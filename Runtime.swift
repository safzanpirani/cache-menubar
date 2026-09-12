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
