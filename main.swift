import Cocoa
import IOKit.pwr_mgt

private func envSeconds(_ key: String, default def: TimeInterval) -> TimeInterval {
    if let raw = ProcessInfo.processInfo.environment[key],
       let value = TimeInterval(raw), value > 0 {
        return value
    }
    return def
}

// StayAwake: menu bar app that keeps the screen on while Claude Code,
// Codex/GPT, or a Cursor agent is working, and gets out of the way when
// they aren't. ☕️ = keeping the Mac awake, 💤 = normal sleep allowed.
//
// Claude: Claude Code appends to a session transcript
//   (~/.claude/projects/**/*.jsonl) continuously while it works, so a recent
//   write means "Claude is running". Regular (non-Code) chats in the Claude
//   desktop app don't write transcripts, so those are covered the same way
//   as GPT: CPU-time growth in Claude.app processes while streaming.
// GPT: the Codex app-server heartbeats its log file even when idle, so file
//   times are useless — but its CPU usage is 0.0% idle and jumps when it
//   actually works, so "working" = its processes accumulated CPU time since
//   the last check.
// Cursor: activity hooks (~/.cursor/hooks.json) touch a heartbeat file on
//   every agent event (prompt submitted, thought, response, tool use), so a
//   fresh heartbeat means a Cursor agent is working.
//
// Usage log: 15-minute buckets in a CSV, pruned to 90 days. Each row counts
// how many checks fell in the bucket and how many of them found the screen
// being kept awake (total and per-AI), so "% of day active" is
// awake * checkInterval / 86400.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private var displayAssertionID: IOPMAssertionID = 0
    private var userActivityID: IOPMAssertionID = 0
    private var activityTimer: Timer?
    private var blocking = false

    private let idleThreshold = envSeconds("STAYAWAKE_IDLE_SECS", default: 600)
    private let checkInterval = envSeconds("STAYAWAKE_CHECK_SECS", default: 30)
    private let scanDir = ProcessInfo.processInfo.environment["STAYAWAKE_SCAN_DIR"]
        ?? (NSHomeDirectory() + "/.claude/projects")
    // Matches both the Codex app-server (VS Code extension) and ChatGPT.app.
    private let gptPattern = ProcessInfo.processInfo.environment["STAYAWAKE_GPT_PATTERN"] ?? "codex,chatgpt"
    // CPU fraction (of one core) the GPT processes must average between two
    // checks to count as working. Measured: idle ≤1.3% (UI noise with the
    // window open), streaming a response 23–66%.
    private let gptCpuRate = Double(ProcessInfo.processInfo.environment["STAYAWAKE_GPT_CPU_RATE"] ?? "") ?? 0.05
    // Matches the Claude desktop app and the claude CLI.
    private let claudePattern = ProcessInfo.processInfo.environment["STAYAWAKE_CLAUDE_PATTERN"] ?? "claude"
    private let cursorHeartbeat = ProcessInfo.processInfo.environment["STAYAWAKE_CURSOR_HEARTBEAT"]
        ?? (NSHomeDirectory() + "/.cursor/state/stayawake.heartbeat")
    private let usageFile = ProcessInfo.processInfo.environment["STAYAWAKE_USAGE_FILE"]
        ?? (NSHomeDirectory() + "/Documents/StayAwake/usage.csv")
    private let debugStatus = CommandLine.arguments.contains("--debug-status")

    private var prevGptCpu: Double?
    private var prevGptSample: Date?
    private var lastGptActive: Date?
    private var prevClaudeCpu: Double?
    private var lastClaudeAppActive: Date?
    private var claudeLast: Date?
    private var cursorLast: Date?
    private let launchTime = Date()

    // bucket is "yyyy-MM-ddTHH:mm" floored to the quarter hour.
    private struct UsageRow {
        var bucket: String
        var checks: Int
        var awake: Int
        var claude: Int
        var gpt: Int
        var cursor: Int
        var csv: String { "\(bucket),\(checks),\(awake),\(claude),\(gpt),\(cursor)" }
    }
    private var usage: [UsageRow] = []

    // The coffee cup is dark enough to read on any menu bar; the blue zzz
    // needs the white disc behind it.
    private static let awakeIcon = statusIcon("☕️", circle: false)
    private static let sleepIcon = statusIcon("💤", circle: true)

    /// Emoji, optionally on a white circle so it stays readable on
    /// transparent/wallpaper-tinted menu bars.
    private static func statusIcon(_ emoji: String, side: CGFloat = 20, circle: Bool) -> NSImage {
        let size = NSSize(width: side, height: side)
        return NSImage(size: size, flipped: false) { rect in
            if circle {
                let disc = NSBezierPath(ovalIn: rect.insetBy(dx: side * 0.025, dy: side * 0.025))
                NSColor.white.setFill()
                disc.fill()
                NSColor.black.withAlphaComponent(0.2).setStroke()
                disc.lineWidth = max(1, side * 0.05)
                disc.stroke()
            }
            let text = emoji as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: side * (circle ? 0.6 : 0.75))]
            let textSize = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2,
                                  y: rect.midY - textSize.height / 2),
                      withAttributes: attrs)
            return true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--render-icons") {
            for (name, icon) in [("awake", Self.statusIcon("☕️", side: 100, circle: false)),
                                 ("sleep", Self.statusIcon("💤", side: 100, circle: true))] {
                let rep = NSBitmapImageRep(data: icon.tiffRepresentation!)!
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "icon-\(name).png"))
            }
            NSApp.terminate(nil)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.sleepIcon
        menu.delegate = self
        statusItem.menu = menu

        loadUsage()
        let timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.check()
        }
        RunLoop.main.add(timer, forMode: .common)
        check()
    }

    func applicationWillTerminate(_ notification: Notification) {
        setBlocking(false)
    }

    // MARK: - Detection

    private func check() {
        let dir = scanDir
        let pattern = gptPattern
        let claudePat = claudePattern
        let heartbeat = cursorHeartbeat
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let lastWrite = Self.lastTranscriptWrite(in: dir)
            let ps = Self.processList()
            let gptCpu = Self.totalCpuSeconds(psOutput: ps, processPattern: pattern)
            let claudeCpu = Self.totalCpuSeconds(psOutput: ps, processPattern: claudePat)
            let cursorBeat = (try? FileManager.default.attributesOfItem(atPath: heartbeat))?[.modificationDate] as? Date
            DispatchQueue.main.async {
                self?.apply(lastWrite: lastWrite, gptCpu: gptCpu, claudeCpu: claudeCpu, cursorBeat: cursorBeat)
            }
        }
    }

    private static func processList() -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Ao", "cputime,comm"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do { try task.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Most recent modification time of any Claude Code session transcript.
    private static func lastTranscriptWrite(in dir: String) -> Date? {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: dir),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }
        var latest: Date?
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            if let date = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                if latest == nil || date > latest! { latest = date }
            }
        }
        return latest
    }

    /// Total accumulated CPU seconds of all processes whose executable path
    /// contains any of the comma-separated needles (case-insensitive).
    private static func totalCpuSeconds(psOutput out: String, processPattern: String) -> Double {
        let needles = processPattern.lowercased().split(separator: ",").map(String.init)
        var total = 0.0
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            guard needles.contains(where: { lower.contains($0) }) else { continue }
            if let timeField = trimmed.split(separator: " ").first {
                total += parseCpuTime(String(timeField))
            }
        }
        return total
    }

    /// ps cputime looks like "0:00.03", "12:34.56", "1:02:03.04", or "1-02:03:04".
    private static func parseCpuTime(_ raw: String) -> Double {
        var days = 0.0
        var rest = raw
        if let dash = raw.firstIndex(of: "-") {
            days = Double(raw[..<dash]) ?? 0
            rest = String(raw[raw.index(after: dash)...])
        }
        var seconds = 0.0
        for part in rest.split(separator: ":") {
            seconds = seconds * 60 + (Double(part) ?? 0)
        }
        return days * 86400 + seconds
    }

    private func apply(lastWrite: Date?, gptCpu: Double, claudeCpu: Double, cursorBeat: Date?) {
        let now = Date()

        // GPT / Claude.app: did their processes burn CPU since the last sample?
        var gptRate = 0.0
        var claudeRate = 0.0
        if let prevTime = prevGptSample {
            let elapsed = now.timeIntervalSince(prevTime)
            if elapsed > 1 {
                if let prevCpu = prevGptCpu {
                    gptRate = max(0, gptCpu - prevCpu) / elapsed
                    if gptRate >= gptCpuRate { lastGptActive = now }
                }
                if let prevCpu = prevClaudeCpu {
                    claudeRate = max(0, claudeCpu - prevCpu) / elapsed
                    if claudeRate >= gptCpuRate { lastClaudeAppActive = now }
                }
            }
        }
        prevGptCpu = gptCpu
        prevClaudeCpu = claudeCpu
        prevGptSample = now
        // Claude = most recent of transcript write (Claude Code) or app CPU
        // activity (regular desktop chats).
        claudeLast = [lastWrite, lastClaudeAppActive].compactMap { $0 }.max()
        cursorLast = cursorBeat

        let claudeIdle = claudeLast.map { now.timeIntervalSince($0) } ?? .infinity
        let gptIdle = lastGptActive.map { now.timeIntervalSince($0) } ?? .infinity
        let cursorIdle = cursorBeat.map { now.timeIntervalSince($0) } ?? .infinity
        let working = min(claudeIdle, gptIdle, cursorIdle) < idleThreshold
        setBlocking(working)
        statusItem.button?.image = working ? Self.awakeIcon : Self.sleepIcon

        recordUsage(awake: working,
                    claude: claudeIdle < idleThreshold,
                    gpt: gptIdle < idleThreshold,
                    cursor: cursorIdle < idleThreshold)

        if debugStatus {
            log("CHECK working=\(working) claudeIdle=\(Self.describeAgo(claudeIdle)) " +
                "claudeRate=\(String(format: "%.3f", claudeRate)) " +
                "gptIdle=\(Self.describeAgo(gptIdle)) gptRate=\(String(format: "%.3f", gptRate)) " +
                "cursorIdle=\(Self.describeAgo(cursorIdle))")
        }
    }

    private func setBlocking(_ on: Bool) {
        if on && !blocking {
            var id: IOPMAssertionID = 0
            guard IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Claude/GPT/Cursor is working" as CFString,
                &id) == kIOReturnSuccess else { return }
            displayAssertionID = id
            blocking = true

            // The display-sleep assertion alone doesn't stop the screensaver on
            // all macOS versions; periodically declaring user activity does.
            declareActivity()
            activityTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.declareActivity()
            }
            log("BLOCK_ON")
        } else if !on && blocking {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
            if userActivityID != 0 {
                IOPMAssertionRelease(userActivityID)
                userActivityID = 0
            }
            activityTimer?.invalidate()
            activityTimer = nil
            blocking = false
            log("BLOCK_OFF")
        }
    }

    private func declareActivity() {
        IOPMAssertionDeclareUserActivity("Claude/GPT/Cursor is working" as CFString,
                                         kIOPMUserActiveLocal,
                                         &userActivityID)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()

        addInfo(blocking ? "☕️ Keeping your Mac awake" : "💤 Sleep allowed")
        menu.addItem(.separator())

        // Only tools seen this session (or currently active) get a line.
        var listedAny = false
        let sources: [(String, Date?)] = [("Claude", claudeLast), ("GPT", lastGptActive), ("Cursor", cursorLast)]
        for (name, last) in sources {
            guard let last else { continue }
            let idle = now.timeIntervalSince(last)
            guard idle < idleThreshold || last > launchTime else { continue }
            let dot = idle < idleThreshold ? "🟢" : "⚪️"
            addInfo("\(dot) \(name) — \(Self.describeAgo(idle))")
            listedAny = true
        }
        if !listedAny {
            addInfo("No AI activity this session")
        }

        menu.addItem(.separator())
        let (awakeSeconds, percent) = todayStats()
        addInfo(String(format: "Today: active %@ (%.0f%% of day)",
                       Self.describeDuration(awakeSeconds), percent))
        let openItem = NSMenuItem(title: "Open Usage Log", action: #selector(openUsage), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit StayAwake", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func addInfo(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func openUsage() {
        NSWorkspace.shared.open(URL(fileURLWithPath: usageFile))
    }

    // MARK: - Usage log

    private static func bucketKey(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d",
                      c.year!, c.month!, c.day!, c.hour!, (c.minute! / 15) * 15)
    }

    private func recordUsage(awake: Bool, claude: Bool, gpt: Bool, cursor: Bool) {
        let key = Self.bucketKey(for: Date())
        if usage.last?.bucket != key {
            usage.append(UsageRow(bucket: key, checks: 0, awake: 0, claude: 0, gpt: 0, cursor: 0))
            let cutoff = Self.bucketKey(for: Date().addingTimeInterval(-90 * 86400))
            usage.removeAll { $0.bucket < cutoff }
        }
        var row = usage[usage.count - 1]
        row.checks += 1
        if awake { row.awake += 1 }
        if claude { row.claude += 1 }
        if gpt { row.gpt += 1 }
        if cursor { row.cursor += 1 }
        usage[usage.count - 1] = row
        saveUsage()
    }

    private func todayStats() -> (TimeInterval, Double) {
        let dayPrefix = String(Self.bucketKey(for: Date()).prefix(10))
        let awakeChecks = usage.filter { $0.bucket.hasPrefix(dayPrefix) }.reduce(0) { $0 + $1.awake }
        let seconds = Double(awakeChecks) * checkInterval
        return (seconds, seconds / 86400 * 100)
    }

    private func loadUsage() {
        guard let text = try? String(contentsOfFile: usageFile, encoding: .utf8) else { return }
        for line in text.split(separator: "\n").dropFirst() {
            let f = line.split(separator: ",").map(String.init)
            guard f.count == 6, let checks = Int(f[1]), let awake = Int(f[2]),
                  let claude = Int(f[3]), let gpt = Int(f[4]), let cursor = Int(f[5]) else { continue }
            usage.append(UsageRow(bucket: f[0], checks: checks, awake: awake,
                                  claude: claude, gpt: gpt, cursor: cursor))
        }
    }

    private func saveUsage() {
        let dir = (usageFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let text = "bucket,checks,awake,claude,gpt,cursor\n"
            + usage.map(\.csv).joined(separator: "\n") + "\n"
        try? text.write(toFile: usageFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Formatting

    private static func describeAgo(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "—" }
        if interval < 90 { return "\(Int(interval))s ago" }
        if interval < 5400 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h \(Int(interval.truncatingRemainder(dividingBy: 3600) / 60))m ago"
    }

    private static func describeDuration(_ interval: TimeInterval) -> String {
        if interval < 3600 { return "\(Int(interval / 60))m" }
        return "\(Int(interval / 3600))h \(Int(interval.truncatingRemainder(dividingBy: 3600) / 60))m"
    }

    private func log(_ message: String) {
        guard debugStatus else { return }
        FileHandle.standardOutput.write((message + "\n").data(using: .utf8)!)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
