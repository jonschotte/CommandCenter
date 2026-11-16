import Foundation
import AppKit
import UserNotifications

/// What Claude Code last told us about a session, via its hooks.
enum ClaudeState: Equatable {
    case working          // prompt submitted / tools running
    case needsPermission  // blocked on a permission prompt
    case waiting          // idle, waiting for input (Claude's own idle notification)
    case done             // finished responding; your turn
    case ended
}

/// Receives Claude Code hook events and turns them into session status + macOS notifications.
///
/// How it works: a tiny shell script (`cc-hook.sh`) is registered as a Claude Code hook. Claude runs
/// it on each event, with the event JSON on stdin; the script appends one line to `events.jsonl`
/// with the Command Center session id (from the environment) and its parent PIDs. The app tails that file.
final class AgentEvents: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static weak var shared: AgentEvents?

    /// Status for agents running outside the app, keyed by their PID.
    @Published var external: [pid_t: (ClaudeState, String)] = [:]
    @Published var globalHooksInstalled = false
    @Published var notifyOnDone: Bool = UserDefaults.standard.object(forKey: "notifyOnDone") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnDone, forKey: "notifyOnDone") }
    }
    @Published var notifyOnPermission: Bool = UserDefaults.standard.object(forKey: "notifyOnPermission") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnPermission, forKey: "notifyOnPermission") }
    }
    @Published var playSound: Bool = UserDefaults.standard.object(forKey: "notifySound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(playSound, forKey: "notifySound") }
    }
    @Published var lastError: String?

    weak var sessions: SessionStore?
    weak var scanner: ProcessScanner?

    static let base = (NSHomeDirectory() as NSString).appendingPathComponent(".commandcenter")
    static let hookScript = base + "/hooks/cc-hook.sh"
    static let settingsFile = base + "/hooks/cc-settings.json"
    static let eventsFile = base + "/events.jsonl"
    static let claudeSettings = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
    static let hookEvents = ["UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionStart", "SessionEnd"]

    /// Extra `claude` flag for in-app sessions, unless hooks are already installed globally.
    static var settingsFlag: String? {
        guard shared?.globalHooksInstalled != true, FileManager.default.fileExists(atPath: settingsFile) else { return nil }
        return "--settings " + shellQuote(settingsFile)
    }

    private var timer: Timer?
    private var offset: UInt64 = 0

    override init() {
        super.init()
        AgentEvents.shared = self
    }

    func start() {
        installHookFiles()
        globalHooksInstalled = Self.checkGlobalInstalled()
        // Start from the end of the log; trim it if it has grown large.
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: Self.eventsFile))?[.size] as? UInt64 {
            if size > 2_000_000 { try? "".write(toFile: Self.eventsFile, atomically: true, encoding: .utf8); offset = 0 }
            else { offset = size }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }

        if Bundle.main.bundleIdentifier != nil {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    // MARK: Hook files

    private func installHookFiles() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (Self.hookScript as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        # Command Center hook: forwards Claude Code events to the app. Prints nothing; never blocks Claude.
        IN=$(cat | tr -d '\\n')
        GP=$(ps -o ppid= -p "$PPID" 2>/dev/null | tr -d ' ')
        printf '{"cc":"%s","ppid":%s,"gppid":%s,"ts":%s,"e":%s}\\n' "${COMMAND_CENTER_SESSION_ID:-}" "${PPID:-0}" "${GP:-0}" "$(date +%s)" "${IN:-null}" >> "$HOME/.commandcenter/events.jsonl" 2>/dev/null
        exit 0
        """
        try? script.write(toFile: Self.hookScript, atomically: true, encoding: .utf8)
        chmod(Self.hookScript, 0o755)
        let settings: [String: Any] = ["hooks": Self.hooksBlock()]
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: Self.settingsFile))
        }
    }

    private static var hookCommand: String { "\"" + hookScript + "\"" }

    private static func hooksBlock() -> [String: Any] {
        var hooks: [String: Any] = [:]
        for e in hookEvents {
            hooks[e] = [["matcher": "", "hooks": [["type": "command", "command": hookCommand, "timeout": 5]]]]
        }
        return hooks
    }

    // MARK: Global install (~/.claude/settings.json) — opt-in, so agents started anywhere report status

    static func checkGlobalInstalled() -> Bool {
        guard let data = FileManager.default.contents(atPath: claudeSettings),
              let s = String(data: data, encoding: .utf8) else { return false }
        return s.contains("cc-hook.sh")
    }

    func setGlobalHooks(_ enable: Bool) {
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if let data = fm.contents(atPath: Self.claudeSettings) {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastError = "~/.claude/settings.json isn't valid JSON, so it was left untouched."
                return
            }
            root = obj
            let backup = Self.claudeSettings + ".commandcenter-backup"
            if !fm.fileExists(atPath: backup) { try? data.write(to: URL(fileURLWithPath: backup)) }
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for e in Self.hookEvents {
            var groups = (hooks[e] as? [[String: Any]]) ?? []
            // Remove any previous Command Center entries.
            groups = groups.compactMap { g in
                var g = g
                let inner = ((g["hooks"] as? [[String: Any]]) ?? []).filter { !(($0["command"] as? String) ?? "").contains("cc-hook.sh") }
                if inner.isEmpty { return nil }
                g["hooks"] = inner
                return g
            }
            if enable {
                groups.append(["matcher": "", "hooks": [["type": "command", "command": Self.hookCommand, "timeout": 5]]])
            }
            hooks[e] = groups.isEmpty ? nil : groups
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        do {
            try fm.createDirectory(atPath: (Self.claudeSettings as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: URL(fileURLWithPath: Self.claudeSettings), options: .atomic)
            globalHooksInstalled = enable
            lastError = nil
        } catch {
            lastError = "Couldn't update ~/.claude/settings.json: \(error.localizedDescription)"
        }
    }

    // MARK: Event processing

    private func poll() {
        guard let h = FileHandle(forReadingAtPath: Self.eventsFile) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0 } // file was truncated
        guard size > offset else { return }
        try? h.seek(toOffset: offset)
        let data = h.readDataToEndOfFile()
        // Only consume complete lines.
        guard let lastNL = data.lastIndex(of: 0x0A) else { return }
        let chunk = data[data.startIndex...lastNL]
        offset += UInt64(chunk.count)
        for line in chunk.split(separator: 0x0A) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ obj: [String: Any]) {
        guard let e = obj["e"] as? [String: Any], let name = e["hook_event_name"] as? String else { return }
        let message = (e["message"] as? String) ?? ""
        let state: ClaudeState
        switch name {
        case "UserPromptSubmit", "PostToolUse": state = .working
        case "Notification":
            let type = (e["notification_type"] as? String) ?? ""
            state = (type.contains("permission") || message.lowercased().contains("permission")) ? .needsPermission : .waiting
        case "Stop": state = .done
        case "SessionStart": state = .done
        case "SessionEnd": state = .ended
        default: return
        }
        let cwd = (e["cwd"] as? String) ?? ""

        // In-app session?
        if let ccID = obj["cc"] as? String, !ccID.isEmpty, let uuid = UUID(uuidString: ccID),
           let s = sessions?.session(uuid) {
            let previous = s.claudeState
            s.applyHook(state, message: message)
            if state != previous { maybeNotify(state: state, title: s.name, message: message, sessionID: uuid, pid: nil) }
            if state == .needsPermission || state == .done, sessions?.selection != .session(uuid) || !NSApp.isActive {
                if name != "SessionStart" { s.needsAttention = true; sessions?.updateBadge() }
            }
            return
        }

        // External agent: match the hook's parent/grandparent PID to a detected agent.
        let candidates = [obj["ppid"], obj["gppid"]].compactMap { ($0 as? NSNumber)?.int32Value }
        guard let agent = scanner?.agents.first(where: { candidates.contains($0.pid) }) else { return }
        let previous = external[agent.pid]?.0
        if state == .ended { external[agent.pid] = nil } else { external[agent.pid] = (state, message) }
        if state != previous {
            let title = (cwd as NSString).lastPathComponent.isEmpty ? agent.name : (cwd as NSString).lastPathComponent
            maybeNotify(state: state, title: title + " · " + agent.host, message: message, sessionID: nil, pid: agent.pid)
        }
    }

    private func maybeNotify(state: ClaudeState, title: String, message: String, sessionID: UUID?, pid: pid_t?) {
        let body: String
        switch state {
        case .needsPermission:
            guard notifyOnPermission else { return }
            body = message.isEmpty ? "Claude needs your permission to continue." : message
        case .done:
            guard notifyOnDone else { return }
            body = "Claude finished and is waiting for you."
        default: return
        }
        // Don't notify about the session you're looking at.
        if NSApp.isActive {
            if let sessionID, sessions?.selection == .session(sessionID) { return }
            if let pid, sessions?.selection == .external(pid) { return }
        }
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if playSound { content.sound = .default }
        var info: [String: Any] = [:]
        if let sessionID { info["session"] = sessionID.uuidString }
        if let pid { info["pid"] = Int(pid) }
        content.userInfo = info
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if err != nil {
                DispatchQueue.main.async { NSApp.requestUserAttention(.informationalRequest) }
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let id = (info["session"] as? String).flatMap(UUID.init(uuidString:)) {
                self.sessions?.selection = .session(id)
            } else if let pid = info["pid"] as? Int {
                self.sessions?.selection = .external(pid_t(pid))
            }
        }
        completionHandler()
    }
}
