import CryptoKit
import MultipeerConnectivity
import SwiftUI

/// Finds Macs running NotchIsland (Portal on) and sends files to the connected one.
///
/// The Mac advertises `_notch-portal._tcp`; this side browses and invites the chosen Mac. Then the
/// handshake from `PortalPairing.swift` (shared with the Mac): the first time both screens show the
/// same code and the phone keeps a key in the Keychain; afterwards each connection proves that key in
/// both directions. Files go out only to a Mac that proved it (`sendResource`).
@MainActor
final class PortalLink: NSObject, ObservableObject {
    enum State: Equatable {
        case searching
        case connecting(String)
        /// Connected, checking keys.
        case verifying(String)
        /// First time with this Mac: compare `code` with the Mac's screen.
        case pairing(mac: String, code: String?, confirmed: Bool)
        case connected(String)
        /// The Mac declined, or its proof was wrong.
        case refused(String)
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

    /// This phone's id in the handshake (the Mac keeps its key under it).
    private let deviceID: String = {
        if let id = UserDefaults.standard.string(forKey: "portalDeviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "portalDeviceID")
        return id
    }()
    private let keys = PortalKeyStore(service: "local.notchisland.portalcompanion")
    /// Set once the Mac proved the key (or pairing finished): only then files may go.
    private var verifiedMac: MCPeerID?
    /// The Mac's id and nonce from `hello`, and our nonce for `auth`.
    private var macID: String?
    private var macNonce = Data()
    private var phoneNonce = Data()
    private var pairingKey: Curve25519.KeyAgreement.PrivateKey?
    private var pendingKey: Data?
    /// Don't keep reconnecting (and popping windows on) a Mac that said no.
    private var declined: Set<String> = []

    private var peer: MCPeerID!
    private var session: MCSession!
    private var browser: MCNearbyServiceBrowser!

    override init() {
        super.init()
        restart()
    }

    /// The Mac files can go to: connected and verified.
    var connectedMac: MCPeerID? { verifiedMac.flatMap { session.connectedPeers.contains($0) ? $0 : nil } }
    private var sessionMac: MCPeerID? { session.connectedPeers.first }

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
        verifiedMac = nil
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
        declined.remove(mac.displayName)
        if let current = sessionMac, current != mac { session.disconnect() }
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
        guard sessionMac == nil else { return }
        switch state {
        case .searching, .refused: break
        default: return
        }
        let candidates = macs.filter { !declined.contains($0.displayName) }
        let pick = candidates.first { $0.displayName == preferredMac } ?? (candidates.count == 1 ? candidates.first : nil)
        if let pick { connect(to: pick) }
    }

    // MARK: Handshake

    private func send(_ message: PortalMessage, to mac: MCPeerID) {
        try? session.send(message.encoded(), toPeers: [mac], with: .reliable)
    }

    private func handle(_ message: PortalMessage, from mac: MCPeerID) {
        let name = mac.displayName
        let me = deviceName.trimmingCharacters(in: .whitespaces).isEmpty ? "iPhone" : deviceName
        switch message {
        case let .hello(id, nonce):
            macID = id
            macNonce = nonce
            if let key = keys.key(for: id) {
                phoneNonce = PortalPairing.nonce()
                let proof = PortalPairing.proof(key: key, role: .phone, mac: id, macNonce: nonce, phoneNonce: phoneNonce)
                send(.auth(device: deviceID, name: me, nonce: phoneNonce, proof: proof), to: mac)
            } else {
                startPairing(with: mac, name: me)
            }

        case let .welcome(proof):
            guard let id = macID, let key = keys.key(for: id),
                  PortalPairing.verify(proof, key: key, role: .mac, mac: id, macNonce: macNonce, phoneNonce: phoneNonce) else {
                // Someone answered for this Mac without its key: don't send it anything.
                return refuse(mac)
            }
            verifiedMac = mac
            state = .connected(name)

        case .unknown:
            // The Mac forgot this phone: pair again.
            if let id = macID { keys.remove(id) }
            startPairing(with: mac, name: me)

        case let .pairKey(pub):
            guard let own = pairingKey,
                  let (key, code) = try? PortalPairing.derive(own: own, peerPub: pub, phonePub: own.publicKey.rawRepresentation, macPub: pub)
            else { return refuse(mac) }
            pendingKey = key
            send(.pairReveal(pub: own.publicKey.rawRepresentation), to: mac)
            state = .pairing(mac: name, code: PortalPairing.display(code), confirmed: false)

        case .paired:
            guard let id = macID, let key = pendingKey, case .pairing(_, _, true) = state else { return refuse(mac) }
            keys.set(key, for: id)
            pendingKey = nil
            pairingKey = nil
            verifiedMac = mac
            state = .connected(name)
            UINotificationFeedbackGenerator().notificationOccurred(.success)

        case .denied:
            refuse(mac)

        case .auth, .pair, .pairReveal, .confirm:
            break   // phone → Mac only
        }
    }

    private func startPairing(with mac: MCPeerID, name: String) {
        let own = Curve25519.KeyAgreement.PrivateKey()
        pairingKey = own
        pendingKey = nil
        state = .pairing(mac: mac.displayName, code: nil, confirmed: false)
        send(.pair(device: deviceID, name: name, commit: PortalPairing.commitment(to: own.publicKey.rawRepresentation)), to: mac)
    }

    /// The user saw the same code on both screens.
    func confirmPairing() {
        guard case let .pairing(name, code?, false) = state, let mac = sessionMac else { return }
        send(.confirm, to: mac)
        state = .pairing(mac: name, code: code, confirmed: true)
    }

    func cancelPairing() {
        guard let mac = sessionMac else { state = .searching; return }
        send(.denied, to: mac)
        refuse(mac)
    }

    private func refuse(_ mac: MCPeerID) {
        declined.insert(mac.displayName)
        verifiedMac = nil
        pairingKey = nil
        pendingKey = nil
        state = .refused(mac.displayName)
        session.disconnect()
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
            case .connected:
                // The Mac's hello may already have moved us on to pairing or connected.
                switch self.state {
                case .searching, .connecting, .refused: self.state = .verifying(peerID.displayName)
                default: break
                }
            case .connecting: self.state = .connecting(peerID.displayName)
            case .notConnected:
                if self.verifiedMac == peerID { self.verifiedMac = nil }
                if case .refused = self.state {} else { self.state = .searching }
                // Declined or dropped: try again in a moment (the Mac may have just been woken).
                try? await Task.sleep(for: .seconds(3))
                self.autoConnect()
            @unknown default: break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = PortalMessage.decode(data) else { return }
        Task { @MainActor in self.handle(message, from: peerID) }
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
