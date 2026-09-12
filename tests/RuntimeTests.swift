import Foundation

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
        print("PASS: process output, deadlines, inherited pipes, launch errors, literal arguments, and poll ownership")
    }
}
