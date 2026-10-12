// notchisland-cli — report long-running tasks to NotchIsland's Developer Mode.
//
//   notchisland-cli run [--id ID] [--title T] [--category C] -- <command> [args…]
//   notchisland-cli start <id> [--title T] [--category C] [--message M]
//   notchisland-cli progress <id> <0…1 | NN%> [--message M]
//   notchisland-cli message <id> <text>
//   notchisland-cli finish <id> (--status success|failure|cancelled | --exit-code N) [--message M]
//
// Events go to the island over its local Unix socket (owner-only). If the island isn't running or
// Developer Mode is off, nothing happens and the tool still succeeds — your scripts never break
// because of it. `run` executes *your* command here, in your shell's context; the island itself
// never executes anything it receives.
import Foundation

let usage = """
usage:
  notchisland-cli run [--id ID] [--title T] [--category C] -- <command> [args…]
  notchisland-cli start <id> [--title T] [--category C] [--message M]
  notchisland-cli progress <id> <0…1 | NN%> [--message M]
  notchisland-cli message <id> <text>
  notchisland-cli finish <id> (--status success|failure|cancelled | --exit-code N) [--message M]

categories: build, test, script, server, deploy, other
options: --quiet (no warnings), --verbose (print the island's answer)
"""

let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/NotchIsland/claude.sock").path

var quiet = false
var verbose = false

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("notchisland-cli: \(message)\n\(usage)".utf8))
    exit(64)   // EX_USAGE
}

func warn(_ message: String) {
    guard !quiet else { return }
    FileHandle.standardError.write(Data("notchisland-cli: \(message)\n".utf8))
}

/// Sends one event; returns the island's answer if it gave one. Never throws: the island being
/// away is normal.
@discardableResult
func send(_ event: [String: Any]) -> [String: Any]? {
    var payload = event
    payload["v"] = 1
    payload["type"] = "task"
    guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
    data.append(0x0A)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else {
        if verbose { warn("NotchIsland isn't running — event dropped") }
        return nil
    }
    _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while response.count < 8192 {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        response.append(contentsOf: buffer[0..<n])
        if buffer[0..<n].contains(0x0A) { break }
    }
    let answer = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any]
    if let answer, answer["ok"] as? Bool == false, let error = answer["error"] as? String {
        warn(error)
    } else if verbose, let answer {
        warn("island: \(answer)")
    }
    return answer
}

// MARK: Argument parsing

var args = Array(CommandLine.arguments.dropFirst())
args.removeAll { arg in
    if arg == "--quiet" || arg == "-q" { quiet = true; return true }
    if arg == "--verbose" || arg == "-v" { verbose = true; return true }
    return false
}
guard let command = args.first else { fail("missing command") }
args.removeFirst()
if command == "-h" || command == "--help" || command == "help" {
    print(usage)
    exit(0)
}

/// Pulls `--name value` pairs out of the arguments (up to a `--` separator).
func options(_ names: Set<String>) -> [String: String] {
    var result: [String: String] = [:]
    var i = 0
    while i < args.count, args[i] != "--" {
        let name = args[i].hasPrefix("--") ? String(args[i].dropFirst(2)) : ""
        if names.contains(name) {
            guard i + 1 < args.count else { fail("--\(name) needs a value") }
            result[name] = args[i + 1]
            args.removeSubrange(i...(i + 1))
        } else if args[i].hasPrefix("--") {
            fail("unknown option \(args[i])")
        } else {
            i += 1
        }
    }
    return result
}

func positional(_ what: String) -> String {
    guard let first = args.first, first != "--" else { fail("missing \(what)") }
    args.removeFirst()
    return first
}

func progressValue(_ s: String) -> Double {
    if s.hasSuffix("%"), let p = Double(s.dropLast()) { return p / 100 }
    guard let p = Double(s) else { fail("progress must be 0…1 or NN%") }
    return p
}

let categories: Set<String> = ["build", "test", "script", "server", "deploy", "other"]

func validatedCategory(_ c: String?) -> String? {
    guard let c else { return nil }
    guard categories.contains(c) else { fail("unknown category \(c)") }
    return c
}

func base(_ event: String, _ id: String, _ opts: [String: String]) -> [String: Any] {
    var e: [String: Any] = ["event": event, "id": id, "source": "notchisland-cli"]
    if let t = opts["title"] { e["title"] = t }
    if let c = validatedCategory(opts["category"]) { e["category"] = c }
    if let m = opts["message"] { e["message"] = m }
    return e
}

switch command {
case "start":
    let opts = options(["title", "category", "message"])
    send(base("start", positional("task id"), opts))

case "progress":
    let opts = options(["message"])
    let id = positional("task id")
    var e = base("progress", id, opts)
    e["progress"] = progressValue(positional("progress"))
    send(e)

case "message":
    let id = positional("task id")
    send(base("message", id, ["message": args.joined(separator: " ")]))

case "finish":
    let opts = options(["status", "exit-code", "message"])
    var e = base("finish", positional("task id"), opts)
    if let s = opts["status"] {
        guard ["success", "failure", "cancelled"].contains(s) else { fail("status must be success, failure or cancelled") }
        e["status"] = s
    }
    if let c = opts["exit-code"] {
        guard let code = Int(c) else { fail("--exit-code must be a number") }
        e["exit_code"] = code
    }
    guard e["status"] != nil || e["exit_code"] != nil else { fail("finish needs --status or --exit-code") }
    send(e)

case "run":
    let opts = options(["id", "title", "category"])
    guard let sep = args.firstIndex(of: "--"), sep + 1 < args.count else { fail("run needs: -- <command> [args…]") }
    let commandLine = Array(args[(sep + 1)...])
    let title = opts["title"] ?? commandLine.joined(separator: " ")
    // A stable default ID per command, so re-running replaces the previous entry.
    let slug = commandLine.prefix(2).joined(separator: "-").unicodeScalars
        .map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
    let id = opts["id"] ?? String(("run-" + slug).prefix(64))
    var start = base("start", id, ["title": title])
    if let c = validatedCategory(opts["category"]) { start["category"] = c } else { start["category"] = "script" }
    send(start)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = commandLine
    // Ctrl-C reaches the whole process group: let the child handle it, then report "cancelled".
    signal(SIGINT, SIG_IGN)
    do {
        try process.run()
    } catch {
        send(["event": "finish", "id": id, "status": "failure", "message": "could not start: \(commandLine[0])"])
        FileHandle.standardError.write(Data("notchisland-cli: could not start \(commandLine[0]): \(error.localizedDescription)\n".utf8))
        exit(127)
    }
    process.waitUntilExit()
    let code = process.terminationStatus
    var finish: [String: Any] = ["event": "finish", "id": id]
    if process.terminationReason == .uncaughtSignal {
        finish["status"] = code == SIGINT ? "cancelled" : "failure"
        finish["message"] = code == SIGINT ? "прервано" : "сигнал \(code)"
        send(finish)
        exit(128 + code)
    }
    finish["exit_code"] = Int(code)
    send(finish)
    exit(code)

default:
    fail("unknown command \(command)")
}
exit(0)
