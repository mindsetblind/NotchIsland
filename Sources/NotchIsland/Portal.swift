import AppKit
import Combine
import MultipeerConnectivity
import Network
import NotchIslandCore

/// Portal: photos and files thrown from an iPhone land on this Mac with an effect at the screen edge.
///
/// Two ways in:
/// - **Multipeer** (the PortalCompanion iOS app): the Mac advertises `_notch-portal._tcp`, the phone
///   finds it, and files arrive through `sendResource`. A device sends only after it was allowed once.
/// - **HTTP** (iOS Shortcuts, curl): `POST /upload` on the local network with a token from Settings.
///
/// Off until the user turns it on (advertising makes macOS ask for local-network access).
@MainActor
final class PortalService: ObservableObject {
    static let shared = PortalService()
    nonisolated static let serviceType = "notch-portal"

    /// Devices that are connected right now (Multipeer).
    @Published private(set) var connected: [String] = []
    /// Devices allowed to send without asking (persisted by name).
    @Published private(set) var trusted: [String] = UserDefaults.standard.stringArray(forKey: "portalTrustedDevices") ?? []
    @Published private(set) var httpStatus: String = ""
    @Published private(set) var lastError: String?

    /// A file has landed: (file, sender).
    var onReceived: ((URL, String) -> Void)?

    private var multipeer: MultipeerReceiver?
    private var http: PortalHTTPServer?
    private var observers: [AnyCancellable] = []

    func start() {
        let s = AppSettings.shared
        observers = [
            s.$portalEnabled.removeDuplicates().sink { [weak self] on in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.setMultipeer(on) } }
            },
            s.$portalHTTPEnabled.combineLatest(s.$portalHTTPPort).sink { [weak self] on, port in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.setHTTP(on, port: port) } }
            },
        ]
    }

    // MARK: Destination

    nonisolated static var folder: URL {
        if let path = UserDefaults.standard.string(forKey: "portalFolder"), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// Moves a finished temporary file into the destination folder under a safe, unique name.
    /// Thread-safe: Multipeer calls it from its own queue (the temporary file is gone once it returns).
    nonisolated static func store(_ temp: URL, name: String) throws -> URL {
        let folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = PortalFiles.uniqueDestination(for: PortalFiles.sanitize(name), in: folder)
        try FileManager.default.moveItem(at: temp, to: dest)
        // Like a browser download: macOS remembers where the file came from.
        try? (dest as NSURL).setResourceValue(Date(), forKey: .contentModificationDateKey)
        return dest
    }

    // MARK: Multipeer

    private func setMultipeer(_ on: Bool) {
        if on, multipeer == nil {
            let receiver = MultipeerReceiver(name: Host.current().localizedName ?? "Mac")
            receiver.delegate = self
            receiver.start()
            multipeer = receiver
        } else if !on, let receiver = multipeer {
            receiver.stop()
            multipeer = nil
            connected = []
        }
    }

    var macName: String { Host.current().localizedName ?? "Mac" }

    func forget(_ device: String) {
        trusted.removeAll { $0 == device }
        UserDefaults.standard.set(trusted, forKey: "portalTrustedDevices")
    }

    fileprivate func trust(_ device: String) {
        guard !trusted.contains(device) else { return }
        trusted.append(device)
        UserDefaults.standard.set(trusted, forKey: "portalTrustedDevices")
    }

    /// First time a device knocks: ask. Answered once, remembered by device name.
    fileprivate func shouldAccept(_ device: String) -> Bool {
        if trusted.contains(device) { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "«\(device)» хочет отправлять файлы на этот Mac"
        alert.informativeText = "Фото и файлы будут сохраняться в папку «\(Self.folder.lastPathComponent)». Разрешение можно отозвать в настройках NotchIsland → Portal."
        alert.addButton(withTitle: "Разрешить")
        alert.addButton(withTitle: "Отклонить")
        let ok = alert.runModal() == .alertFirstButtonReturn
        if ok { trust(device) }
        return ok
    }

    // MARK: HTTP

    private func setHTTP(_ on: Bool, port: Int) {
        http?.stop()
        http = nil
        guard on else { httpStatus = ""; return }
        let server = PortalHTTPServer(port: UInt16(clamping: port))
        server.delegate = self
        server.onState = { [weak self] status in self?.httpStatus = status }
        server.start()
        http = server
    }

    /// Addresses to type into Shortcuts: `http://name.local:port/upload` and the IPv4 one.
    var uploadURLs: [String] {
        let port = AppSettings.shared.portalHTTPPort
        var urls: [String] = []
        let host = ProcessInfo.processInfo.hostName
        if host.hasSuffix(".local") { urls.append("http://\(host):\(port)/upload") }
        urls += Self.localIPv4().map { "http://\($0):\(port)/upload" }
        return urls
    }

    static func localIPv4() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }   // Wi-Fi / Ethernet, not VPN tunnels
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }
}

// MARK: - Transfers (shared by both ways in)

extension PortalService: PortalTransferDelegate {
    func transferBegan(id: String, name: String, from: String) {
        PortalEffectController.shared.begin(id: id, name: name)
    }

    func transferProgress(id: String, fraction: Double) {
        PortalEffectController.shared.update(id: id, fraction: fraction)
    }

    func transferFinished(id: String, file: URL?, from: String, error: String?) {
        if let file {
            debugLog("portal: received \(file.lastPathComponent) from \(from)")
            lastError = nil
            Usage.track(.portalReceived)
            PortalEffectController.shared.finish(id: id, file: file)
            onReceived?(file, from)
        } else {
            debugLog("portal: transfer from \(from) failed: \(error ?? "?")")
            lastError = error
            PortalEffectController.shared.fail(id: id)
        }
    }

    func peersChanged(_ names: [String]) { connected = names }
    func allowPeer(_ name: String) -> Bool { shouldAccept(name) }
}

@MainActor
protocol PortalTransferDelegate: AnyObject {
    func transferBegan(id: String, name: String, from: String)
    func transferProgress(id: String, fraction: Double)
    func transferFinished(id: String, file: URL?, from: String, error: String?)
    func peersChanged(_ names: [String])
    func allowPeer(_ name: String) -> Bool
}

// MARK: - Multipeer receiver

/// Advertises the Mac and accepts resources. Multipeer calls back on its own queues; everything the
/// UI needs is sent to the main actor, except moving the finished file (it must happen right away).
final class MultipeerReceiver: NSObject, MCNearbyServiceAdvertiserDelegate, MCSessionDelegate {
    weak var delegate: PortalTransferDelegate?

    private let peer: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private var progressObservers: [String: NSKeyValueObservation] = [:]
    private let lock = NSLock()

    init(name: String) {
        peer = Self.persistentPeerID(name: name)
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["app": "NotchIsland"],
                                               serviceType: PortalService.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
    }

    /// Apple asks to reuse one peer ID per device name, or nearby phones see "ghost" duplicates.
    private static func persistentPeerID(name: String) -> MCPeerID {
        let d = UserDefaults.standard
        if d.string(forKey: "portalPeerName") == name, let data = d.data(forKey: "portalPeerID"),
           let saved = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data) {
            return saved
        }
        let fresh = MCPeerID(displayName: name)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: fresh, requiringSecureCoding: true) {
            d.set(data, forKey: "portalPeerID")
            d.set(name, forKey: "portalPeerName")
        }
        return fresh
    }

    func start() {
        advertiser.startAdvertisingPeer()
        debugLog("portal: advertising as \(peer.displayName)")
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        session.disconnect()
    }

    private func onMain(_ work: @escaping @MainActor (PortalTransferDelegate) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { if let d = self?.delegate { work(d) } }
        }
    }

    // MARK: Advertiser

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let session = session
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                let ok = self?.delegate?.allowPeer(peerID.displayName) ?? false
                invitationHandler(ok, ok ? session : nil)
            }
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        debugLog("portal: can't advertise: \(error.localizedDescription)")
    }

    // MARK: Session

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let names = session.connectedPeers.map(\.displayName)
        onMain { $0.peersChanged(names) }
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {
        let id = "\(peerID.displayName)/\(resourceName)/\(ObjectIdentifier(progress).hashValue)"
        let from = peerID.displayName
        onMain { $0.transferBegan(id: id, name: resourceName, from: from) }
        let observer = progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let fraction = p.fractionCompleted
            self?.onMain { $0.transferProgress(id: id, fraction: fraction) }
        }
        lock.lock(); progressObservers[resourceName + from] = observer; lock.unlock()
        // The finish callback has no progress object: remember which id belongs to this name.
        lock.lock(); activeIDs[resourceName + from] = id; lock.unlock()
    }

    private var activeIDs: [String: String] = [:]

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        let from = peerID.displayName
        let key = resourceName + from
        lock.lock()
        let id = activeIDs.removeValue(forKey: key) ?? key
        progressObservers.removeValue(forKey: key)?.invalidate()
        lock.unlock()
        var stored: URL?, failure = error?.localizedDescription
        if let localURL, error == nil {
            do { stored = try PortalService.store(localURL, name: resourceName) } catch { failure = error.localizedDescription }
        }
        onMain { $0.transferFinished(id: id, file: stored, from: from, error: failure) }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
}

// MARK: - HTTP server (Shortcuts / curl)

/// `POST /upload` with the body being the file (or multipart/form-data with a file field).
/// Auth: `Authorization: Bearer <token>`, `X-Portal-Token: <token>` or `?token=`.
/// File name: `X-Filename` header (percent-encoded or UTF-8), `?name=`, or the multipart part's.
/// `GET /` answers with a short status line so reachability is easy to check.
final class PortalHTTPServer {
    weak var delegate: PortalTransferDelegate?
    var onState: (@MainActor (String) -> Void)?

    private let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "notchisland.portal.http")

    init(port: UInt16) { self.port = port }

    @MainActor func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? 54321)
            listener.stateUpdateHandler = { [weak self, port] state in
                let text: String
                switch state {
                case .ready: text = "Слушает порт \(port)"
                case .failed(let e): text = "Ошибка: \(e.localizedDescription)"
                case .waiting(let e): text = "Ждёт сеть: \(e.localizedDescription)"
                default: return
                }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onState?(text) } }
            }
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return conn.cancel() }
                PortalHTTPConnection(conn, delegate: self.delegate).start(on: self.queue)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onState?("Не удалось открыть порт \(port): \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// One request: streams the body to a temporary file (videos may be large), then stores it.
private final class PortalHTTPConnection {
    private let conn: NWConnection
    private weak var delegate: PortalTransferDelegate?
    private let parser = HTTPUploadParser()
    private var head: HTTPRequestHead?
    private var tempURL: URL?
    private var file: FileHandle?
    private var received = 0
    private var id = UUID().uuidString
    private var from = "Быстрые команды"
    private var lastReport = Date.distantPast
    /// Keeps itself alive until the connection ends.
    private var retainCycle: PortalHTTPConnection?
    private var announced = false

    static let maxBytes = 8 << 30   // 8 GB

    init(_ conn: NWConnection, delegate: PortalTransferDelegate?) {
        self.conn = conn
        self.delegate = delegate
    }

    func start(on queue: DispatchQueue) {
        retainCycle = self
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.cleanUp()
            default: break
            }
        }
        conn.start(queue: queue)
        if case .hostPort(let host, _) = conn.endpoint { from = "\(host)" }
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.handle(self.parser.feed(data)) }
            if self.parser.isFinished { return }
            if isComplete || error != nil {
                self.handle(self.parser.finishInput())
                if !self.parser.isFinished { self.conn.cancel() }
                return
            }
            self.receive()
        }
    }

    private func handle(_ events: [HTTPUploadParser.Event]) {
        for event in events {
            switch event {
            case .head(let head):
                self.head = head
                guard begin(head) else { return }
            case .body(let data):
                received += data.count
                guard received <= Self.maxBytes else { return fail(413, "Слишком большой файл") }
                file?.write(data)
                report()
            case .done:
                finish()
            case .failed(let why):
                respond(400, json: ["ok": false, "error": why])
            }
        }
    }

    /// Checks the request and opens the temporary file. Returns false when it already answered.
    private func begin(_ head: HTTPRequestHead) -> Bool {
        if head.method == "GET" && (head.path == "/" || head.path == "/ping") {
            respond(200, json: ["ok": true, "app": "NotchIsland Portal"])
            return false
        }
        guard head.method == "POST" || head.method == "PUT", head.path == "/upload" else {
            respond(404, json: ["ok": false, "error": "use POST /upload"])
            return false
        }
        guard PortalToken.matches(head.token, AppSettings.portalToken) else {
            respond(401, json: ["ok": false, "error": "wrong token"])
            return false
        }
        if let length = head.contentLength, length > Self.maxBytes {
            respond(413, json: ["ok": false, "error": "too large"])
            return false
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("portal-\(id)")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        tempURL = temp
        file = try? FileHandle(forWritingTo: temp)
        if head.expectsContinue { conn.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent) }
        if let device = head.headers["x-device-name"], !device.isEmpty { from = device.removingPercentEncoding ?? device }
        let name = head.fileName ?? "файл"
        let id = id, from = from
        DispatchQueue.main.async { [weak delegate] in
            MainActor.assumeIsolated { delegate?.transferBegan(id: id, name: name, from: from) }
        }
        announced = true
        return true
    }

    private func report() {
        guard let total = head?.contentLength, total > 0, Date().timeIntervalSince(lastReport) > 0.05 else { return }
        lastReport = Date()
        let fraction = Double(received) / Double(total), id = id
        DispatchQueue.main.async { [weak delegate] in
            MainActor.assumeIsolated { delegate?.transferProgress(id: id, fraction: fraction) }
        }
    }

    private func finish() {
        try? file?.close()
        file = nil
        guard let head, let temp = tempURL else { return }
        do {
            var name = head.fileName
            var source = temp
            if let boundary = head.multipartBoundary {
                // Shortcuts' "Form" body: cut the file part out into its own file.
                let body = try Data(contentsOf: temp, options: .alwaysMapped)
                guard let part = Multipart.filePart(in: body, boundary: boundary) else { throw PortalError.noFile }
                let extracted = temp.appendingPathExtension("part")
                try body.subdata(in: part.range).write(to: extracted)
                try? FileManager.default.removeItem(at: temp)
                tempURL = extracted
                source = extracted
                name = part.fileName ?? name
                if (name.map { ($0 as NSString).pathExtension.isEmpty } ?? true), let ext = PortalFiles.fileExtension(forContentType: part.contentType) {
                    name = (name ?? "Portal") + "." + ext
                }
            } else if (name.map { ($0 as NSString).pathExtension.isEmpty } ?? true),
                      let ext = PortalFiles.fileExtension(forContentType: head.headers["content-type"]) {
                name = (name ?? "Portal") + "." + ext
            }
            guard received > 0 else { throw PortalError.noFile }
            let stored = try PortalService.store(source, name: name ?? "")
            tempURL = nil
            respond(200, json: ["ok": true, "name": stored.lastPathComponent])
            notifyFinished(file: stored, error: nil)
        } catch {
            fail(400, (error as? PortalError)?.message ?? error.localizedDescription)
        }
    }

    private func fail(_ status: Int, _ message: String) {
        respond(status, json: ["ok": false, "error": message])
        notifyFinished(file: nil, error: message)
    }

    private func notifyFinished(file: URL?, error: String?) {
        guard announced else { return }
        announced = false
        let id = id, from = from
        DispatchQueue.main.async { [weak delegate] in
            MainActor.assumeIsolated { delegate?.transferFinished(id: id, file: file, from: from, error: error) }
        }
    }

    private func respond(_ status: Int, json: [String: Any]) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 413: "Payload Too Large"][status] ?? "Error"
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in self?.conn.cancel() })
    }

    private func cleanUp() {
        try? file?.close()
        file = nil
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        tempURL = nil
        if announced { notifyFinished(file: nil, error: "соединение прервано") }
        retainCycle = nil
    }
}

private enum PortalError: Error {
    case noFile
    var message: String { "в запросе нет файла" }
}
