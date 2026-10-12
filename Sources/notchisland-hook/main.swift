// notchisland-hook — bridge between Claude Code hooks and NotchIsland.
//
// Claude Code runs this on every hook event with the event JSON on stdin. It forwards the event to
// the running island over a Unix socket. For PermissionRequest it waits for the island's answer and
// prints it (Claude Code reads the decision from stdout). If the island isn't running, or anything
// goes wrong, it exits 0 with no output, so Claude Code simply carries on as usual — never blocked.
import Foundation

let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/NotchIsland/claude.sock").path

func quietExit() -> Never { exit(0) }

let input = FileHandle.standardInput.readDataToEndOfFile()
guard var event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { quietExit() }

/// Parent process chain, so the island can bring the right terminal/app window to the front.
func ancestorPIDs() -> [Int32] {
    var pids: [Int32] = []
    var pid = getppid()
    while pid > 1, pids.count < 16 {
        pids.append(pid)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
        pid = info.kp_eproc.e_ppid
    }
    return pids
}
event["ancestor_pids"] = ancestorPIDs()

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { quietExit() }
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8CString)
guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { quietExit() }
withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    pathBytes.withUnsafeBytes { raw.copyMemory(from: $0) }
}
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else { quietExit() }   // island not running

guard var payload = try? JSONSerialization.data(withJSONObject: event) else { quietExit() }
payload.append(0x0A)
_ = payload.withUnsafeBytes { write(fd, $0.baseAddress, payload.count) }

guard event["hook_event_name"] as? String == "PermissionRequest" else {
    close(fd)
    quietExit()
}

// Wait for the decision line (the island closes the socket without one = "answer in the terminal").
var response = Data()
var buffer = [UInt8](repeating: 0, count: 4096)
while true {
    let n = read(fd, &buffer, buffer.count)
    if n <= 0 { break }
    response.append(contentsOf: buffer[0..<n])
    if buffer[0..<n].contains(0x0A) { break }
}
close(fd)
if let line = String(data: response, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
   !line.isEmpty, line != "{}" {
    print(line)
}
exit(0)
