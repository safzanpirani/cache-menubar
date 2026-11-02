import Foundation

struct ProcessResult {
    let status: Int32
    let output: Data
    let error: String
}

/// Drain both pipes while the child runs, and bound the entire operation.
/// Completion always runs on the main queue, including launch failures.
func runProcess(_ executable: String, arguments: [String], timeout: Double = 10,
                done: @escaping (ProcessResult) -> Void) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe(), errors = Pipe()
    process.standardOutput = output; process.standardError = errors
    do { try process.run() } catch {
        DispatchQueue.main.async { done(ProcessResult(status: -1, output: Data(), error: error.localizedDescription)) }
        return
    }
    for handle in [output.fileHandleForReading, errors.fileHandleForReading] {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }
    DispatchQueue.global().async {
        var stdout = Data(), stderr = Data()
        var failure: String?
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func drain(_ handle: FileHandle, into data: inout Data) {
            var buffer = [UInt8](repeating: 0, count: 65536)
            // Bound each pass so a continuously writing process cannot prevent
            // deadline checks. Also bound retained output from a broken source.
            for _ in 0..<16 {
                let count = read(handle.fileDescriptor, &buffer, buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
                if data.count > 8 * 1024 * 1024 { failure = "process output exceeded 8 MiB"; break }
            }
        }
        while true {
            drain(output.fileHandleForReading, into: &stdout)
            drain(errors.fileHandleForReading, into: &stderr)
            if !process.isRunning { break }
            if ProcessInfo.processInfo.systemUptime >= deadline { failure = "process exceeded its \(timeout)s deadline" }
            if failure != nil {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // A descendant may retain a pipe after the direct child exits. Read
        // only available bytes, then close; never wait for that descendant's EOF.
        drain(output.fileHandleForReading, into: &stdout)
        drain(errors.fileHandleForReading, into: &stderr)
        output.fileHandleForReading.closeFile(); errors.fileHandleForReading.closeFile()
        let result = ProcessResult(status: failure == nil ? process.terminationStatus : -1,
                                   output: stdout, error: failure ?? String(data: stderr, encoding: .utf8) ?? "")
        DispatchQueue.main.async { done(result) }
    }
}

/// Invalidated callbacks cannot clear or overwrite a newer request's state.
struct PollRequests {
    private var requests: [String: UUID] = [:]
    mutating func start(_ key: String) -> UUID? {
        guard requests[key] == nil else { return nil }
        let id = UUID(); requests[key] = id; return id
    }
    mutating func finish(_ key: String, _ id: UUID) -> Bool {
        guard requests[key] == id else { return false }
        requests.removeValue(forKey: key); return true
    }
    mutating func cancel(_ key: String) { requests.removeValue(forKey: key) }
    mutating func cancelAll() { requests.removeAll() }
}

/// Keep marks for each session's current turn, without resetting other sessions.
struct ReminderHistory {
    private var sessions: [String: (at: Date, marks: Set<String>)] = [:]

    mutating func retain(_ keys: Set<String>) {
        sessions = sessions.filter { keys.contains($0.key) }
    }

    mutating func consume(_ key: String, at: Date, mark: String) -> Bool {
        if sessions[key]?.at != at { sessions[key] = (at, []) }
        return sessions[key]!.marks.insert(mark).inserted
    }
}

struct ChatRequestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// HTTP errors must not masquerade as a successful refresh or warm action.
func runChatRequest(_ request: URLRequest, session: URLSession = .shared,
                    done: @escaping (Result<Data, Error>) -> Void) {
    var request = request
    request.timeoutInterval = 5
    session.dataTask(with: request) { data, response, error in
        let result: Result<Data, Error>
        if let error = error {
            result = .failure(error)
        } else if let response = response as? HTTPURLResponse {
            if (200..<300).contains(response.statusCode) {
                result = .success(data ?? Data())
            } else {
                result = .failure(ChatRequestError(message: "Chat server returned HTTP \(response.statusCode)"))
            }
        } else {
            result = .failure(ChatRequestError(message: "Chat server did not return an HTTP response"))
        }
        DispatchQueue.main.async { done(result) }
    }.resume()
}

/// A running herdr TUI client: its own pid, its parent chain (up to launchd), and the kitty window it runs in.
struct HerdrClient: Equatable {
    let pid: Int32
    let ancestors: [Int32]
    let kittySocket: String?, kittyWindow: String?
}

/// Finds the herdr client for a host in `/bin/ps -axwwE -o pid=,ppid=,command=` output, where each command is
/// followed by its environment. `remote` nil: the local client (`herdr` or `herdr --session NAME`). Otherwise the
/// client attached with `herdr --remote <remote>`. Helper processes (`herdr client`, `herdr server`, API calls) never match.
func findHerdrClient(_ table: String, remote: String?) -> HerdrClient? {
    var parent: [Int32: Int32] = [:]
    var found: (pid: Int32, env: [Substring])?
    for line in table.split(separator: "\n") {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { continue }
        parent[pid] = ppid
        guard found == nil, fields[2].split(separator: "/").last == "herdr" else { continue }
        let rest = fields.dropFirst(3)
        let envStart = rest.firstIndex { $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil } ?? rest.endIndex
        let args = Array(rest[..<envStart])
        let matches: Bool
        if let remote = remote {
            matches = args.firstIndex(of: "--remote").map { $0 + 1 < args.count && args[$0 + 1] == Substring(remote) } ?? false
        } else {
            matches = args.isEmpty || (args.count == 2 && args[0] == "--session")
        }
        if matches { found = (pid, Array(rest[envStart...])) }
    }
    guard let (pid, env) = found else { return nil }
    var ancestors: [Int32] = []
    var current = parent[pid]
    while let p = current, p > 1, !ancestors.contains(p) { ancestors.append(p); current = parent[p] }
    func value(_ key: String) -> String? { env.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) } }
    return HerdrClient(pid: pid, ancestors: ancestors, kittySocket: value("KITTY_LISTEN_ON"), kittyWindow: value("KITTY_WINDOW_ID"))
}
