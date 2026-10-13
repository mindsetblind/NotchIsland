import Foundation
import NotchIslandCore
import Security
import SwiftUI

/// Where the pet thinks. Groq answers in well under a second on a free key; Ollama runs a model on
/// this Mac; Claude Code uses your Claude subscription (slower, smartest).
enum PetProvider: String, CaseIterable, Identifiable {
    case groq, ollama, claude
    var id: String { rawValue }
    var title: String {
        switch self {
        case .groq: return "Groq (быстро, облако)"
        case .ollama: return "Ollama (на этом Mac)"
        case .claude: return "Claude Code"
        }
    }
    var short: String {
        switch self {
        case .groq: return "Groq"
        case .ollama: return "Ollama"
        case .claude: return "Claude Code"
        }
    }
}

/// API keys for model providers, in the login Keychain.
enum SecretStore {
    private static let service = "local.notchisland.pet"

    static func get(_ account: String) -> String? {
        var out: AnyObject?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func set(_ account: String, _ value: String?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Any OpenAI-compatible chat API (Groq, Ollama, LM Studio…) with a short tool loop: the model looks
/// around with list_folder / spotlight_search / read_file and finishes by calling `answer` with the plan.
/// Like with Claude Code, it only proposes — NotchIsland checks and runs the plan after you confirm.
final class OpenAICompatibleBrain: PetBrain, @unchecked Sendable {
    enum Failure: LocalizedError {
        case noKey, unreachable(String), http(Int, String), noAnswer
        var errorDescription: String? {
            switch self {
            case .noKey: return "Нужен ключ Groq: возьми его на console.groq.com/keys и вставь в Настройках → Pet-помощник"
            case .unreachable(let what): return "Нет связи с \(what)"
            case .http(let code, let message): return "Модель ответила ошибкой \(code): \(message)"
            case .noAnswer: return "Модель не дала ответа — попробуй переформулировать"
            }
        }
    }

    let name: String
    let baseURL: URL
    let apiKey: () -> String?
    let model: () async throws -> String
    let policy = PetPolicy(home: FileManager.default.homeDirectoryForCurrentUser)
    private let lock = NSLock()
    private var task: URLSessionDataTask?

    init(name: String, baseURL: URL, apiKey: @escaping () -> String?, model: @escaping () async throws -> String) {
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    func cancel() { lock.withLock { task }?.cancel() }

    func plan(_ request: String, context: PetContext) async throws -> PetPlan {
        let model = try await model()
        let started = Date()
        defer { debugLog("pet: \(name) \(model) answered in \(String(format: "%.2f", Date().timeIntervalSince(started))) s") }
        let home = policy.home.path
        var messages: [[String: Any]] = [
            ["role": "system", "content": ClaudeCodeBrain.systemPrompt(home: home, tools: "list_folder, spotlight_search, read_file") + Self.toolNote],
            ["role": "user", "content": ClaudeCodeBrain.prompt(request, context: context)],
        ]
        // A handful of look-arounds at most; each round trip is a fraction of a second on Groq.
        for round in 0..<6 {
            var body: [String: Any] = [
                "model": model, "messages": messages, "tools": Self.tools, "temperature": 0.2,
                "tool_choice": round == 5 ? ["type": "function", "function": ["name": "answer"]] as Any : "required" as Any,
            ]
            if model.contains("gpt-oss") { body["reasoning_effort"] = "low" }
            let message = try await chat(body)
            let calls = message["tool_calls"] as? [[String: Any]] ?? []
            if calls.isEmpty {
                // No tool call: take a JSON plan from the text, or the text as the reply.
                let text = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw Failure.noAnswer }
                // PetPlan.parse finds a JSON plan inside a "result" text, or uses the text as the reply.
                let wrapped = try JSONSerialization.data(withJSONObject: ["result": text])
                return (try? PetPlan.parse(cliOutput: wrapped)) ?? PetPlan(reply: text)
            }
            messages.append(message.filter { ["role", "content", "tool_calls"].contains($0.key) })
            for call in calls {
                let fn = call["function"] as? [String: Any] ?? [:]
                let name = fn["name"] as? String ?? ""
                let args = (fn["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any] ?? [:]
                if name == "answer" {
                    let data = try JSONSerialization.data(withJSONObject: args)
                    return try JSONDecoder().decode(PetPlan.self, from: data)
                }
                messages.append(["role": "tool", "tool_call_id": call["id"] as? String ?? "", "content": run(name, args)])
            }
        }
        throw Failure.noAnswer
    }

    private func chat(_ body: [String: Any]) async throws -> [String: Any] {
        let t0 = Date()
        defer { debugLog("pet:   \(name) round trip \(String(format: "%.2f", Date().timeIntervalSince(t0))) s") }
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = apiKey() { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    let t = URLSession.shared.dataTask(with: req) { d, r, e in
                        if let e { cont.resume(throwing: e) } else { cont.resume(returning: (d ?? Data(), r!)) }
                    }
                    lock.withLock { task = t }
                    t.resume()
                }
            } onCancel: { [weak self] in self?.cancel() }
        } catch let e as URLError where e.code != .cancelled {
            throw Failure.unreachable(name)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? String(decoding: data.prefix(200), as: UTF8.self)
            debugLog("pet: \(name) HTTP \(status): \(message)")
            throw Failure.http(status, message)
        }
        guard let choice = (json?["choices"] as? [[String: Any]])?.first, let message = choice["message"] as? [String: Any] else {
            throw Failure.noAnswer
        }
        return message
    }

    // MARK: Tools (home folder only, never Library or hidden files)

    static let toolNote = """

    Инструменты: list_folder — что лежит в папке; spotlight_search — найти файлы по имени или содержимому; \
    read_file — начало текстового файла. Закончив, ОБЯЗАТЕЛЬНО вызови answer с планом (reply, files, actions, music).
    """

    static let tools: [[String: Any]] = {
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "function", "function": ["name": name, "description": description,
                                              "parameters": ["type": "object", "properties": properties, "required": required]]]
        }
        let plan = (try? JSONSerialization.jsonObject(with: Data(PetPlan.jsonSchema.utf8))) as? [String: Any] ?? [:]
        return [
            tool("list_folder", "Список файлов и папок (имя, тип, размер, дата изменения).", ["path": ["type": "string"]], ["path"]),
            tool("spotlight_search", "Поиск файлов через Spotlight по имени (или по содержимому, если content=true).",
                 ["query": ["type": "string"], "folder": ["type": "string"], "content": ["type": "boolean"]], ["query"]),
            tool("read_file", "Первые ~4000 символов текстового файла.", ["path": ["type": "string"]], ["path"]),
            ["type": "function", "function": ["name": "answer", "description": "Финальный ответ: план для пользователя.", "parameters": plan]],
        ]
    }()

    func run(_ name: String, _ args: [String: Any]) -> String {
        let fm = FileManager.default
        switch name {
        case "list_folder":
            guard let url = (args["path"] as? String).flatMap(policy.resolve) else { return "Недоступно: только домашняя папка." }
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: .skipsHiddenFiles) else {
                return "Не получилось открыть папку."
            }
            let df = ISO8601DateFormatter()
            let lines = items.prefix(300).map { item -> String in
                let v = try? item.resourceValues(forKeys: Set(keys))
                let kind = v?.isDirectory == true ? "папка" : "\(v?.fileSize ?? 0) Б"
                return "\(item.lastPathComponent)\t\(kind)\t\(v?.contentModificationDate.map(df.string) ?? "")"
            }
            return "\(url.path) — \(items.count) шт.\n" + lines.joined(separator: "\n")
        case "spotlight_search":
            guard let query = args["query"] as? String, !query.isEmpty else { return "Пустой запрос." }
            let folder = (args["folder"] as? String).flatMap(policy.resolve) ?? policy.home
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            p.arguments = (args["content"] as? Bool == true) ? ["-onlyin", folder.path, query] : ["-onlyin", folder.path, "-name", query]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return "Spotlight недоступен." }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let paths = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { policy.resolve($0) != nil }
            return paths.isEmpty ? "Ничего не найдено." : paths.prefix(60).joined(separator: "\n")
        case "read_file":
            guard let url = (args["path"] as? String).flatMap(policy.resolve),
                  let handle = try? FileHandle(forReadingFrom: url) else { return "Не получилось прочитать." }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 16_000)) ?? Data()
            guard let text = String(data: data, encoding: .utf8) else { return "Это не текстовый файл." }
            return String(text.prefix(4000))
        default:
            return "Нет такого инструмента."
        }
    }
}

/// Picks the brain from Settings for every request (Claude Code keeps its warm spare process).
final class RoutingBrain: PetBrain, @unchecked Sendable {
    let claude: ClaudeCodeBrain
    let groq: OpenAICompatibleBrain
    let ollama: OpenAICompatibleBrain
    private var current: PetBrain?

    init(claude: ClaudeCodeBrain) {
        self.claude = claude
        groq = OpenAICompatibleBrain(name: "Groq", baseURL: URL(string: "https://api.groq.com/openai/v1")!,
                                     apiKey: { SecretStore.get("groq") },
                                     model: { try await GroqModels.pick() })
        ollama = OpenAICompatibleBrain(name: "Ollama", baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
                                       apiKey: { nil },
                                       model: { await MainActor.run { AppSettings.shared.petOllamaModel } })
    }

    private func brain() -> PetBrain {
        switch AppSettings.shared.petProvider {
        case .groq: return groq
        case .ollama: return ollama
        case .claude: return claude
        }
    }

    func plan(_ request: String, context: PetContext) async throws -> PetPlan {
        let b = await MainActor.run { brain() }
        current = b
        if b === groq, SecretStore.get("groq") == nil { throw OpenAICompatibleBrain.Failure.noKey }
        return try await b.plan(request, context: context)
    }

    func cancel() { current?.cancel() }

    func prewarm() {
        // Read straight from defaults: this runs on a background queue.
        if UserDefaults.standard.string(forKey: "petProvider") == PetProvider.claude.rawValue { claude.prewarm() }
    }

    func release() { claude.release() }
}

/// Groq's model list changes over time: use the chosen one, else the best available of a short list.
enum GroqModels {
    static let preferred = ["openai/gpt-oss-120b", "llama-3.3-70b-versatile", "moonshotai/kimi-k2-instruct", "qwen/qwen3-32b"]
    nonisolated(unsafe) private static var cached: [String]?

    static func available() async throws -> [String] {
        if let cached { return cached }
        guard let key = SecretStore.get("groq") else { throw OpenAICompatibleBrain.Failure.noKey }
        var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OpenAICompatibleBrain.Failure.http((response as? HTTPURLResponse)?.statusCode ?? 0, "не удалось получить список моделей (ключ верный?)")
        }
        let ids = (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [[String: Any]] ?? [])
            .compactMap { $0["id"] as? String }.sorted()
        cached = ids
        return ids
    }

    static func pick() async throws -> String {
        let chosen = await MainActor.run { AppSettings.shared.petGroqModel }
        if !chosen.isEmpty { return chosen }
        let ids = (try? await available()) ?? []
        return preferred.first(where: ids.contains) ?? preferred[0]
    }

    static func forget() { cached = nil }
}


/// Settings rows: provider, Groq key and model, Ollama model, Claude model.
struct PetBrainSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var key = SecretStore.get("groq") ?? ""
    @State private var models: [String] = []
    @State private var status = ""

    var body: some View {
        Picker("Мозг", selection: $settings.petProvider) {
            ForEach(PetProvider.allCases) { Text($0.title).tag($0) }
        }
        switch settings.petProvider {
        case .groq:
            SecureField("Ключ Groq", text: $key, prompt: Text("gsk_…"))
                .onSubmit(saveKey)
                .onChange(of: key) { _, _ in status = "" }
            HStack {
                Link("Получить бесплатный ключ", destination: URL(string: "https://console.groq.com/keys")!)
                Spacer()
                if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.secondary) }
                Button("Сохранить и проверить", action: saveKey)
            }
            Picker("Модель", selection: $settings.petGroqModel) {
                Text("Автоматически").tag("")
                ForEach(models.filter { !$0.contains("whisper") && !$0.contains("tts") && !$0.contains("guard") }, id: \.self) { Text($0).tag($0) }
            }
            .task { await loadModels() }
            Text("Groq отвечает за доли секунды; бесплатного ключа хватает с запасом. Запрос и имена файлов, которые pet смотрит, уходят в Groq.")
                .font(.callout).foregroundStyle(.secondary)
        case .ollama:
            TextField("Модель Ollama", text: $settings.petOllamaModel, prompt: Text("qwen2.5:7b"))
            Text("Всё работает на этом Mac, без интернета. Установи Ollama (ollama.com) и скачай модель командой «ollama pull \(settings.petOllamaModel)».")
                .font(.callout).foregroundStyle(.secondary)
        case .claude:
            Picker("Модель", selection: $settings.petModel) {
                Text("Sonnet — точнее").tag("sonnet")
                Text("Haiku — быстрее").tag("haiku")
            }
            Text("Использует твою подписку Claude (нужен вход: claude auth login). Медленнее, зато умнее всех.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func saveKey() {
        SecretStore.set("groq", key)
        GroqModels.forget()
        status = "Проверяю…"
        Task { await loadModels() }
    }

    private func loadModels() async {
        guard SecretStore.get("groq") != nil else { status = key.isEmpty ? "" : status; return }
        do {
            models = try await GroqModels.available()
            status = "Ключ работает ✓"
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? "Ошибка"
        }
    }
}
