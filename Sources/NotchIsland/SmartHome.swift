import AppKit
import CryptoKit
import NotchIslandCore
import SwiftUI

enum SmartHomeError: LocalizedError {
    case noClientID, notLoggedIn, offline, http(Int), api(String)

    var errorDescription: String? {
        switch self {
        case .noClientID: return "Не задан ClientID приложения Яндекса — укажи его в Настройках → Дом"
        case .notLoggedIn: return "Нужно войти в Яндекс в Настройках → Дом"
        case .offline: return "Нет соединения с Яндексом — проверь интернет"
        case .http(403): return "Яндекс отказал в доступе (403). Проверь, что у приложения на oauth.yandex.ru есть права «Умный дом»."
        case .http(let c): return "Ошибка Яндекса (\(c))"
        case .api(let m): return "Яндекс: \(m)"
        }
    }
}

// MARK: - Yandex OAuth (PKCE, no client secret) + Smart Home API

final class YandexSmartHome {
    static let port: UInt16 = 8974
    static let redirectURI = "http://127.0.0.1:\(port)/callback"
    static let scopes = "iot:view iot:control"
    private static let clientIDKey = "yandexClientID"
    private static let expiresKey = "yandexTokenExpires"
    private static let api = "https://api.iot.yandex.net/v1.0"

    var clientID: String? {
        get { UserDefaults.standard.string(forKey: Self.clientIDKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue?.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.clientIDKey) }
    }

    var isLoggedIn: Bool { SecretStore.get("yandex-access") != nil }

    private var server: CallbackServer?
    private var loginTimeout: DispatchWorkItem?

    func login(completion: @escaping (Error?) -> Void) {
        guard let clientID else { return completion(SmartHomeError.noClientID) }
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(16)

        server?.stop()
        let server = CallbackServer(port: Self.port, serviceName: "Яндексу")
        self.server = server
        do {
            try server.start { [weak self] query in
                guard let self else { return }
                server.stop()
                guard query["state"] == state, let code = query["code"] else {
                    return completion(SmartHomeError.api(query["error_description"] ?? "вход отменён"))
                }
                Task { @MainActor in
                    do {
                        try await self.requestToken(["grant_type": "authorization_code", "code": code,
                                                     "client_id": clientID, "code_verifier": verifier])
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            }
        } catch {
            return completion(error)
        }
        loginTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak server] in server?.stop() }
        loginTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: timeout)

        var c = URLComponents(string: "https://oauth.yandex.ru/authorize")!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "scope", value: Self.scopes),
            .init(name: "force_confirm", value: "yes"),
        ]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    // Login by code: for apps whose Callback URL is Yandex's own debug page. Yandex shows a code there,
    // the user pastes it into Settings and we exchange it with the PKCE verifier.
    static let codePageURI = "https://oauth.yandex.ru/verification_code"
    private var pendingVerifier: String?

    func startCodeLogin() throws {
        guard let clientID else { throw SmartHomeError.noClientID }
        let verifier = Self.randomString(64)
        pendingVerifier = verifier
        var c = URLComponents(string: "https://oauth.yandex.ru/authorize")!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: Self.codePageURI),
            .init(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "scope", value: Self.scopes),
            .init(name: "force_confirm", value: "yes"),
        ]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    func finishCodeLogin(_ code: String) async throws {
        guard let clientID else { throw SmartHomeError.noClientID }
        guard let verifier = pendingVerifier else { throw SmartHomeError.api("сначала нажми «Получить код»") }
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw SmartHomeError.api("вставь код со страницы Яндекса") }
        try await requestToken(["grant_type": "authorization_code", "code": code,
                                "client_id": clientID, "code_verifier": verifier])
        pendingVerifier = nil
    }

    func logout() {
        SecretStore.set("yandex-access", nil)
        SecretStore.set("yandex-refresh", nil)
        UserDefaults.standard.removeObject(forKey: Self.expiresKey)
    }

    private func requestToken(_ form: [String: String]) async throws {
        var req = URLRequest(url: URL(string: "https://oauth.yandex.ru/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = c.percentEncodedQuery?.data(using: .utf8)
        let (data, status) = try await perform(req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, let token = json?["access_token"] as? String else {
            debugLog("yandex token: \(status) \(json?["error"] ?? "")")
            if status == 400 || status == 401 { logout(); throw SmartHomeError.notLoggedIn }
            throw SmartHomeError.http(status)
        }
        SecretStore.set("yandex-access", token)
        if let refresh = json?["refresh_token"] as? String { SecretStore.set("yandex-refresh", refresh) }
        let expires = Date().addingTimeInterval((json?["expires_in"] as? Double ?? 365 * 86400) - 86400)
        UserDefaults.standard.set(expires.timeIntervalSince1970, forKey: Self.expiresKey)
    }

    /// Yandex tokens live about a year; refresh a day before that.
    private func validToken() async throws -> String {
        guard let token = SecretStore.get("yandex-access") else { throw SmartHomeError.notLoggedIn }
        let expires = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: Self.expiresKey))
        guard Date() > expires, let refresh = SecretStore.get("yandex-refresh"), let clientID else { return token }
        try await requestToken(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        return SecretStore.get("yandex-access") ?? token
    }

    private func perform(_ req: URLRequest) async throws -> (Data, Int) {
        var req = req
        req.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code) {
            throw SmartHomeError.offline
        }
    }

    private func call(_ path: String, body: Data? = nil) async throws -> Data {
        var req = URLRequest(url: URL(string: Self.api + path)!)
        req.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let (data, status) = try await perform(req)
        if status == 401 { logout(); throw SmartHomeError.notLoggedIn }
        guard (200..<300).contains(status) else { throw SmartHomeError.http(status) }
        return data
    }

    func snapshot() async throws -> HomeSnapshot {
        do {
            return try YandexHome.parseUserInfo(try await call("/user/info"))
        } catch YandexHomeError.api(let m) {
            throw SmartHomeError.api(m)
        }
    }

    func runScenario(_ id: String) async throws {
        _ = try await call("/scenarios/\(id)/actions", body: Data("{}".utf8))
    }

    /// Sends commands; returns the lamps the hub couldn't reach.
    func send(_ commands: [(lampID: String, action: LampAction)]) async throws -> [String] {
        YandexHome.failedLamps(try await call("/devices/actions", body: YandexHome.actionsBody(commands)))
    }

    private static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<n).map { _ in chars.randomElement()! })
    }
}

// MARK: - State for the Home panel

@MainActor
final class SmartHomeController: ObservableObject {
    static let shared = SmartHomeController()

    let yandex = YandexSmartHome()
    @Published private(set) var snapshot = HomeSnapshot()
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var loggedIn: Bool
    @Published private(set) var hasClientID: Bool
    /// Lamps the hub reported as unreachable on the last command.
    @Published private(set) var unreachable: Set<String> = []

    private var poll: Timer?
    /// After a command, polling must not briefly show the old state the cloud still reports.
    private var holdUntil: [String: Date] = [:]
    private var sliderTask: Task<Void, Never>?

    /// Rooms and lamps placed by hand in the plan editor (UserDefaults "homeLayout").
    @Published private(set) var layout: HomeLayout
    var plan: HomePlan { HomePlan.make(snapshot, layout: layout) }

    private init() {
        loggedIn = yandex.isLoggedIn
        hasClientID = yandex.clientID != nil
        layout = UserDefaults.standard.data(forKey: "homeLayout")
            .flatMap { try? JSONDecoder().decode(HomeLayout.self, from: $0) } ?? HomeLayout()
    }

    func editLayout(_ change: (inout HomeLayout) -> Void) {
        change(&layout)
        UserDefaults.standard.set(try? JSONEncoder().encode(layout), forKey: "homeLayout")
    }

    func resetLayout() { editLayout { $0 = HomeLayout() } }

    /// Snapshots only: a made-up flat without a Yandex login.
    func showSample(_ sample: HomeSnapshot) {
        loggedIn = true
        snapshot = sample
    }

    func setClientID(_ id: String) {
        yandex.clientID = id
        hasClientID = yandex.clientID != nil
    }

    func login() {
        error = nil
        yandex.login { [weak self] error in
            guard let self else { return }
            self.loggedIn = self.yandex.isLoggedIn
            self.error = error?.localizedDescription
            if error == nil { self.refresh() }
        }
    }

    /// Waiting for the code from Yandex's page (login by code).
    @Published private(set) var awaitingCode = false

    func startCodeLogin() {
        error = nil
        do {
            try yandex.startCodeLogin()
            awaitingCode = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func finishCodeLogin(_ code: String) {
        Task {
            do {
                try await yandex.finishCodeLogin(code)
                awaitingCode = false
                loggedIn = yandex.isLoggedIn
                error = nil
                refresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func logout() {
        yandex.logout()
        loggedIn = false
        snapshot = HomeSnapshot()
    }

    /// Keeps the state fresh while the panel is visible.
    func startPolling() {
        refresh()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(quiet: true) }
        }
    }

    func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    func refresh(quiet: Bool = false) {
        guard loggedIn, !loading else { return }
        if !quiet { loading = true }
        Task {
            defer { loading = false }
            do {
                var fresh = try await yandex.snapshot()
                // Keep what we just commanded until the cloud catches up.
                let now = Date()
                for (id, until) in holdUntil where until > now {
                    if let mine = snapshot.lamps.first(where: { $0.id == id }), let i = fresh.lamps.firstIndex(where: { $0.id == id }) {
                        fresh.lamps[i] = mine
                    }
                }
                holdUntil = holdUntil.filter { $0.value > now }
                snapshot = fresh
                error = nil
            } catch SmartHomeError.notLoggedIn {
                loggedIn = false
                error = SmartHomeError.notLoggedIn.localizedDescription
            } catch {
                if !quiet || snapshot.lamps.isEmpty { self.error = error.localizedDescription }
            }
        }
    }

    func toggle(_ lampID: String) {
        guard let lamp = snapshot.lamps.first(where: { $0.id == lampID }) else { return }
        apply([(lampID, .power(!(lamp.isOn ?? false)))])
    }

    /// Room label: everything on if anything is off, otherwise everything off.
    func toggleRoom(_ roomID: String) {
        let known = Set(snapshot.rooms.map(\.id))
        let lamps = snapshot.lamps.filter { lamp in (lamp.roomID.flatMap { known.contains($0) ? $0 : nil } ?? HomePlan.noRoomID) == roomID }
        let turnOn = lamps.contains { $0.isOn != true }
        apply(lamps.map { ($0.id, .power(turnOn)) })
    }

    func allOff() {
        apply(snapshot.lamps.filter { $0.isOn == true }.map { ($0.id, .power(false)) })
    }

    /// Slider moves: the plan follows at once, the hub gets the last value after a short pause.
    func set(_ action: LampAction, for lampID: String) {
        snapshot = YandexHome.applying(action, to: lampID, in: snapshot)
        holdUntil[lampID] = Date().addingTimeInterval(8)
        sliderTask?.cancel()
        sliderTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await send([(lampID, action)])
        }
    }

    func apply(_ commands: [(lampID: String, action: LampAction)]) {
        guard !commands.isEmpty else { return }
        Usage.track(.lampToggled)
        for (id, action) in commands {
            snapshot = YandexHome.applying(action, to: id, in: snapshot)
            holdUntil[id] = Date().addingTimeInterval(8)
        }
        Task { await send(commands) }
    }

    private func send(_ commands: [(lampID: String, action: LampAction)]) async {
        do {
            let failed = try await yandex.send(commands)
            unreachable.subtract(commands.map(\.lampID))
            unreachable.formUnion(failed)
            error = failed.isEmpty ? nil : "Хаб не достучался до \(failed.count == 1 ? "лампы" : "\(failed.count) ламп") — она в сети?"
        } catch SmartHomeError.notLoggedIn {
            loggedIn = false
            error = SmartHomeError.notLoggedIn.localizedDescription
        } catch {
            self.error = error.localizedDescription
            // The command didn't go through: show the real state again.
            for (id, _) in commands { holdUntil[id] = nil }
            refresh(quiet: true)
        }
    }
}
