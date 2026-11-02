import Foundation

final class ChatProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url!.path == "/timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        let status = Int(request.url!.lastPathComponent)!
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status != 204 { client?.urlProtocol(self, didLoad: Data("[]".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct RuntimeTests {
    static func require(_ value: Bool, _ message: String) {
        if !value { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
    }

    static func run(_ executable: String, _ arguments: [String], timeout: Double = 2) -> ProcessResult {
        var result: ProcessResult?
        var completions = 0
        runProcess(executable, arguments: arguments, timeout: timeout) {
            result = $0; completions += 1
        }
        let deadline = Date().addingTimeInterval(timeout + 2)
        while result == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        require(result != nil, "process completion was not delivered")
        require(completions == 1, "process completed more than once")
        return result!
    }

    static func main() {
        let large = run("/bin/sh", ["-c", "head -c 400000 /dev/zero; head -c 400000 /dev/zero >&2"])
        require(large.status == 0 && large.output.count == 400000 && large.error.count == 400000,
                "large stdout/stderr must drain without a pipe deadlock: status=\(large.status), out=\(large.output.count), errBytes=\(large.error.count)")

        let start = Date()
        let stalled = run("/bin/sleep", ["5"], timeout: 0.15)
        require(stalled.status != 0 && stalled.error.contains("deadline") && Date().timeIntervalSince(start) < 2,
                "a stalled child must release the poll")

        let inheritedStart = Date()
        let inherited = run("/bin/sh", ["-c", "(sleep 1) & exit 0"])
        require(inherited.status == 0 && Date().timeIntervalSince(inheritedStart) < 0.8,
                "an inherited pipe must not keep completion waiting for EOF")

        require(run("/nonexistent/cache-menubar-test", []).status != 0, "launch failure must complete")
        let literal = "pane'; echo unintended-command"
        let argument = run("/bin/sh", ["-c", "printf '%s' \"$1\"", "fixture", literal])
        require(String(data: argument.output, encoding: .utf8) == literal, "arguments must remain literal")

        var polls = PollRequests()
        let old = polls.start("chat")!
        require(polls.start("chat") == nil, "duplicate polls must be prevented")
        polls.cancel("chat")
        let current = polls.start("chat")!
        require(!polls.finish("chat", old), "a stale callback must not overwrite the new source")
        require(polls.start("chat") == nil, "a stale callback must not release a newer request")
        require(polls.finish("chat", current), "the current callback must complete")
        let remote = polls.start("remote:chat")!
        require(polls.start("chat") != nil, "a host named chat must not collide with the HTTP source")
        polls.cancelAll()
        require(!polls.finish("remote:chat", remote) && polls.start("remote:chat") != nil,
                "changed host settings must invalidate old polls")
        var reminders = ReminderHistory()
        let at = Date(timeIntervalSince1970: 1000)
        let keys = Set((0..<600).map { "session-\($0)" })
        var remindersFirstPass = true
        for _ in 0..<3 {
            var consumed = 0
            for key in keys {
                for mark in ["13", "28", "43", "58", "expired"] {
                    if reminders.consume(key, at: at, mark: mark) { consumed += 1 }
                }
            }
            require(consumed == (remindersFirstPass ? 3000 : 0), "large reminder histories must not replay")
            remindersFirstPass = false
            reminders.retain(keys)
        }
        require(reminders.consume("session-0", at: at.addingTimeInterval(1), mark: "13"), "a new turn must reset its marks")
        require(!reminders.consume("session-1", at: at, mark: "13"), "a new turn must preserve other sessions' marks")
        reminders.retain(["session-0"])
        require(reminders.consume("session-1", at: at, mark: "13"), "removed sessions must release their history")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        func chat(_ path: String, method: String = "GET") -> Result<Data, Error> {
            var result: Result<Data, Error>?
            var request = URLRequest(url: URL(string: "https://fixture.invalid/" + path)!)
            request.httpMethod = method
            runChatRequest(request, session: session) {
                require(Thread.isMainThread, "HTTP callbacks must run on the main thread")
                result = $0
            }
            let deadline = Date().addingTimeInterval(2)
            while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            require(result != nil, "HTTP completion must arrive")
            return result!
        }
        if case .success(let data) = chat("200") { require(data == Data("[]".utf8), "successful response must preserve data") }
        else { require(false, "HTTP 200 must succeed") }
        for method in ["GET", "POST"] {
            if case .failure(let error) = chat("503", method: method) {
                require(error.localizedDescription.contains("503"), "HTTP failures must identify status")
            } else { require(false, "HTTP failure must not succeed, even with valid JSON") }
        }
        if case .success(let data) = chat("204", method: "POST") { require(data.isEmpty, "empty successful action must be accepted") }
        else { require(false, "HTTP 204 must succeed") }
        if case .failure = chat("timeout") {} else { require(false, "transport failure must not succeed") }

        // Shaped like `/bin/ps -axwwE -o pid=,ppid=,command=` with kitty hosting a local and a remote herdr client.
        let table = """
            1     0 /sbin/launchd
          500     1 /Applications/kitty.app/Contents/MacOS/kitty TERM=xterm
          510   500 login -pfl safzan /bin/zsh
          511   510 -zsh KITTY_WINDOW_ID=4 KITTY_LISTEN_ON=unix:/tmp/kitty-500
          512   511 herdr KITTY_WINDOW_ID=4 KITTY_LISTEN_ON=unix:/tmp/kitty-500 HOME=/Users/safzan
          520   500 login -pfl safzan /bin/zsh
          521   520 -zsh KITTY_WINDOW_ID=11
          522   521 herdr --remote ampere KITTY_WINDOW_ID=11 KITTY_LISTEN_ON=unix:/tmp/kitty-500
          523   522 /Users/safzan/.local/bin/herdr client KITTY_WINDOW_ID=11
          530   1 /Users/safzan/.local/bin/herdr server HOME=/Users/safzan
          531   600 /Users/safzan/.local/bin/herdr agent focus w1:p2 HOME=/Users/safzan
        """
        require(findHerdrClient(table, remote: nil) == HerdrClient(pid: 512, ancestors: [511, 510, 500], kittySocket: "unix:/tmp/kitty-500", kittyWindow: "4"),
                "the local client is the bare `herdr`, with its kitty window and parent chain")
        require(findHerdrClient(table, remote: "ampere")?.pid == 522 && findHerdrClient(table, remote: "ampere")?.kittyWindow == "11",
                "a remote host maps to its `herdr --remote` client, not the `herdr client` helper")
        require(findHerdrClient(table, remote: "server-pc") == nil, "a host with no attached client finds nothing")
        require(findHerdrClient("  9 1 herdr --session work\n", remote: nil)?.pid == 9, "a named local session is a local client")
        print("PASS: process output, deadlines, poll ownership, reminder history, HTTP failures, and herdr client lookup")
    }
}
