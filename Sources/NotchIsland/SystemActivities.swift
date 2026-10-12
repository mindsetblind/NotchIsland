import AppKit
import EventKit
import NotchIslandCore

// MARK: - Disk space

/// Warns when the startup volume runs low on space. Checked rarely (every 30 minutes and after
/// wake) — free space doesn't change fast enough to justify more.
@MainActor
final class DiskSpaceMonitor {
    var onLow: ((Int64) -> Void)?
    /// In GB, highest first.
    private var alarm = ThresholdAlarm(thresholds: [10, 5], hysteresis: 2)
    private var timer: Timer?

    func start() {
        let t = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        t.tolerance = 5 * 60
        timer = t
        // Not right at launch: login is busy enough.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in MainActor.assumeIsolated { self?.check() } }
    }

    func check() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return }
        if alarm.update(Double(bytes) / 1_000_000_000) != nil { onLow?(bytes) }
    }
}

// MARK: - Low battery

/// Announces 20% and 10% once per discharge; plugging in re-arms it.
struct LowBatteryWatcher {
    private var alarm = ThresholdAlarm(thresholds: [20, 10], hysteresis: 3)

    /// Returns the level to announce, if any.
    mutating func update(_ b: Battery) -> Int? {
        guard b.hasBattery else { return nil }
        if b.onAC {
            alarm.reset()
            return nil
        }
        return alarm.update(Double(b.level)).map { _ in b.level }
    }
}

// MARK: - Finished downloads

/// Notices files that finish downloading into ~/Downloads. Uses a kernel file-system event on the
/// folder (no polling). Browsers write to a temporary name (.download, .crdownload, .part) and rename
/// it when done, so a new file with a final name means a finished download.
///
/// Off by default: watching the folder makes macOS ask for access to Downloads.
@MainActor
final class DownloadsWatcher {
    var onFinished: ((URL) -> Void)?
    /// Set when macOS refused access to the folder.
    private(set) var accessDenied = false

    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private var scanWork: DispatchWorkItem?
    private let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

    private static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "tmp", "opdownload", "!qb"]

    var isRunning: Bool { source != nil }

    func start() {
        guard source == nil else { return }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            accessDenied = errno == EPERM || errno == EACCES
            debugLog("downloads: can't watch folder (errno \(errno))")
            return
        }
        accessDenied = false
        known = listing()
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleScan() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
        scanWork?.cancel()
    }

    private func listing() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    /// Folder events come in bursts while a file is written: look once things settle.
    private func scheduleScan() {
        scanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.scan() } }
        scanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func scan() {
        let now = listing()
        let added = now.subtracting(known)
        known = now
        for name in added.sorted() {
            guard !name.hasPrefix("."), !Self.partialExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            let url = folder.appendingPathComponent(name)
            onFinished?(url)
        }
    }
}

// MARK: - Calendar

/// Upcoming calendar events: a short alert a few minutes before an event and when it starts.
/// Needs calendar access, which is only requested when the user turns this on. Events are read
/// locally through EventKit and never leave the Mac.
@MainActor
final class CalendarMonitor: ObservableObject {
    enum Access: Equatable { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    var onAlert: ((EKEvent, _ startingNow: Bool) -> Void)?
    var leadMinutes = 5

    private let store = EKEventStore()
    private var timer: Timer?
    private var changeObserver: Any?
    private var announced: Set<String> = []
    private var enabled = false

    init() {
        access = Self.currentAccess()
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: return .granted
        case .notDetermined: return .unknown
        default: return .denied
        }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        guard on else { return stop() }
        switch Self.currentAccess() {
        case .granted:
            access = .granted
            start()
        case .denied:
            access = .denied
        case .unknown:
            store.requestFullAccessToEvents { [weak self] granted, error in
                if let error { debugLog("calendar: access request failed: \(error.localizedDescription)") }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.access = granted ? .granted : .denied
                        if granted && self.enabled { self.start() }
                    }
                }
            }
        }
    }

    private func start() {
        if changeObserver == nil {
            changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reschedule() }
            }
        }
        reschedule()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
    }

    /// Wakes up exactly when the next alert is due (no periodic polling); also on calendar changes and wake.
    func reschedule() {
        timer?.invalidate()
        timer = nil
        guard enabled, access == .granted else { return }
        let now = Date()
        let events = upcomingEvents(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(24 * 3600))
        let lead = TimeInterval(leadMinutes * 60)
        var next: Date?
        for e in events {
            guard let start = e.startDate else { continue }
            for (at, key) in [(start.addingTimeInterval(-lead), "soon"), (start, "now")] where at > now.addingTimeInterval(-30) {
                let id = "\(e.calendarItemIdentifier)|\(start.timeIntervalSince1970)|\(key)"
                if announced.contains(id) { continue }
                if at <= now.addingTimeInterval(1) {
                    announced.insert(id)
                    onAlert?(e, key == "now")
                } else if next.map({ at < $0 }) ?? true {
                    next = at
                }
            }
        }
        if announced.count > 500 { announced.removeAll() }
        if let next {
            let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.reschedule() } }
            t.tolerance = 2
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            // Nothing in the next 24 h: look again in an hour.
            let t = Timer.scheduledTimer(withTimeInterval: 3600, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.reschedule() }
            }
            t.tolerance = 300
            timer = t
        }
    }

    private func upcomingEvents(from: Date, to: Date) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).filter { e in
            guard !e.isAllDay, e.status != .canceled else { return false }
            // Skip events the user declined.
            let me = e.attendees?.first { $0.isCurrentUser }
            return me?.participantStatus != .declined
        }
    }
}
