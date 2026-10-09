import AppKit
import CryptoKit
import Network
import Security

// MARK: - Data

struct PlaylistTrack: Identifiable, Equatable {
    let id: String          // position-based, playlists may contain the same track twice
    let uri: String
    let name: String
    let artist: String
    let duration: Double
    let imageURL: URL?
}

struct PlaybackContext: Equatable {
    let uri: String?        // nil → no playable context, showing the play queue instead
    let title: String
    let tracks: [PlaylistTrack]
}

enum SpotifyError: LocalizedError {
    case noClientID, notLoggedIn, http(Int), badResponse, premiumRequired, noActiveDevice

    var errorDescription: String? {
        switch self {
        case .noClientID: return "Не задан Spotify Client ID"
        case .notLoggedIn: return "Нужно войти в Spotify"
        case .http(403): return "Spotify отказал в доступе (403). Проверь, что твой аккаунт добавлен в User Management приложения на developer.spotify.com."
        case .http(429): return "Слишком много запросов к Spotify, попробуй через минуту"
        case .http(let c): return "Ошибка Spotify (\(c))"
        case .badResponse: return "Неожиданный ответ Spotify"
        case .premiumRequired: return "Spotify разрешает выбирать трек из сторонних приложений только с Premium"
        case .noActiveDevice: return "Spotify не видит активного устройства — нажми ⏯ один раз и попробуй снова"
        }
    }
}

// MARK: - Web API client (OAuth PKCE, no client secret)

final class SpotifyWeb {
    static let port: UInt16 = 8973
    static let redirectURI = "http://127.0.0.1:\(port)/callback"
    static let scopes = "user-read-playback-state user-modify-playback-state user-read-currently-playing playlist-read-private playlist-read-collaborative user-library-read"
    private static let grantedScopesKey = "spotifyGrantedScopes"

    /// True when the saved login predates a scope we now need (e.g. playback control) → user must log in again.
    var needsReauth: Bool {
        guard isLoggedIn else { return false }
        let granted = Set((UserDefaults.standard.string(forKey: Self.grantedScopesKey) ?? "").split(separator: " ").map(String.init))
        return !Set(Self.scopes.split(separator: " ").map(String.init)).isSubset(of: granted)
    }
    private static let clientIDKey = "spotifyClientID"
    private static let api = "https://api.spotify.com/v1"
    private static let maxTracks = 500

    var clientID: String? {
        get { UserDefaults.standard.string(forKey: Self.clientIDKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue?.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.clientIDKey) }
    }

    var isLoggedIn: Bool { Keychain.refreshToken != nil }

    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private var server: CallbackServer?

    // MARK: Auth

    func login(completion: @escaping (Error?) -> Void) {
        guard let clientID else { return completion(SpotifyError.noClientID) }
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(16)

        server?.stop()
        let server = CallbackServer(port: Self.port)
        self.server = server
        do {
            try server.start { [weak self] query in
                guard let self else { return }
                server.stop()
                guard query["state"] == state, let code = query["code"] else {
                    return completion(SpotifyError.badResponse)
                }
                Task { @MainActor in
                    do {
                        try await self.requestToken([
                            "grant_type": "authorization_code",
                            "code": code,
                            "redirect_uri": Self.redirectURI,
                            "client_id": clientID,
                            "code_verifier": verifier,
                        ])
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            }
        } catch {
            return completion(error)
        }

        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
            .init(name: "scope", value: Self.scopes),
        ]
        NSWorkspace.shared.open(c.url!)
    }

    func logout() {
        Keychain.refreshToken = nil
        UserDefaults.standard.removeObject(forKey: Self.grantedScopesKey)
        accessToken = nil
        expiresAt = .distantPast
    }

    private func requestToken(_ form: [String: String]) async throws {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = c.percentEncodedQuery?.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 {
            // Refresh token revoked or expired: force a fresh login.
            logout()
            throw SpotifyError.notLoggedIn
        }
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else { throw SpotifyError.http(status) }
        accessToken = token
        expiresAt = Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600) - 60)
        if let refresh = json["refresh_token"] as? String { Keychain.refreshToken = refresh }
        if let scope = json["scope"] as? String { UserDefaults.standard.set(scope, forKey: Self.grantedScopesKey) }
    }

    private func validToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let accessToken, Date() < expiresAt { return accessToken }
        guard let clientID else { throw SpotifyError.noClientID }
        guard let refresh = Keychain.refreshToken else { throw SpotifyError.notLoggedIn }
        try await requestToken(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        return accessToken!
    }

    /// GET a Web API URL. Returns nil for 204 No Content.
    private func get(_ urlString: String, retry: Bool = true) async throws -> [String: Any]? {
        let url = URL(string: urlString.hasPrefix("http") ? urlString : Self.api + urlString)!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 && retry {
            _ = try await validToken(forceRefresh: true)
            return try await get(urlString, retry: false)
        }
        if status == 204 { return nil }
        guard (200..<300).contains(status) else { throw SpotifyError.http(status) }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: Playback control

    /// Starts `trackURI` inside `contextURI` (playlist/album) in the background, without touching the Spotify window.
    func play(trackURI: String, contextURI: String?) async throws {
        let body: [String: Any] = contextURI.map { ["context_uri": $0, "offset": ["uri": trackURI]] }
            ?? ["uris": [trackURI]]
        // Target Spotify on *this* Mac explicitly; otherwise the command may go to a phone/web player
        // that Spotify considers "active", and the desktop app just stops.
        let device = try? await thisComputerDeviceID()
        let query = device.map { "?device_id=\($0)" } ?? ""
        debugLog("play: track=\(trackURI) context=\(contextURI ?? "-") device=\(device ?? "-")")
        try await send("PUT", "/me/player/play" + query, body: body)
    }

    private func thisComputerDeviceID() async throws -> String? {
        let devices = (try await get("/me/player/devices")?["devices"] as? [[String: Any]]) ?? []
        debugLog("devices: \(devices.map { "\($0["name"] ?? "?")/\($0["type"] ?? "?")/active=\($0["is_active"] ?? "?")" })")
        let computers = devices.filter { ($0["type"] as? String)?.lowercased() == "computer" }
        let name = Host.current().localizedName
        let pick = computers.first { ($0["name"] as? String) == name }
            ?? computers.first { $0["is_active"] as? Bool == true }
            ?? computers.first
        return pick?["id"] as? String
    }

    /// One-line summary of the player state, for diagnostics.
    func playerSummary() async -> String {
        guard let p = try? await get("/me/player") else { return "no player (204)" }
        let device = (p["device"] as? [String: Any])?["name"] ?? "?"
        let item = (p["item"] as? [String: Any])?["uri"] ?? "?"
        let ctx = (p["context"] as? [String: Any])?["uri"] ?? "-"
        return "playing=\(p["is_playing"] ?? "?") device=\(device) item=\(item) context=\(ctx)"
    }

    private func send(_ method: String, _ path: String, body: [String: Any], retry: Bool = true) async throws {
        var req = URLRequest(url: URL(string: Self.api + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 && retry {
            _ = try await validToken(forceRefresh: true)
            return try await send(method, path, body: body, retry: false)
        }
        debugLog("\(method) \(path) → \(status) \(String(data: data, encoding: .utf8) ?? "")")
        guard !(200..<300).contains(status) else { return }
        let reason = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
            .flatMap { $0["error"] as? [String: Any] }?["reason"] as? String
        switch (status, reason) {
        case (403, "PREMIUM_REQUIRED"): throw SpotifyError.premiumRequired
        case (404, _), (_, "NO_ACTIVE_DEVICE"): throw SpotifyError.noActiveDevice
        default: throw SpotifyError.http(status)
        }
    }

    // MARK: Playback context

    /// What is playing right now and the list of tracks around it (playlist, album or queue).
    func currentContext() async throws -> PlaybackContext {
        let current = try await get("/me/player/currently-playing")
        let ctx = current?["context"] as? [String: Any]
        debugLog("currently-playing context=\(ctx?["uri"] ?? "-") item=\((current?["item"] as? [String: Any])?["uri"] ?? "-")")
        if let type = ctx?["type"] as? String, let uri = ctx?["uri"] as? String,
           let id = uri.split(separator: ":").last.map(String.init) {
            do {
                switch type {
                case "playlist": return try await playlist(id: id, uri: uri)
                case "album": return try await album(id: id, uri: uri)
                default: break // artist, liked songs, radio… → queue
                }
            } catch SpotifyError.http(let code) where code == 404 || code == 403 {
                debugLog("context \(uri) not readable (\(code)) → showing queue")
                // Spotify's own algorithmic/editorial playlists aren't readable by third-party apps.
            }
        }
        return try await queue()
    }

    private func playlist(id: String, uri: String) async throws -> PlaybackContext {
        guard let p = try await get("/playlists/\(id)") else { throw SpotifyError.badResponse }
        let title = p["name"] as? String ?? "Плейлист"
        // The tracks page is called "tracks" in the classic API and "items" in the newer one.
        var page = (p["tracks"] as? [String: Any]) ?? (p["items"] as? [String: Any])
        if page?["items"] == nil {
            do { page = try await get("/playlists/\(id)/items?limit=50") }
            catch { page = try await get("/playlists/\(id)/tracks?limit=50") }
        }
        let tracks = try await collect(firstPage: page, fallbackImage: nil)
        return PlaybackContext(uri: uri, title: title, tracks: tracks)
    }

    private func album(id: String, uri: String) async throws -> PlaybackContext {
        guard let a = try await get("/albums/\(id)") else { throw SpotifyError.badResponse }
        let image = Self.smallestImage(a["images"])
        let tracks = try await collect(firstPage: a["tracks"] as? [String: Any], fallbackImage: image)
        return PlaybackContext(uri: uri, title: a["name"] as? String ?? "Альбом", tracks: tracks)
    }

    private func queue() async throws -> PlaybackContext {
        let q = try await get("/me/player/queue")
        var raw: [[String: Any]] = []
        if let cur = q?["currently_playing"] as? [String: Any] { raw.append(cur) }
        raw += q?["queue"] as? [[String: Any]] ?? []
        let tracks = raw.enumerated().compactMap { Self.parseTrack($1, index: $0, fallbackImage: nil) }
        return PlaybackContext(uri: nil, title: "Далее в очереди", tracks: tracks)
    }

    private func collect(firstPage: [String: Any]?, fallbackImage: URL?) async throws -> [PlaylistTrack] {
        var tracks: [PlaylistTrack] = []
        var page = firstPage
        while let p = page {
            for item in p["items"] as? [[String: Any]] ?? [] {
                if let t = Self.parseTrack(item, index: tracks.count, fallbackImage: fallbackImage) { tracks.append(t) }
            }
            guard tracks.count < Self.maxTracks, let next = p["next"] as? String else { break }
            page = try await get(next)
        }
        return tracks
    }

    private static func parseTrack(_ obj: [String: Any], index: Int, fallbackImage: URL?) -> PlaylistTrack? {
        // Playlist entries wrap the track ("track" in the classic API, "item" in the newer one).
        let t = (obj["item"] as? [String: Any]) ?? (obj["track"] as? [String: Any]) ?? obj
        guard let uri = t["uri"] as? String, !uri.hasPrefix("spotify:local:"),
              let name = t["name"] as? String else { return nil }
        let artists = (t["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        let show = (t["show"] as? [String: Any])?["name"] as? String
        let album = t["album"] as? [String: Any]
        return PlaylistTrack(
            id: "\(index)-\(uri)",
            uri: uri,
            name: name,
            artist: artists?.joined(separator: ", ") ?? show ?? "",
            duration: (t["duration_ms"] as? Double ?? 0) / 1000,
            imageURL: smallestImage(album?["images"] ?? t["images"]) ?? fallbackImage
        )
    }

    private static func smallestImage(_ any: Any?) -> URL? {
        let images = any as? [[String: Any]] ?? []
        // Spotify lists images largest first; the last one is ~64px, perfect for a row thumbnail.
        return (images.last?["url"] as? String).flatMap(URL.init(string:))
    }

    private static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<n).map { _ in chars.randomElement(using: &rng)! })
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback server that catches the OAuth redirect

final class CallbackServer {
    private let port: UInt16
    private var listener: NWListener?

    init(port: UInt16) { self.port = port }

    func start(onCallback: @escaping ([String: String]) -> Void) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                // "GET /callback?code=…&state=… HTTP/1.1"
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let isCallback = path.hasPrefix("/callback")
                let body = isCallback
                    ? "<html><meta charset=utf-8><body style='font:16px -apple-system;background:#000;color:#fff;display:grid;place-items:center;height:100vh;margin:0'>NotchIsland подключён к Spotify — вкладку можно закрыть.</body></html>"
                    : ""
                let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
                guard isCallback else { return }
                var query: [String: String] = [:]
                URLComponents(string: "http://127.0.0.1" + path)?.queryItems?.forEach { query[$0.name] = $0.value }
                onCallback(query)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "local.notchisland.spotify"
    private static let account = "refresh_token"

    static var refreshToken: String? {
        get {
            var out: AnyObject?
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true]
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }
        set {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
            SecItemDelete(q as CFDictionary)
            guard let newValue else { return }
            var add = q
            add[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

// MARK: - Diagnostics log (~/Library/Logs/NotchIsland.log)

func debugLog(_ message: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/NotchIsland.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}
