import AppKit
import AVFoundation
import ServiceManagement
import UserNotifications

// CacheMenuBar: watches the prompt caches of Claude Code and Codex CLI sessions, local and on remote hosts, and reminds you
// before they expire. Data comes from `cachewatch-hook` (hooks/), which records each session's last turn end and cache shape
// into ~/.local/state/cachewatch/. Remote hosts are read over ssh.
// Reminders fire at fixed minute offsets from the turn that wrote the cache:
//   Anthropic 1h ttl → 13, 28, 43, 58     Anthropic 5m ttl → 1, 3     OpenAI (≈30 min automatic cache) → 8, 18, 28
// plus one "expired" notice with the estimated cost of resuming.

enum Settings {
    static let d = UserDefaults.standard
    static var hosts: [String] { get { d.stringArray(forKey: "hosts") ?? ["ampere"] } set { d.set(newValue, forKey: "hosts") } }
    static var sound: Bool { get { d.object(forKey: "sound") as? Bool ?? true } set { d.set(newValue, forKey: "sound") } }
    static var notify: Bool { get { d.object(forKey: "notify") as? Bool ?? true } set { d.set(newValue, forKey: "notify") } }
    static var expiredNotice: Bool { get { d.object(forKey: "expiredNotice") as? Bool ?? true } set { d.set(newValue, forKey: "expiredNotice") } }
    static var openaiMinutes: Int { get { max(5, d.object(forKey: "openaiMinutes") as? Int ?? 30) } set { d.set(newValue, forKey: "openaiMinutes") } }
    static var stateDir: String { NSHomeDirectory() + "/.local/state/cachewatch" }
    /// The local chat app (Bun server). Empty disables that source.
    static var chatURL: String { get { d.string(forKey: "chatURL") ?? "http://localhost:8787" } set { d.set(newValue, forKey: "chatURL") } }
    static var chatBase: String? { let u = chatURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")); return u.isEmpty ? nil : u }
}

let offsets: [String: [Double]] = ["1h": [13, 28, 43, 58], "5m": [1, 3], "openai": [8, 18, 28]]

// USD per MTok: (input, cache read, 5m write, 1h write). Used only for the "cost to resume" line.
let prices: [(prefix: String, input: Double, read: Double, w5: Double, w1h: Double)] = [
    ("claude-fable-5-1", 10, 0.25, 12.5, 20), ("claude-mythos-5-1", 10, 0.25, 12.5, 20),
    ("claude-fable-5", 10, 1, 12.5, 20), ("claude-mythos-5", 10, 1, 12.5, 20),
    ("claude-opus-5", 5, 0.5, 6.25, 10), ("claude-opus-4-5", 5, 0.5, 6.25, 10), ("claude-opus-4-6", 5, 0.5, 6.25, 10),
    ("claude-opus-4-7", 5, 0.5, 6.25, 10), ("claude-opus-4-8", 5, 0.5, 6.25, 10), ("claude-opus-4", 15, 1.5, 18.75, 30),
    ("claude-sonnet-5", 2, 0.2, 2.5, 4), ("claude-sonnet-4", 3, 0.3, 3.75, 6), ("claude-haiku-4", 1, 0.1, 1.25, 2),
    ("gpt-5-nano", 0.05, 0.005, 0, 0), ("gpt-5-mini", 0.25, 0.025, 0, 0), ("gpt-5", 1.25, 0.125, 0, 0),
    ("gpt-4.1-mini", 0.4, 0.1, 0, 0), ("gpt-4.1", 2, 0.5, 0, 0), ("gpt-4o", 2.5, 1.25, 0, 0), ("o3", 2, 0.5, 0, 0),
]

struct SessionInfo {
    let key: String            // "<host>/<agent>-<session_id>"
    let host: String, local: Bool
    let agent: String, sessionId: String, paneId: String?
    let title: String, cwd: String, model: String, lastPrompt: String?
    let active: Bool           // a turn is running; the next Stop refreshes the cache
    let at: Date?              // when the last turn ended = when the cache was written/refreshed
    let ttl: String            // "1h" | "5m" | "openai"
    let tokens: Int
    // chat-app sessions only
    var chatId: String? = nil
    var warmOn = false, warmPings = 0, warmNext: Date? = nil
    var isChat: Bool { agent == "chat" }

    var ttlSeconds: Double { ttl == "1h" ? 3600 : ttl == "5m" ? 300 : Double(Settings.openaiMinutes) * 60 }
    var expiresAt: Date? { at.map { $0.addingTimeInterval(ttlSeconds) } }
    func remaining(_ now: Date) -> Double { expiresAt.map { $0.timeIntervalSince(now) } ?? -1 }
    func isLive(_ now: Date) -> Bool { !active && remaining(now) > 0 }
    var ttlLabel: String { ttl == "openai" ? "OpenAI cache" : "\(ttl) ttl" }
    var agentLabel: String { agent == "codex" ? "Codex" : agent == "chat" ? "Chat app" : "Claude Code" }
    var where_: String { isChat ? "chat" : local ? "local" : host }

    /// Cost of re-sending the prefix once it has lapsed, versus the read it would have been.
    var resumeCost: (write: Double, read: Double)? {
        guard tokens > 0, let p = prices.first(where: { model.hasPrefix($0.prefix) }) else { return nil }
        let rate = ttl == "1h" ? p.w1h : ttl == "5m" ? p.w5 : p.input
        return (Double(tokens) * rate / 1e6, Double(tokens) * p.read / 1e6)
    }

    /// A session of the chat app, from its GET /api/sessions list (cache + warm fields).
    init?(chat o: [String: Any]) {
        guard let id = o["id"] as? String, let provider = o["provider"] as? String else { return nil }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let c = o["cache"] as? [String: Any]; let w = o["warm"] as? [String: Any]
        agent = "chat"; sessionId = id; chatId = id; host = "chat"; local = true; key = "chat/\(id)"; paneId = nil
        cwd = ""; title = o["title"] as? String ?? "Untitled"; model = o["model"] as? String ?? ""; lastPrompt = nil; active = false
        if provider == "anthropic" {
            guard let c = c else { return nil }
            at = (c["at"] as? String).flatMap { iso.date(from: $0) }; ttl = c["ttl"] as? String ?? "5m"; tokens = c["tokens"] as? Int ?? 0
        } else {
            guard (o["count"] as? Int ?? 0) > 0 else { return nil }
            at = (o["updatedAt"] as? String).flatMap { iso.date(from: $0) }; ttl = "openai"; tokens = 0
        }
        warmOn = w?["on"] as? Bool ?? false; warmPings = w?["pings"] as? Int ?? 0
        warmNext = (w?["nextAt"] as? String).flatMap { iso.date(from: $0) }
    }

    init?(json o: [String: Any], host: String, local: Bool) {
        guard let agent = o["agent"] as? String, let sid = o["session_id"] as? String else { return nil }
        self.agent = agent; sessionId = sid; self.host = host; self.local = local
        key = "\(host)/\(agent)-\(sid)"
        paneId = o["pane_id"] as? String
        cwd = o["cwd"] as? String ?? ""
        title = (o["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (cwd as NSString).lastPathComponent
        model = o["model"] as? String ?? (agent == "codex" ? "gpt-5" : "")
        lastPrompt = o["last_prompt"] as? String
        active = o["active"] as? Bool ?? false
        at = (o["at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        ttl = o["ttl"] as? String ?? (agent == "codex" ? "openai" : "5m")
        tokens = o["tokens"] as? Int ?? 0
    }
}

func mmss(_ t: Double) -> String { let s = max(0, Int(t.rounded(.down))); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60) }
func usd(_ n: Double) -> String { n >= 1 ? String(format: "$%.2f", n) : n >= 0.01 ? String(format: "$%.3f", n) : String(format: "$%.4f", n) }
func kilo(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }

// ---------- sound: soft two-note sine chime, synthesised in memory ----------
final class Chime {
    private var players: [AVAudioPlayer] = []
    private func render(notes: [(hz: Double, at: Double)], gain: Float = 0.22) -> Data {
        let sr = 44100.0, dur = 0.75, n = Int(sr * dur)
        var pcm = [Float](repeating: 0, count: n)
        for note in notes {
            for i in 0..<n {
                let t = Double(i) / sr - note.at; if t < 0 || t > 0.45 { continue }
                let env = min(1, t / 0.012) * exp(-t * 7.5)
                pcm[i] += Float(sin(2 * .pi * note.hz * t) * env)
            }
        }
        var d = Data(); func le<T: FixedWidthInteger>(_ v: T) { var v = v.littleEndian; d.append(Data(bytes: &v, count: MemoryLayout<T>.size)) }
        d.append("RIFF".data(using: .ascii)!); le(UInt32(36 + n * 2)); d.append("WAVEfmt ".data(using: .ascii)!)
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(sr)); le(UInt32(sr * 2)); le(UInt16(2)); le(UInt16(16))
        d.append("data".data(using: .ascii)!); le(UInt32(n * 2))
        for v in pcm { le(Int16(max(-1, min(1, v * gain)) * 32767)) }
        return d
    }
    private lazy var reminder = render(notes: [(523.25, 0), (783.99, 0.13)])          // C5 → G5, rising: "still time"
    private lazy var expired = render(notes: [(783.99, 0), (523.25, 0.13), (392, 0.26)]) // G5 → C5 → G4, falling: "gone"
    func play(expired e: Bool) {
        guard Settings.sound, let p = try? AVAudioPlayer(data: e ? expired : reminder) else { return }
        players.removeAll { !$0.isPlaying }; players.append(p); p.play()
    }
}

// ---------- sources ----------
/// Reads every *.json in the local state dir.
func readLocal() -> [SessionInfo] {
    let dir = Settings.stateDir
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
    let host = ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "local"
    return names.filter { $0.hasSuffix(".json") }.compactMap { n in
        guard let d = FileManager.default.contents(atPath: dir + "/" + n), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return SessionInfo(json: o, host: host, local: true)
    }
}
/// `ssh host` and prints each state file as one line; the user's ~/.ssh/config (ControlMaster etc.) applies.
func readRemote(_ host: String, done: @escaping ([SessionInfo]?, String?) -> Void) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", host, "for f in ~/.local/state/cachewatch/*.json; do [ -f \"$f\" ] && cat \"$f\" && echo; done 2>/dev/null; true"]
    let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
    p.terminationHandler = { proc in
        let data = out.fileHandleForReading.readDataToEndOfFile(); let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        DispatchQueue.main.async {
            if proc.terminationStatus != 0 { done(nil, e.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? "ssh exit \(proc.terminationStatus)"); return }
            let s = String(data: data, encoding: .utf8) ?? ""
            done(s.split(separator: "\n").compactMap { line in
                guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
                return SessionInfo(json: o, host: host, local: false)
            }, nil)
        }
    }
    do { try p.run() } catch { done(nil, error.localizedDescription) }
}

/// Chat app sessions over HTTP.
func readChat(done: @escaping ([SessionInfo]?, String?) -> Void) {
    guard let base = Settings.chatBase, let url = URL(string: base + "/api/sessions") else { done([], nil); return }
    var req = URLRequest(url: url); req.timeoutInterval = 5
    URLSession.shared.dataTask(with: req) { data, _, err in
        DispatchQueue.main.async {
            if let err = err { done(nil, err.localizedDescription); return }
            guard let data = data, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { done(nil, "unreadable response"); return }
            done(arr.compactMap { SessionInfo(chat: $0) }, nil)
        }
    }.resume()
}
func chatPost(_ path: String, _ body: [String: Any], then: @escaping () -> Void) {
    guard let base = Settings.chatBase, let u = URL(string: base + path) else { return }
    var r = URLRequest(url: u); r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "content-type")
    r.httpBody = try? JSONSerialization.data(withJSONObject: body)
    URLSession.shared.dataTask(with: r) { _, _, _ in DispatchQueue.main.async(execute: then) }.resume()
}

// ---------- app ----------
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var local: [SessionInfo] = []
    var chat: [SessionInfo] = []
    var remote: [String: [SessionInfo]] = [:]
    var hostErrors: [String: String] = [:]
    var polling = Set<String>()
    var lastPoll = Date.distantPast
    var fired = Set<String>()
    var timer: Timer?
    let chime = Chime()
    var settingsWindow: NSWindow?
    var notificationsAllowed = false

    var all: [SessionInfo] { local + chat + Settings.hosts.flatMap { remote[$0] ?? [] } }
    func live(_ now: Date = Date()) -> [SessionInfo] { all.filter { $0.isLive(now) }.sorted { $0.remaining(now) < $1.remaining(now) } }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Cache timer")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.menu = NSMenu(); statusItem.menu?.delegate = self
        let center = UNUserNotificationCenter.current(); center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in DispatchQueue.main.async { self.notificationsAllowed = ok } }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func tick() {
        if Date().timeIntervalSince(lastPoll) >= 10 { poll() }
        checkReminders(); render()
    }

    func poll() {
        lastPoll = Date()
        local = readLocal()
        if Settings.chatBase != nil, !polling.contains("chat") {
            polling.insert("chat")
            readChat { list, err in
                self.polling.remove("chat")
                if let list = list { self.chat = list; self.hostErrors["chat app"] = nil } else { self.hostErrors["chat app"] = err }
                self.checkReminders(); self.render()
            }
        } else if Settings.chatBase == nil { chat = []; hostErrors["chat app"] = nil }
        for h in Settings.hosts where !polling.contains(h) {
            polling.insert(h)
            readRemote(h) { list, err in
                self.polling.remove(h)
                if let list = list { self.remote[h] = list; self.hostErrors[h] = nil } else { self.hostErrors[h] = err }
                self.checkReminders(); self.render()
            }
        }
    }

    /// Fire any reminder mark that has come due since the cache was written and has not fired yet. A new `at` (the session ran
    /// another turn) starts a fresh set. Marks that came due while the app or the host was unreachable are skipped, not backfilled.
    func checkReminders() {
        let now = Date()
        for s in all where !s.active && !s.warmOn {
            guard let at = s.at, let marks = offsets[s.ttl], let exp = s.expiresAt else { continue }
            let age = now.timeIntervalSince(at)
            for m in marks where m * 60 <= age && m * 60 < s.ttlSeconds {
                let key = "\(s.key)|\(at.timeIntervalSince1970)|\(m)"
                if fired.contains(key) { continue }; fired.insert(key)
                if age - m * 60 > 45 { continue }
                let left = exp.timeIntervalSince(now)
                remind(s, title: "\(s.title) · \(mmss(left)) left", body: "\(s.agentLabel) on \(s.where_) · \(kilo(s.tokens)) cached tokens (\(s.ttlLabel)). Send a message to keep the cache.", expired: false)
            }
            let ek = "\(s.key)|\(at.timeIntervalSince1970)|expired"
            if Settings.expiredNotice, now >= exp, !fired.contains(ek) {
                fired.insert(ek)
                if now.timeIntervalSince(exp) > 45 { continue }
                let cost = s.resumeCost.map { " Resuming re-sends the prefix for about \(usd($0.write)) instead of \(usd($0.read))." } ?? ""
                remind(s, title: "\(s.title) · cache expired", body: "\(s.agentLabel) on \(s.where_) · \(kilo(s.tokens)) tokens lapsed.\(cost)", expired: true)
            }
        }
        if fired.count > 2000 { fired.removeAll() }
    }

    func remind(_ s: SessionInfo, title: String, body: String, expired: Bool) {
        chime.play(expired: expired)
        guard Settings.notify, notificationsAllowed else { return }
        let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.userInfo = ["key": s.key]
        c.interruptionLevel = expired ? .active : .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list] }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        if let key = r.notification.request.content.userInfo["key"] as? String { await MainActor.run { self.focus(key) } }
    }

    // ---------- menubar rendering ----------
    func render() {
        let now = Date(); let l = live(now)
        guard let b = statusItem.button else { return }
        let working = all.filter { $0.active }.count
        if let first = l.first {
            let left = first.remaining(now)
            let color: NSColor = left < 60 ? .systemRed : left < 180 ? .systemOrange : .labelColor
            let extra = l.count > 1 ? " +\(l.count - 1)" : ""
            b.attributedTitle = NSAttributedString(string: " \(mmss(left))\(extra)", attributes: [.foregroundColor: color, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
            b.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
            b.toolTip = "\(first.title) (\(first.agentLabel), \(first.where_)): \(mmss(left)) left on \(kilo(first.tokens)) cached tokens"
        } else {
            b.attributedTitle = NSAttributedString(string: working > 0 ? " \(working)" : "")
            b.image = NSImage(systemSymbolName: working > 0 ? "timer" : hostErrors.isEmpty ? "timer" : "timer.slash", accessibilityDescription: nil)
            b.toolTip = working > 0 ? "\(working) session\(working == 1 ? "" : "s") working" : hostErrors.isEmpty ? "No live prompt caches" : hostErrors.map { "\($0): \($1)" }.joined(separator: "\n")
        }
    }

    /// Local sessions: ask herdr to focus the agent's pane. Remote ones: nothing to jump to from here.
    func focus(_ key: String) {
        guard let s = all.first(where: { $0.key == key }), s.local else { return }
        if let id = s.chatId { if let base = Settings.chatBase, let u = URL(string: base + "/#" + id) { NSWorkspace.shared.open(u) }; return }
        for target in [s.paneId, s.sessionId].compactMap({ $0 }) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-lc", "herdr agent focus '\(target)' >/dev/null 2>&1"]
            try? p.run(); p.waitUntilExit()
            if p.terminationStatus == 0 { break }
        }
    }
    @objc func focusAction(_ m: NSMenuItem) { if let k = m.representedObject as? String { focus(k) } }
    @objc func warmAction(_ m: NSMenuItem) { if let id = m.representedObject as? String { chatPost("/api/sessions/\(id)/warm", ["on": m.state != .on]) { self.poll() } } }
    @objc func pingAction(_ m: NSMenuItem) { if let id = m.representedObject as? String { chatPost("/api/sessions/\(id)/warm", ["now": true]) { self.poll() } } }
    @objc func copyCwd(_ m: NSMenuItem) { if let s = m.representedObject as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) } }
    @objc func testChime() { chime.play(expired: false); DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.chime.play(expired: true) } }
    @objc func refreshAction() { poll() }
    @objc func quit() { NSApp.terminate(nil) }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date(); let l = live(now)
        let working = all.filter { $0.active }.sorted { $0.title < $1.title }
        let lapsed = all.filter { !$0.active && !$0.isLive(now) && $0.at != nil }.sorted { $0.at! > $1.at! }.prefix(6)
        func header(_ t: String) { let it = NSMenuItem(title: t, action: nil, keyEquivalent: ""); it.isEnabled = false; menu.addItem(it) }
        if l.isEmpty && working.isEmpty { header("No live prompt caches") }
        if !l.isEmpty { header("Live caches"); for s in l { menu.addItem(sessionItem(s, now: now)) } }
        if !working.isEmpty { if !l.isEmpty { menu.addItem(.separator()) }; header("Working now"); for s in working { menu.addItem(sessionItem(s, now: now)) } }
        if !lapsed.isEmpty { menu.addItem(.separator()); header("Recently expired"); for s in lapsed { menu.addItem(sessionItem(s, now: now)) } }
        for (h, e) in hostErrors.sorted(by: { $0.key < $1.key }) { menu.addItem(.separator()); header("\(h): \(e)") }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh", action: #selector(refreshAction), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Test chimes", action: #selector(testChime), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit CacheMenuBar", action: #selector(quit), keyEquivalent: "q").target = self
    }

    func sessionItem(_ s: SessionInfo, now: Date) -> NSMenuItem {
        let left = s.remaining(now)
        let state = s.active ? "working" : left > 0 ? mmss(left) : "expired"
        let title = String(s.title.prefix(36)) + (s.title.count > 36 ? "…" : "")
        let it = NSMenuItem(title: "\(title)  ·  \(state)  ·  \(kilo(s.tokens))  ·  \(s.where_)", action: #selector(focusAction), keyEquivalent: "")
        it.target = self; it.representedObject = s.key
        it.image = NSImage(systemSymbolName: s.warmOn ? "flame.fill" : s.active ? "circle.dotted" : left > 0 ? (left < 180 ? "exclamationmark.circle" : "checkmark.circle") : "clock.badge.xmark", accessibilityDescription: nil)
        let sub = NSMenu()
        func info(_ t: String) { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; sub.addItem(i) }
        info("\(s.agentLabel) · \(s.model.isEmpty ? "model unknown" : s.model) · \(s.ttlLabel)")
        if !s.cwd.isEmpty { info(s.cwd) }
        if let p = s.lastPrompt { info("“\(p)”") }
        if let at = s.at { info("Last turn ended \(DateFormatter.localizedString(from: at, dateStyle: .none, timeStyle: .short))") }
        if let c = s.resumeCost {
            info(left > 0 || s.active ? "Next turn reads the cache for ~\(usd(c.read))" : "Resuming re-sends the prefix for ~\(usd(c.write)) (was \(usd(c.read)) as a read)")
        }
        sub.addItem(.separator())
        if let id = s.chatId {
            let o = NSMenuItem(title: "Open in browser", action: #selector(focusAction), keyEquivalent: ""); o.target = self; o.representedObject = s.key; sub.addItem(o)
            let w = NSMenuItem(title: s.warmOn ? "Keep warm: on (\(s.warmPings) pings\(s.warmNext.map { ", next \(mmss($0.timeIntervalSince(now)))" } ?? ""))" : "Keep warm (server pings the cache)", action: #selector(warmAction), keyEquivalent: "")
            w.target = self; w.representedObject = id; w.state = s.warmOn ? .on : .off; sub.addItem(w)
            let p = NSMenuItem(title: "Ping now (1-token request)", action: #selector(pingAction), keyEquivalent: ""); p.target = self; p.representedObject = id; sub.addItem(p)
        } else if s.local {
            let f = NSMenuItem(title: "Focus in herdr", action: #selector(focusAction), keyEquivalent: ""); f.target = self; f.representedObject = s.key; sub.addItem(f)
        } else {
            info("Remote session on \(s.host): attach with  herdr --remote \(s.host)")
        }
        if !s.cwd.isEmpty { let c = NSMenuItem(title: "Copy working directory", action: #selector(copyCwd(_:)), keyEquivalent: ""); c.target = self; c.representedObject = s.cwd; sub.addItem(c) }
        it.submenu = sub
        return it
    }
}

// ---------- settings window ----------
extension AppDelegate {
    @objc func showSettings() {
        if let w = settingsWindow { NSApp.setActivationPolicy(.regular); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 370), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "CacheMenuBar Settings"; w.center(); w.delegate = self; w.isReleasedWhenClosed = false
        let v = NSView(frame: w.contentView!.bounds)
        func label(_ t: String, x: CGFloat = 20, y: CGFloat, w: CGFloat = 420) { let l = NSTextField(wrappingLabelWithString: t); l.frame = NSRect(x: x, y: y, width: w, height: 30); l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor; v.addSubview(l) }
        let chat = NSTextField(frame: NSRect(x: 20, y: 316, width: 420, height: 24)); chat.stringValue = Settings.chatURL; chat.placeholderString = "http://localhost:8787 (empty to disable)"
        chat.target = self; chat.action = #selector(chatChanged(_:)); v.addSubview(chat)
        label("Chat app server; its sessions, keep-warm state and cost estimates appear alongside the CLI sessions.", y: 282)
        let hosts = NSTextField(frame: NSRect(x: 20, y: 250, width: 420, height: 24)); hosts.stringValue = Settings.hosts.joined(separator: ", "); hosts.placeholderString = "ampere, main"
        hosts.target = self; hosts.action = #selector(hostsChanged(_:)); v.addSubview(hosts)
        label("Remote ssh hosts to watch, comma-separated (names from ~/.ssh/config). Each needs cachewatch-hook installed; see README.", y: 216)
        let om = NSTextField(frame: NSRect(x: 20, y: 186, width: 60, height: 24)); om.integerValue = Settings.openaiMinutes; om.target = self; om.action = #selector(openaiChanged(_:)); v.addSubview(om)
        label("minutes an idle OpenAI (Codex) prompt cache is assumed to live", x: 88, y: 180, w: 350)
        func check(_ t: String, y: CGFloat, on: Bool, sel: Selector) { let c = NSButton(checkboxWithTitle: t, target: self, action: sel); c.frame = NSRect(x: 20, y: y, width: 420, height: 20); c.state = on ? .on : .off; v.addSubview(c) }
        check("Play a chime on each reminder", y: 140, on: Settings.sound, sel: #selector(soundChanged(_:)))
        check("Show a notification on each reminder", y: 116, on: Settings.notify, sel: #selector(notifyChanged(_:)))
        check("Also notify when a cache has expired, with the cost to resume", y: 92, on: Settings.expiredNotice, sel: #selector(expiredChanged(_:)))
        check("Launch CacheMenuBar at login", y: 60, on: SMAppService.mainApp.status == .enabled, sel: #selector(loginChanged(_:)))
        label("Reminders after the last turn: 1h ttl at minute 13 / 28 / 43 / 58 · 5m ttl at 1 / 3 · OpenAI at 8 / 18 / 28.", y: 14)
        w.contentView = v; settingsWindow = w
        NSApp.setActivationPolicy(.regular); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func chatChanged(_ f: NSTextField) { Settings.chatURL = f.stringValue.trimmingCharacters(in: .whitespaces); chat = []; hostErrors["chat app"] = nil; poll() }
    @objc func hostsChanged(_ f: NSTextField) {
        Settings.hosts = f.stringValue.split(whereSeparator: { $0 == "," || $0 == " " }).map { String($0) }.filter { !$0.isEmpty }
        remote = [:]; hostErrors = [:]; poll()
    }
    @objc func openaiChanged(_ f: NSTextField) { Settings.openaiMinutes = f.integerValue; render() }
    @objc func soundChanged(_ b: NSButton) { Settings.sound = b.state == .on; if Settings.sound { chime.play(expired: false) } }
    @objc func notifyChanged(_ b: NSButton) { Settings.notify = b.state == .on }
    @objc func expiredChanged(_ b: NSButton) { Settings.expiredNotice = b.state == .on }
    @objc func loginChanged(_ b: NSButton) {
        do { if b.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { b.state = b.state == .on ? .off : .on; NSAlert(error: error).runModal() }
    }
    func windowWillClose(_ n: Notification) { NSApp.setActivationPolicy(.accessory) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
