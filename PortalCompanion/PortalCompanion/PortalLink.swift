import MultipeerConnectivity
import SwiftUI

/// Finds Macs running NotchIsland (Portal on) and sends files to the connected one.
///
/// The Mac advertises `_notch-portal._tcp`; this side browses, invites the chosen Mac and, once the
/// Mac's user allows it (first time only), sends files with `sendResource`.
@MainActor
final class PortalLink: NSObject, ObservableObject {
    enum State: Equatable {
        case searching
        case connecting(String)
        case connected(String)
    }

    static let serviceType = "notch-portal"

    @Published private(set) var state = State.searching
    /// Macs nearby.
    @Published private(set) var macs: [MCPeerID] = []
    /// The Mac to connect to (remembered by name).
    private var preferredMac: String {
        get { UserDefaults.standard.string(forKey: "preferredMac") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "preferredMac") }
    }
    /// How this phone shows up on the Mac (iOS no longer tells apps the phone's real name).
    @Published var deviceName = UserDefaults.standard.string(forKey: "deviceName") ?? UIDevice.current.name {
        didSet {
            guard deviceName != oldValue else { return }
            UserDefaults.standard.set(deviceName, forKey: "deviceName")
            restart()
        }
    }

    private var peer: MCPeerID!
    private var session: MCSession!
    private var browser: MCNearbyServiceBrowser!

    override init() {
        super.init()
        restart()
    }

    var connectedMac: MCPeerID? { session.connectedPeers.first }

    func restart() {
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        let name = deviceName.trimmingCharacters(in: .whitespaces).isEmpty ? "iPhone" : deviceName
        peer = Self.persistentPeerID(name: name)
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        browser = MCNearbyServiceBrowser(peer: peer, serviceType: Self.serviceType)
        browser.delegate = self
        macs = []
        state = .searching
        browser.startBrowsingForPeers()
    }

    /// Reusing one peer ID per name stops the Mac from seeing "ghost" duplicates after relaunches.
    private static func persistentPeerID(name: String) -> MCPeerID {
        let d = UserDefaults.standard
        if d.string(forKey: "peerName") == name, let data = d.data(forKey: "peerID"),
           let saved = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data) {
            return saved
        }
        let fresh = MCPeerID(displayName: name)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: fresh, requiringSecureCoding: true) {
            d.set(data, forKey: "peerID")
            d.set(name, forKey: "peerName")
        }
        return fresh
    }

    func connect(to mac: MCPeerID) {
        preferredMac = mac.displayName
        if let current = connectedMac, current != mac { session.disconnect() }
        state = .connecting(mac.displayName)
        browser.invitePeer(mac, to: session, withContext: nil, timeout: 30)
    }

    /// Sends a file; `progress` reports 0…1. Throws when there's no Mac or the transfer fails.
    func send(_ url: URL, name: String, progress: @escaping @MainActor (Double) -> Void) async throws {
        guard let mac = connectedMac else { throw PortalLinkError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var observation: NSKeyValueObservation?
            let p = session.sendResource(at: url, withName: name, toPeer: mac) { error in
                observation?.invalidate()
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
            observation = p?.observe(\.fractionCompleted) { p, _ in
                let f = p.fractionCompleted
                Task { @MainActor in progress(f) }
            }
            if p == nil { cont.resume(throwing: PortalLinkError.notConnected) }
        }
    }

    private func autoConnect() {
        guard connectedMac == nil, case .searching = state else { return }
        let pick = macs.first { $0.displayName == preferredMac } ?? (macs.count == 1 ? macs.first : nil)
        if let pick { connect(to: pick) }
    }
}

enum PortalLinkError: LocalizedError {
    case notConnected
    var errorDescription: String? { "Mac не подключён" }
}

extension PortalLink: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard !self.macs.contains(peerID) else { return }
            self.macs.append(peerID)
            self.autoConnect()
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in self.macs.removeAll { $0 == peerID } }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("portal: can't browse: \(error)")
    }
}

extension PortalLink: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected: self.state = .connected(peerID.displayName)
            case .connecting: self.state = .connecting(peerID.displayName)
            case .notConnected:
                self.state = .searching
                // Declined or dropped: try again in a moment (the Mac may have just been woken).
                try? await Task.sleep(for: .seconds(3))
                self.autoConnect()
            @unknown default: break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
