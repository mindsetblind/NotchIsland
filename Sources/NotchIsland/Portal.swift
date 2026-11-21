import AppKit
import Combine
import CryptoKit
import MultipeerConnectivity
import Network
import NotchIslandCore

/// Portal: photos and files thrown from an iPhone land on this Mac with an effect at the screen edge.
///
/// Two ways in:
/// - **Multipeer** (the PortalCompanion iOS app): the Mac advertises `_notch-portal._tcp`, the phone
///   finds it, and files arrive through `sendResource`. A phone sends only after pairing: both screens
///   show the same 6-digit code once, then every connection proves the shared key (`PortalPairing`).
/// - **HTTP** (iOS Shortcuts, curl): `POST /upload` on the local network with a token from Settings.
///
/// Off until the user turns it on (advertising makes macOS ask for local-network access).
@MainActor
final class PortalService: ObservableObject {
    static let shared = PortalService()
    nonisolated static let serviceType = "notch-portal"

    /// Paired phones (id → name); their keys live in the Keychain.
    struct Device: Codable, Hashable, Identifiable {
        var id: String
        var name: String
    }

    /// Paired devices that are connected and verified right now.
    @Published private(set) var connected: Set<String> = []
    /// Devices paired with this Mac.
    @Published private(set) var trusted: [Device] = PortalService.loadDevices()
    @Published private(set) var httpStatus: String = ""
    @Published private(set) var lastError: String?

    /// A file has landed: (file, sender).
    var onReceived: ((URL, String) -> Void)?

    private var multipeer: MultipeerReceiver?
    private let keys = PortalKeyStore(service: "local.notchisland.portal")
    /// The Mac's nonce for each connected phone that hasn't proven itself yet.
    private var challenges: [MCPeerID: Data] = [:]
    private var pairing: Pairing?
    private var pairingTimeout: DispatchWorkItem?
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

    /// Stable identity of this Mac in the handshake (phones keep their key under it).
    nonisolated static var macID: String {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "portalMacID") { return id }
        let id = UUID().uuidString
        d.set(id, forKey: "portalMacID")
        return id
    }

    private static func loadDevices() -> [Device] {
        // Trust by name (before pairing existed) is not trust any more: those phones pair once again.
        UserDefaults.standard.removeObject(forKey: "portalTrustedDevices")
        guard let data = UserDefaults.standard.data(forKey: "portalDevices") else { return [] }
        return (try? JSONDecoder().decode([Device].self, from: data)) ?? []
    }

    private func saveDevices() {
        UserDefaults.standard.set(try? JSONEncoder().encode(trusted), forKey: "portalDevices")
    }

    func forget(_ id: String) {
        trusted.removeAll { $0.id == id }
        saveDevices()
        keys.remove(id)
        multipeer?.revoke(device: id)
        connected.remove(id)
    }

    // MARK: Handshake

    private struct Pairing {
        let peer: MCPeerID
        let device: String
        let name: String
        let commit: Data
        let own = Curve25519.KeyAgreement.PrivateKey()
        var key: Data?
        var macAllowed = false
        var phoneConfirmed = false
    }

    fileprivate func peerJoined(_ peer: MCPeerID) {
        let nonce = PortalPairing.nonce()
        challenges[peer] = nonce
        multipeer?.send(.hello(mac: Self.macID, nonce: nonce), to: peer)
    }

    fileprivate func peerLeft(_ peer: MCPeerID) {
        challenges.removeValue(forKey: peer)
        if pairing?.peer == peer { endPairing() }
    }

    fileprivate func handle(_ message: PortalMessage, from peer: MCPeerID) {
        switch message {
        case let .auth(device, name, nonce, proof):
            guard let challenge = challenges[peer] else { return }
            guard trusted.contains(where: { $0.id == device }), let key = keys.key(for: device) else {
                return multipeer?.send(.unknown, to: peer) ?? ()
            }
            guard PortalPairing.verify(proof, key: key, role: .phone, mac: Self.macID, macNonce: challenge, phoneNonce: nonce) else {
                debugLog("portal: wrong proof from \(peer.displayName)")
                challenges.removeValue(forKey: peer)
                return multipeer?.send(.denied, to: peer) ?? ()
            }
            challenges.removeValue(forKey: peer)
            rename(device, to: name)
            admit(peer, device: device)
            multipeer?.send(.welcome(proof: PortalPairing.proof(key: key, role: .mac, mac: Self.macID,
                                                                 macNonce: challenge, phoneNonce: nonce)), to: peer)

        case let .pair(device, name, commit):
            // One pairing at a time, and only from a peer we greeted on this connection.
            guard pairing == nil, challenges[peer] != nil, !device.isEmpty, device.count <= 64 else {
                return multipeer?.send(.denied, to: peer) ?? ()
            }
            let p = Pairing(peer: peer, device: device, name: Self.clean(name), commit: commit)
            pairing = p
            multipeer?.send(.pairKey(pub: p.own.publicKey.rawRepresentation), to: peer)
            let timeout = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.pairing?.peer == peer else { return }
                    self.multipeer?.send(.denied, to: peer)
                    self.endPairing()
                }
            }
            pairingTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: timeout)

        case let .pairReveal(pub):
            guard var p = pairing, p.peer == peer, p.key == nil else { return }
            guard PortalPairing.commitment(to: pub) == p.commit,
                  let (key, code) = try? PortalPairing.derive(own: p.own, peerPub: pub, phonePub: pub,
                                                             macPub: p.own.publicKey.rawRepresentation) else {
                multipeer?.send(.denied, to: peer)
                return endPairing()
            }
            p.key = key
            pairing = p
            PortalPairingPanel.shared.show(device: p.name, code: PortalPairing.display(code),
                                           onAllow: { [weak self] in self?.pairingAllowed() },
                                           onDeny: { [weak self] in
                                               self?.multipeer?.send(.denied, to: peer)
                                               self?.endPairing()
                                           })

        case .confirm:
            guard pairing?.peer == peer, pairing?.key != nil else { return }
            pairing?.phoneConfirmed = true
            finishPairingIfAgreed()

        case .denied:
            if pairing?.peer == peer { endPairing() }

        case .hello, .welcome, .unknown, .pairKey, .paired:
            break   // Mac → phone only
        }
    }

    private func pairingAllowed() {
        pairing?.macAllowed = true
        if pairing?.phoneConfirmed != true { PortalPairingPanel.shared.waitForPhone() }
        finishPairingIfAgreed()
    }

    private func finishPairingIfAgreed() {
        guard let p = pairing, let key = p.key, p.macAllowed, p.phoneConfirmed else { return }
        guard keys.set(key, for: p.device) else {
            lastError = "не удалось сохранить ключ в связке ключей"
            multipeer?.send(.denied, to: p.peer)
            return endPairing()
        }
        trusted.removeAll { $0.id == p.device }
        trusted.append(Device(id: p.device, name: p.name))
        saveDevices()
        challenges.removeValue(forKey: p.peer)
        admit(p.peer, device: p.device)
        multipeer?.send(.paired, to: p.peer)
        debugLog("portal: paired \(p.name)")
        endPairing()
    }

    private func endPairing() {
        pairing = nil
        pairingTimeout?.cancel()
        pairingTimeout = nil
        PortalPairingPanel.shared.close()
    }

    private func admit(_ peer: MCPeerID, device: String) {
        let name = trusted.first { $0.id == device }?.name ?? peer.displayName
        multipeer?.authorize(peer, device: device, name: name)
        connected.insert(device)
    }

    private func rename(_ device: String, to name: String) {
        let name = Self.clean(name)
        guard let i = trusted.firstIndex(where: { $0.id == device }), trusted[i].name != name else { return }
        trusted[i].name = name
        saveDevices()
    }

    private static func clean(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isNewline }
        return trimmed.isEmpty ? "iPhone" : String(trimmed.prefix(40))
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

    func peersChanged(_ devices: Set<String>) { connected = devices }
}

@MainActor
protocol PortalTransferDelegate: AnyObject {
    func transferBegan(id: String, name: String, from: String)
    func transferProgress(id: String, fraction: Double)
    func transferFinished(id: String, file: URL?, from: String, error: String?)
    func peersChanged(_ devices: Set<String>)
}

// MARK: - Multipeer receiver

/// Advertises the Mac and accepts resources. Multipeer calls back on its own queues; everything the
/// UI needs is sent to the main actor, except moving the finished file (it must happen right away).
final class MultipeerReceiver: NSObject, MCNearbyServiceAdvertiserDelegate, MCSessionDelegate {
    weak var delegate: PortalService?

    private let peer: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private var progressObservers: [String: NSKeyValueObservation] = [:]
    private let lock = NSLock()
    /// Peers that proved the pairing key: only they may send files. (peer → device id, name)
    private var authorized: [MCPeerID: (device: String, name: String)] = [:]
    /// Resources from unverified peers, cancelled at the start; their finish is ignored.
    private var refused: Set<String> = []

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

    func send(_ message: PortalMessage, to peer: MCPeerID) {
        try? session.send(message.encoded(), toPeers: [peer], with: .reliable)
    }

    func authorize(_ peer: MCPeerID, device: String, name: String) {
        lock.lock(); authorized[peer] = (device, name); lock.unlock()
    }

    /// "Забыть": that phone stops being able to send right away.
    func revoke(device: String) {
        lock.lock()
        let peers = authorized.filter { $0.value.device == device }.map(\.key)
        peers.forEach { authorized.removeValue(forKey: $0) }
        lock.unlock()
        peers.forEach { send(.denied, to: $0) }
    }

    private func onMain(_ work: @escaping @MainActor (PortalService) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { if let d = self?.delegate { work(d) } }
        }
    }

    // MARK: Advertiser

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Anyone nearby may connect; nothing is accepted until the handshake proves the pairing key.
        lock.lock(); let crowded = session.connectedPeers.count >= 6; lock.unlock()
        invitationHandler(!crowded, crowded ? nil : session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        debugLog("portal: can't advertise: \(error.localizedDescription)")
    }

    // MARK: Session

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        lock.lock()
        if state == .notConnected { authorized.removeValue(forKey: peerID) }
        let devices = Set(authorized.values.map(\.device))
        lock.unlock()
        onMain { gate in
            gate.peersChanged(devices)
            if state == .connected { gate.peerJoined(peerID) }
            if state == .notConnected { gate.peerLeft(peerID) }
        }
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {
        lock.lock()
        let sender = authorized[peerID]
        if sender == nil { refused.insert(resourceName + "\u{0}" + peerID.displayName) }
        lock.unlock()
        guard let sender else {
            debugLog("portal: refused \(resourceName) from unverified \(peerID.displayName)")
            progress.cancel()
            return
        }
        let id = "\(sender.device)/\(resourceName)/\(ObjectIdentifier(progress).hashValue)"
        let from = sender.name
        onMain { $0.transferBegan(id: id, name: resourceName, from: from) }
        let observer = progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let fraction = p.fractionCompleted
            self?.onMain { $0.transferProgress(id: id, fraction: fraction) }
        }
        lock.lock(); progressObservers[resourceName + peerID.displayName] = observer; lock.unlock()
        // The finish callback has no progress object: remember which id belongs to this name.
        lock.lock(); activeIDs[resourceName + peerID.displayName] = id; lock.unlock()
    }

    private var activeIDs: [String: String] = [:]

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        lock.lock()
        let wasRefused = refused.remove(resourceName + "\u{0}" + peerID.displayName) != nil
        let from = authorized[peerID]?.name ?? peerID.displayName
        lock.unlock()
        // The temporary file of a refused resource is deleted by Multipeer once this returns.
        guard !wasRefused else { return }
        let key = resourceName + peerID.displayName
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

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = PortalMessage.decode(data) else { return }
        onMain { $0.handle(message, from: peerID) }
    }
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
