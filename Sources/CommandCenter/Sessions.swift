import SwiftUI
import AppKit
import SwiftTerm

enum AgentKind: String, CaseIterable, Identifiable, Codable {
    case claude = "Claude Code"
    case local = "Local Model"
    case shell = "Shell"
    case custom = "Custom Command"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .claude: return "sparkles"
        case .local: return "cpu"
        case .shell: return "terminal"
        case .custom: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

enum SessionActivity {
    case working, needsYou, yourTurn, idle, exited
    var label: String {
        switch self {
        case .working: return "Working"
        case .needsYou: return "Needs you"
        case .yourTurn: return "Your turn"
        case .idle: return "Idle"
        case .exited: return "Exited"
        }
    }
    var explanation: String {
        switch self {
        case .working: return "Green: busy right now, producing output or running tools"
        case .needsYou: return "Orange: blocked until you answer, usually a permission prompt"
        case .yourTurn: return "Blue: finished and waiting for your next message"
        case .idle: return "Gray: nothing happening"
        case .exited: return "Faded gray: the program has ended"
        }
    }
    /// Card border tint: only states that ask for your attention get color.
    var tileTint: SwiftUI.Color {
        switch self {
        case .working, .needsYou, .yourTurn: return color
        default: return .gray
        }
    }
    var color: SwiftUI.Color {
        switch self {
        case .working: return .green
        case .needsYou: return .orange
        case .yourTurn: return .blue
        case .idle: return .gray
        case .exited: return .gray.opacity(0.5)
        }
    }
}

/// Terminal view that reports when output arrives, so we can tell "working" from "waiting for you".
final class SessionTerminalView: LocalProcessTerminalView {
    var onData: (() -> Void)?
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onData?()
    }

    /// ⌘V with an image (or copied files) on the clipboard types the file path(s), the way dropping a file
    /// into Terminal does. Claude Code picks up image paths as attachments. Plain text pastes as usual.
    override func paste(_ sender: Any) {
        let pb = NSPasteboard.general
        let files = ImageAttach.fileURLs(pb)
        if pb.string(forType: .string) == nil || !files.isEmpty {
            let paths = ImageAttach.imagePaths(pb, includeAllFiles: true)
            if !paths.isEmpty { typePaths(paths); return }
        }
        super.paste(sender)
    }

    private func typePaths(_ paths: [String]) {
        // Sent as a bracketed paste when the program asks for it, like a real paste/drop.
        var text = paths.map(ImageAttach.shellEscaped).joined(separator: " ") + " "
        if getTerminal().bracketedPasteMode { text = "\u{1B}[200~" + text + "\u{1B}[201~" }
        send(data: Array(text.utf8)[...])
        window?.makeFirstResponder(self)
    }

    private var dropRegistered = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !dropRegistered { registerForDraggedTypes([.fileURL, .png, .tiff]); dropRegistered = true }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = ImageAttach.imagePaths(sender.draggingPasteboard, includeAllFiles: true)
        guard !paths.isEmpty else { return false }
        typePaths(paths)
        return true
    }
}

struct LaunchSpec: Codable {
    var name: String
    var directory: String
    var kind: AgentKind
    var model: String          // claude model alias / local model path / ""
    var modelLabel: String     // human readable
    var command: String        // shell command to run ("" = plain shell)
}

/// On-disk record of a running session so it can be reattached after the app restarts.
struct SessionRecord: Codable {
    let id: UUID
    let spec: LaunchSpec
    let started: Date
}

/// Where persistent sessions live. Paths are kept short: unix socket paths max out at 104 bytes.
enum SessionVault {
    static let dir: String = {
        let d = CCPaths.stateDir + "/s"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }()
    static var keeper: String? {
        guard let p = Bundle.main.url(forAuxiliaryExecutable: "cc-keeper")?.path,
              FileManager.default.isExecutableFile(atPath: p) else { return nil }
        return p
    }
    static func key(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }
    static func socket(_ id: UUID) -> String { dir + "/" + key(id) + ".sock" }
    static func record(_ id: UUID) -> String { dir + "/" + key(id) + ".json" }

    static func save(_ r: SessionRecord) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(r).write(to: URL(fileURLWithPath: record(r.id)))
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(atPath: record(id))
        try? FileManager.default.removeItem(atPath: socket(id))
    }

    /// Sessions whose background keeper is still alive. Stale records are cleaned up.
    static func survivors() -> [SessionRecord] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var out: [SessionRecord] = []
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: dir + "/" + f),
                  let r = try? dec.decode(SessionRecord.self, from: data) else {
                try? FileManager.default.removeItem(atPath: dir + "/" + f); continue
            }
            if isAlive(socket(r.id)) { out.append(r) } else { remove(r.id) }
        }
        return out.sorted { $0.started < $1.started }
    }

    static func isAlive(_ path: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
        }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return r == 0
    }
}

final class Session: ObservableObject, Identifiable {
    let id: UUID
    private(set) var spec: LaunchSpec
    let started: Date
    let terminal: SessionTerminalView
    let persistent: Bool
    let restored: Bool

    /// Last few non-empty lines on screen, for dashboard previews.
    func preview(lines n: Int) -> [String] {
        let t = terminal.getTerminal()
        var out: [String] = []
        var row = t.rows - 1
        while row >= 0 && out.count < n {
            if let line = t.getLine(row: row)?.translateToString(trimRight: true).replacingOccurrences(of: "\u{0}", with: " "),
               !line.trimmingCharacters(in: .whitespaces).isEmpty { out.insert(line, at: 0) }
            row -= 1
        }
        return out
    }

    @Published var title: String = ""
    @Published var currentDirectory: String
    @Published var isRunning = true
    @Published var exitCode: Int32?
    @Published var lastOutput = Date.distantPast
    @Published var needsAttention = false
    @Published var cpu: Double = 0
    @Published var rssBytes: UInt64 = 0
    @Published var childSummary: String = ""
    /// PID of the process tree's root: the background keeper if persistent, else the shell.
    @Published var rootPid: pid_t = 0
    /// State reported by Claude Code's hooks (nil until the first event arrives).
    @Published var claudeState: ClaudeState?
    @Published var claudeMessage: String = ""

    private var burstStart: Date?

    var name: String { spec.name }
    var pid: pid_t { terminal.process.shellPid }
    var socketPath: String? { persistent ? SessionVault.socket(id) : nil }

    var activity: SessionActivity {
        if !isRunning { return .exited }
        if let st = claudeState {
            switch st {
            case .working: return .working
            case .needsPermission: return .needsYou
            case .waiting, .done: return .yourTurn
            case .ended: break
            }
        }
        return Date().timeIntervalSince(lastOutput) < 2.5 ? .working : .idle
    }

    init(spec: LaunchSpec, id: UUID = UUID(), started: Date = Date(), restored: Bool = false) {
        self.id = id
        self.spec = spec
        self.started = started
        self.restored = restored
        self.persistent = SessionVault.keeper != nil
        self.currentDirectory = spec.directory
        terminal = SessionTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        TerminalProfile.current.apply(to: terminal)
        terminal.onData = { [weak self] in
            DispatchQueue.main.async { self?.noteOutput() }
        }
    }

    private func noteOutput() {
        let now = Date()
        if now.timeIntervalSince(lastOutput) > 2.5 { burstStart = now }
        // Throttle publishes: at most ~3/sec.
        if now.timeIntervalSince(lastOutput) > 0.3 { lastOutput = now }
    }

    /// Called every second by the store. For sessions without hook data, flags one that just finished
    /// a long burst of output (probably done and waiting for you).
    func tick(isSelected: Bool) {
        defer { objectWillChange.send() } // refresh activity dots
        guard claudeState == nil, isRunning, let start = burstStart else { return }
        let idleFor = Date().timeIntervalSince(lastOutput)
        if idleFor > 3, lastOutput.timeIntervalSince(start) > 4 {
            burstStart = nil
            if !isSelected { needsAttention = true }
        } else if idleFor > 3 {
            burstStart = nil
        }
    }

    func start(delegate: LocalProcessTerminalViewDelegate) {
        terminal.processDelegate = delegate
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("CLAUDECODE") || key.hasPrefix("CLAUDE_CODE_") || key == "TERM_PROGRAM" {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "CommandCenter"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["COMMAND_CENTER_SESSION"] = spec.name
        env["COMMAND_CENTER_SESSION_ID"] = id.uuidString
        let envList = env.map { "\($0.key)=\($0.value)" }

        var command = spec.command
        if spec.kind == .claude, let flag = AgentEvents.settingsFlag, command.hasPrefix("claude") {
            command = "claude " + flag + command.dropFirst("claude".count)
        }
        var shellArgs = ["/bin/zsh", "-l", "-i"]
        if !command.isEmpty {
            // Run the agent, then drop into a shell in the same folder so the tab stays useful.
            shellArgs += ["-c", "\(command); echo; echo '── session ended · shell ready ──'; exec /bin/zsh -l -i"]
        }

        if let keeper = SessionVault.keeper {
            let sock = SessionVault.socket(id)
            if !restored { SessionVault.save(SessionRecord(id: id, spec: spec, started: started)) }
            let args = restored ? ["open", sock] : ["open", sock, "--"] + shellArgs
            terminal.startProcess(executable: keeper, args: args, environment: envList, execName: nil,
                                  currentDirectory: spec.directory)
        } else {
            terminal.startProcess(executable: shellArgs[0], args: Array(shellArgs.dropFirst()), environment: envList,
                                  execName: "-zsh", currentDirectory: spec.directory)
        }
    }

    func applyHook(_ state: ClaudeState, message: String) {
        claudeState = state == .ended ? nil : state
        claudeMessage = message
    }

    /// A session still named after its folder (the default) takes its name from the first real prompt,
    /// so two terminals opened in the same folder can be told apart. A name someone chose is kept.
    func adoptNameFromPrompt(_ prompt: String) {
        guard spec.name == (spec.directory as NSString).lastPathComponent,
              let title = Self.title(fromPrompt: prompt) else { return }
        objectWillChange.send()
        spec.name = title
        if persistent { SessionVault.save(SessionRecord(id: id, spec: spec, started: started)) }
    }

    static func title(fromPrompt prompt: String) -> String? {
        let line = prompt.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        // Slash commands and shell escapes say little about the task; wait for a real prompt.
        guard !line.isEmpty, !line.hasPrefix("/"), !line.hasPrefix("!") else { return nil }
        let words = line.split(separator: " ").joined(separator: " ")
        return words.count <= 40 ? words : String(words.prefix(39)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

final class SessionStore: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    @Published var sessions: [Session] = []
    @Published var selection: SidebarItem? = .dashboard
    @Published var showNewSession = false
    @Published var newSessionPreset: LaunchSpec?
    @Published var pendingClose: Session?
    @Published var pendingExternalClose: DetectedAgent?
    @Published var closeError: String?
    @Published var recentDirectories: [String] = UserDefaults.standard.stringArray(forKey: "recentDirectories") ?? []

    static weak var shared: SessionStore?
    static var liveCount: Int { shared?.sessions.filter { $0.isRunning }.count ?? 0 }

    private var timer: Timer?

    override init() {
        super.init()
        SessionStore.shared = self
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            for s in self.sessions { s.tick(isSelected: self.selection == .session(s.id)) }
            self.updateBadge()
        }
        DispatchQueue.main.async { self.restoreSurvivors() }
    }

    func updateBadge() {
        let attention = sessions.filter { $0.needsAttention }.count
        NSApp.dockTile.badgeLabel = attention > 0 ? "\(attention)" : nil
    }

    /// Reattach to sessions that kept running while the app was closed.
    private func restoreSurvivors() {
        let records = SessionVault.survivors()
        for r in records where session(r.id) == nil {
            let s = Session(spec: r.spec, id: r.id, started: r.started, restored: true)
            sessions.append(s)
            s.start(delegate: self)
        }
        if let first = records.first, selection == .dashboard, records.count == 1 { selection = .session(first.id) }
    }

    /// Asks before closing a session that's still running.
    func requestClose(_ s: Session) {
        if s.isRunning { pendingClose = s } else { close(s) }
    }

    func requestExternalClose(_ a: DetectedAgent) { pendingExternalClose = a }

    func confirmExternalClose() {
        guard let a = pendingExternalClose else { return }
        pendingExternalClose = nil
        if selection == .external(a.pid) { selection = .dashboard }
        ProcessScanner.shared?.closeTerminal(of: a) { err in self.closeError = err }
    }

    @discardableResult
    func launch(_ spec: LaunchSpec) -> Session {
        let s = Session(spec: spec)
        sessions.append(s)
        s.start(delegate: self)
        rememberDirectory(spec.directory)
        selection = .session(s.id)
        return s
    }

    func session(_ id: UUID) -> Session? { sessions.first { $0.id == id } }

    /// One click: a plain shell, in the folder of the session you're looking at (or the last folder used).
    @discardableResult
    func newTerminal(in dir: String? = nil) -> Session {
        var d = dir
        if d == nil, case .session(let id) = selection { d = session(id)?.currentDirectory }
        let directory = d ?? recentDirectories.first ?? NSHomeDirectory()
        return launch(LaunchSpec(name: (directory as NSString).lastPathComponent, directory: directory,
                                 kind: .shell, model: "", modelLabel: "", command: ""))
    }

    /// Starts Claude Code right away, in the selected session's folder or the most recent one.
    @discardableResult
    func newClaude(skipPermissions: Bool, in dir: String? = nil) -> Session {
        var d = dir
        if d == nil, case .session(let id) = selection { d = session(id)?.currentDirectory }
        let directory = d ?? recentDirectories.first ?? NSHomeDirectory()
        let command = skipPermissions ? "claude --dangerously-skip-permissions" : "claude"
        return launch(LaunchSpec(name: (directory as NSString).lastPathComponent, directory: directory,
                                 kind: .claude, model: "", modelLabel: skipPermissions ? "Claude · no prompts" : "Claude",
                                 command: command))
    }

    /// Reopens an agent that's running in another terminal as a full Command Center session.
    /// For Claude, resumes the exact same conversation. If `closeOriginal`, the old tab is closed first
    /// so the conversation isn't open in two places.
    func moveHere(_ a: DetectedAgent, closeOriginal: Bool) {
        let dir = a.cwd.isEmpty ? NSHomeDirectory() : a.cwd
        var command = ""
        var kind = AgentKind.shell
        if a.name == "claude" {
            kind = .claude
            if let id = Self.claudeSessionID(pid: a.pid) { command = "claude --resume " + shellQuote(id) }
            else { command = "claude --continue" }
            // Keep the model/permission flags it was started with.
            for flag in ["--dangerously-skip-permissions"] where a.args.contains(flag) { command += " " + flag }
            if let r = a.args.range(of: #"--model[ =](\S+)"#, options: .regularExpression) {
                command += " " + a.args[r].replacingOccurrences(of: "=", with: " ")
            }
        } else if !a.args.isEmpty {
            kind = .custom
            command = a.args
        }
        let spec = LaunchSpec(name: (dir as NSString).lastPathComponent, directory: dir, kind: kind,
                              model: "", modelLabel: "", command: command)
        if closeOriginal {
            ProcessScanner.shared?.closeTerminal(of: a) { err in if let err { self.closeError = err } }
            // Give the old process a moment to exit before resuming its conversation.
            let oldKey = GroupKey.of(a)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let s = self.launch(spec)
                GroupStore.shared.transfer(from: oldKey, to: GroupKey.of(s))
            }
        } else {
            let s = launch(spec)
            if let g = GroupStore.shared.group(for: GroupKey.of(a)) { GroupStore.shared.assign(GroupKey.of(s), to: g) }
        }
    }

    /// Claude Code records each running session in ~/.claude/sessions/<pid>.json.
    static func claudeSessionID(pid: pid_t) -> String? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/sessions/\(pid).json")
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["sessionId"] as? String
    }

    func restart(_ s: Session) {
        stop(s)
        let spec = s.spec
        remove(s)
        let new = launch(spec)
        GroupStore.shared.transfer(from: GroupKey.of(s), to: GroupKey.of(new))
    }

    /// Stops the session's whole process tree (including its background keeper).
    func stop(_ s: Session) {
        let roots = [s.rootPid, s.pid].filter { $0 > 0 }
        guard !roots.isEmpty else { return }
        var pids: [pid_t] = []
        for r in roots { pids += (ProcessScanner.shared?.descendants(of: r) ?? []) + [r] }
        for p in pids.reversed() { kill(p, SIGHUP); kill(p, SIGTERM) }
        let id = s.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for p in pids where kill(p, 0) == 0 { kill(p, SIGKILL) }
            if self.session(id) == nil { SessionVault.remove(id) }
        }
    }

    /// Stops every session. Used by "Stop All & Quit" (synchronous, so it finishes before exit).
    func stopAllNow() {
        for s in sessions {
            var pids: [pid_t] = []
            for r in [s.rootPid, s.pid] where r > 0 { pids += (ProcessScanner.shared?.descendants(of: r) ?? []) + [r] }
            for p in pids.reversed() { kill(p, SIGHUP); kill(p, SIGTERM) }
            SessionVault.remove(s.id)
        }
    }

    func close(_ s: Session) {
        stop(s)
        GroupStore.shared.forget(GroupKey.of(s))
        remove(s)
        SessionVault.remove(s.id)
    }

    private func remove(_ s: Session) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) {
            sessions.remove(at: i)
            if selection == .session(s.id) {
                selection = sessions.isEmpty ? .dashboard : .session(sessions[max(0, i - 1)].id)
            }
        }
        updateBadge()
    }

    func rememberDirectory(_ dir: String) {
        var r = recentDirectories.filter { $0 != dir }
        r.insert(dir, at: 0)
        recentDirectories = Array(r.prefix(12))
        UserDefaults.standard.set(recentDirectories, forKey: "recentDirectories")
    }

    // MARK: LocalProcessTerminalViewDelegate
    private func owner(_ source: TerminalView) -> Session? { sessions.first { $0.terminal === source } }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { self.owner(source)?.title = title }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory) else { return }
        DispatchQueue.main.async { self.owner(source)?.currentDirectory = url.path.isEmpty ? directory : url.path }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            guard let s = self.owner(source) else { return }
            s.isRunning = false
            s.exitCode = exitCode
            s.claudeState = nil
            if let sock = s.socketPath, !SessionVault.isAlive(sock) { SessionVault.remove(s.id) }
        }
    }
}

/// Hosts a session's long-lived terminal NSView inside SwiftUI without recreating it.
/// The container always takes exactly the size SwiftUI offers, and the terminal follows it
/// with plain autoresizing, so the terminal never forces the detail pane wider than the window.
final class TerminalContainer: NSView {
    weak var terminal: NSView?
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func layout() {
        super.layout()
        if let t = terminal {
            t.frame = NSRect(x: bounds.minX + 6, y: bounds.minY, width: max(0, bounds.width - 6), height: max(0, bounds.height - 4))
        }
    }
}

struct TerminalHost: NSViewRepresentable {
    let session: Session

    func makeNSView(context: Context) -> TerminalContainer {
        let container = TerminalContainer()
        container.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.setContentHuggingPriority(.defaultLow, for: .vertical)
        container.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        attach(to: container)
        return container
    }

    func updateNSView(_ container: TerminalContainer, context: Context) {
        if container.terminal !== session.terminal { attach(to: container) }
    }

    /// Accept whatever size SwiftUI proposes instead of the terminal's own preferred size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 400)
    }

    private func attach(to container: TerminalContainer) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let t = session.terminal
        t.removeFromSuperview()
        t.translatesAutoresizingMaskIntoConstraints = true
        t.autoresizingMask = [.width, .height]
        container.terminal = t
        container.addSubview(t)
        container.needsLayout = true
        DispatchQueue.main.async { t.window?.makeFirstResponder(t) }
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func formatBytes(_ b: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
}

func formatDuration(_ t: TimeInterval) -> String {
    let s = Int(t)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
    return "\(s / 86400)d \((s % 86400) / 3600)h"
}

func abbreviatePath(_ p: String) -> String {
    let home = NSHomeDirectory()
    return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
}
