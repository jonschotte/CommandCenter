import Foundation
import Darwin
import AppKit

struct ProcInfo {
    let pid: pid_t
    let ppid: pid_t
    let cpu: Double
    let rssBytes: UInt64
    let elapsed: TimeInterval
    let tty: String
    let args: String
    /// Memory as Activity Monitor's "Memory" column shows it (physical footprint), or RSS if unavailable.
    var memory: UInt64 = 0

    var executable: String { String(args.split(separator: " ", maxSplits: 1).first ?? "") }
    var displayName: String {
        if let r = args.range(of: ".app/") {
            let appPath = args[..<r.lowerBound]
            return (String(appPath) as NSString).lastPathComponent
        }
        return (executable as NSString).lastPathComponent
    }
}

/// Processes grouped under the app they belong to (helpers counted with their app).
struct AppMemoryGroup: Identifiable {
    var id: String { name }
    let name: String
    let total: UInt64
    let cpu: Double
    let procs: [ProcInfo]
    let isApp: Bool
}

enum AgentCategory: String { case agent = "Agent", modelServer = "Model Server" }

struct DetectedAgent: Identifiable {
    var id: pid_t { pid }
    let pid: pid_t
    let name: String           // e.g. "claude"
    let category: AgentCategory
    let args: String
    let cwd: String
    let host: String           // app it's running in (Terminal, Cursor, Command Center…)
    let tty: String
    let elapsed: TimeInterval
    let cpu: Double            // whole process tree
    let rssBytes: UInt64       // whole process tree
    let childCount: Int
    let inApp: Bool            // launched from a Command Center session
}

final class ProcessScanner: ObservableObject {
    @Published private(set) var agents: [DetectedAgent] = []
    @Published private(set) var topByMemory: [ProcInfo] = []
    @Published private(set) var topByCPU: [ProcInfo] = []
    @Published private(set) var processCount = 0
    @Published private(set) var memoryGroups: [AppMemoryGroup] = []

    weak var sessions: SessionStore?
    static weak var shared: ProcessScanner?

    private var timer: Timer?
    private var procs: [pid_t: ProcInfo] = [:]
    private var children: [pid_t: [pid_t]] = [:]
    private let queue = DispatchQueue(label: "scanner", qos: .utility)
    private var cwdCache: [pid_t: String] = [:]
    private let myPid = ProcessInfo.processInfo.processIdentifier

    static let agentNames: [String: AgentCategory] = [
        "claude": .agent, "codex": .agent, "aider": .agent, "gemini": .agent, "opencode": .agent,
        "goose": .agent, "amp": .agent, "cursor-agent": .agent, "crush": .agent, "qwen": .agent,
        "copilot": .agent, "cline": .agent, "openhands": .agent, "kiro": .agent,
        "ollama": .modelServer, "llama-server": .modelServer, "lms": .modelServer,
        "mlx_lm.server": .modelServer, "mlx_lm.chat": .modelServer, "vllm": .modelServer,
    ]
    private static let wrappers: Set<String> = ["node", "bun", "deno", "python", "python3", "uv", "npx"]

    init() { ProcessScanner.shared = self }

    func start() {
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.scan() }
    }

    func descendants(of pid: pid_t) -> [pid_t] {
        var out: [pid_t] = []
        var stack = children[pid] ?? []
        while let p = stack.popLast() {
            out.append(p)
            stack.append(contentsOf: children[p] ?? [])
        }
        return out
    }

    /// Stops every process attached to `tty` (the agent and its shell), then closes the terminal tab if possible.
    func closeTerminal(of agent: DetectedAgent, completion: @escaping (String?) -> Void) {
        let tty = agent.tty
        let onTTY = procs.values.filter { $0.tty == tty }.map(\.pid)
        let targets = Set(onTTY + [agent.pid] + descendants(of: agent.pid))
        for p in targets { kill(p, SIGHUP); kill(p, SIGTERM) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            for p in targets where kill(p, 0) == 0 { kill(p, SIGKILL) }
            guard tty != "??", let host = TerminalBridge.host(for: agent.host) else {
                self.scan(); completion(nil); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                TerminalBridge.closeTab(host, tty: tty) { r in
                    self.scan()
                    if case .failure(let e) = r, !e.message.contains("no longer open") {
                        completion("Processes stopped, but the tab couldn't be closed: \(e.message)")
                    } else {
                        completion(nil)
                    }
                }
            }
        }
    }

    func terminate(_ pid: pid_t, force: Bool = false) {
        kill(pid, force ? SIGKILL : SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.scan() }
    }

    private func scan() {
        let sessionInfo: [(UUID, pid_t, String?)] = sessions?.sessions.filter { $0.isRunning }.map { ($0.id, $0.pid, $0.socketPath) } ?? []
        queue.async { [weak self] in
            guard let self else { return }
            let list = Self.readProcesses()
            var byPid: [pid_t: ProcInfo] = [:]
            var kids: [pid_t: [pid_t]] = [:]
            for p in list { byPid[p.pid] = p; kids[p.ppid, default: []].append(p.pid) }

            func subtree(_ pid: pid_t) -> [pid_t] {
                var out = [pid]; var stack = kids[pid] ?? []
                while let p = stack.popLast() { out.append(p); stack.append(contentsOf: kids[p] ?? []) }
                return out
            }
            func ancestors(_ pid: pid_t) -> [ProcInfo] {
                var out: [ProcInfo] = []; var cur = byPid[pid]?.ppid ?? 0; var guardN = 0
                while cur > 1, let p = byPid[cur], guardN < 64 { out.append(p); cur = p.ppid; guardN += 1 }
                return out
            }
            // A persistent session's processes live under its background keeper ("cc-keeper serve <sock>").
            var sessionPids: [(UUID, pid_t)] = []
            for (id, client, sock) in sessionInfo {
                let server = sock.flatMap { sk in list.first { $0.args.contains("cc-keeper serve " + sk) }?.pid }
                sessionPids.append((id, server ?? client))
            }
            let sessionRoots = Set(sessionPids.map { $0.1 } + sessionInfo.map { $0.1 })

            // Find agents.
            var matched: [(ProcInfo, String, AgentCategory)] = []
            for p in list where p.pid != self.myPid {
                if let (name, cat) = Self.classify(p) { matched.append((p, name, cat)) }
            }
            let matchedPids = Set(matched.map { $0.0.pid })
            matched = matched.filter { !matchedPids.contains($0.0.ppid) } // keep top-level only

            let cwds = Self.readCwds(matched.map { $0.0.pid })
            var agents: [DetectedAgent] = []
            for (p, name, cat) in matched {
                let tree = subtree(p.pid)
                let anc = ancestors(p.pid)
                let inApp = anc.contains { $0.pid == self.myPid || sessionRoots.contains($0.pid) }
                let host: String = inApp ? "Command Center"
                    : anc.first(where: { $0.args.contains(".app/") }).map { Self.hostName($0) } ?? (p.tty == "??" ? "background" : "terminal")
                agents.append(DetectedAgent(
                    pid: p.pid, name: name, category: cat, args: p.args,
                    cwd: cwds[p.pid] ?? "", host: host, tty: p.tty, elapsed: p.elapsed,
                    cpu: tree.compactMap { byPid[$0]?.cpu }.reduce(0, +),
                    rssBytes: tree.compactMap { byPid[$0]?.memory }.reduce(0, +),
                    childCount: tree.count - 1, inApp: inApp))
            }
            agents.sort { ($0.category == .agent ? 0 : 1, -$0.elapsed) < ($1.category == .agent ? 0 : 1, -$1.elapsed) }

            // Per-session resource usage + what's running inside it.
            var sessionStats: [UUID: (Double, UInt64, String, pid_t)] = [:]
            for (id, root) in sessionPids {
                let tree = subtree(root)
                let cpu = tree.compactMap { byPid[$0]?.cpu }.reduce(0, +)
                let rss = tree.compactMap { byPid[$0]?.memory }.reduce(0, +)
                let inner = matched.first { tree.contains($0.0.pid) }?.1 ?? ""
                sessionStats[id] = (cpu, rss, inner, root)
            }

            // Group helper processes under their app for the "top" lists.
            let topMem = Array(list.sorted { $0.memory > $1.memory }.prefix(10))

            var grouped: [String: [ProcInfo]] = [:]
            for p in list { grouped[Self.groupName(p), default: []].append(p) }
            let groups = grouped.map { name, ps in
                AppMemoryGroup(name: name, total: ps.reduce(0) { $0 + $1.memory }, cpu: ps.reduce(0) { $0 + $1.cpu },
                               procs: ps.sorted { $0.memory > $1.memory }, isApp: ps.contains { $0.args.contains(".app/") })
            }.sorted { $0.total > $1.total }
            let topCPU = Array(list.sorted { $0.cpu > $1.cpu }.prefix(10))

            DispatchQueue.main.async {
                self.procs = byPid
                self.children = kids
                self.agents = agents
                self.topByMemory = topMem
                self.memoryGroups = groups
                self.topByCPU = topCPU
                self.processCount = list.count
                for s in self.sessions?.sessions ?? [] {
                    if let st = sessionStats[s.id] {
                        s.cpu = st.0; s.rssBytes = st.1; s.childSummary = st.2
                        if s.rootPid != st.3 { s.rootPid = st.3 }
                    }
                }
            }
        }
    }

    private static func hostName(_ p: ProcInfo) -> String {
        var n = p.displayName.replacingOccurrences(of: ".app", with: "")
        if n == "Code" { n = "VS Code" }
        if n == "iTerm" { n = "iTerm2" }
        return n
    }

    static func classify(_ p: ProcInfo) -> (String, AgentCategory)? {
        if p.args.contains(".app/Contents/") { return nil }
        let parts = p.args.split(separator: " ").map(String.init)
        guard let first = parts.first else { return nil }
        var base = (first as NSString).lastPathComponent
        if base.hasPrefix("-") { base.removeFirst() }
        // Newer Claude Code renames its process to "Claude", so match names case-insensitively.
        base = base.lowercased()
        if let cat = agentNames[base] { return (base, cat) }
        if wrappers.contains(base) || base.hasPrefix("python3.") {
            for arg in parts.dropFirst().prefix(3) where !arg.hasPrefix("-") || arg == "-m" {
                if arg == "-m" { continue }
                var b = (arg as NSString).lastPathComponent.lowercased()
                for ext in [".js", ".mjs", ".cjs", ".py"] where b.hasSuffix(ext) { b = String(b.dropLast(ext.count)) }
                if b == "cli" || b == "index" {
                    // e.g. node …/@anthropic-ai/claude-code/cli.js
                    let lower = arg.lowercased()
                    for name in agentNames.keys where lower.contains("/\(name)") { return (name, agentNames[name]!) }
                }
                if let cat = agentNames[b] { return (b, cat) }
            }
        }
        return nil
    }

    static func readProcesses() -> [ProcInfo] {
        let out = run("/bin/ps", ["-axww", "-o", "pid=,ppid=,pcpu=,rss=,etime=,tty=,args="])
        var list: [ProcInfo] = []
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
            guard f.count == 7, let pid = pid_t(f[0]), let ppid = pid_t(f[1]) else { continue }
            list.append(ProcInfo(pid: pid, ppid: ppid, cpu: Double(f[2]) ?? 0,
                                 rssBytes: (UInt64(f[3]) ?? 0) * 1024, elapsed: parseEtime(String(f[4])),
                                 tty: String(f[5]), args: String(f[6])))
        }
        for i in list.indices {
            list[i].memory = footprint(list[i].pid) ?? list[i].rssBytes
        }
        return list
    }

    /// Physical footprint (what Activity Monitor calls "Memory"). Only readable for your own processes.
    static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return r == 0 ? info.ri_phys_footprint : nil
    }

    /// Name used to group a process: its app bundle, or a friendly name for well-known tools.
    static func groupName(_ p: ProcInfo) -> String {
        if p.args.contains(".app/") {
            var n = p.displayName
            if n == "Code" { n = "VS Code" }
            return n
        }
        if let (name, _) = classify(p) {
            return name == "llama-server" && p.args.contains(".lmstudio") ? "LM Studio (model server)" : name
        }
        let exe = (p.executable as NSString).lastPathComponent
        if p.args.contains("cc-keeper serve") { return "Command Center sessions" }
        if p.args.hasPrefix("/System/") || p.args.hasPrefix("/usr/libexec/") || p.args.hasPrefix("/usr/sbin/") { return "macOS system" }
        return exe.hasPrefix("-") ? String(exe.dropFirst()) : exe
    }

    static func readCwds(_ pids: [pid_t]) -> [pid_t: String] {
        guard !pids.isEmpty else { return [:] }
        let out = run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fpn", "-p", pids.map(String.init).joined(separator: ",")])
        var result: [pid_t: String] = [:]; var cur: pid_t = 0
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { cur = pid_t(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n") { result[cur] = String(line.dropFirst()) }
        }
        return result
    }

    static func parseEtime(_ s: String) -> TimeInterval {
        var days = 0.0; var rest = Substring(s)
        if let dash = s.firstIndex(of: "-") { days = Double(s[..<dash]) ?? 0; rest = s[s.index(after: dash)...] }
        let parts = rest.split(separator: ":").compactMap { Double($0) }
        var secs = 0.0
        for p in parts { secs = secs * 60 + p }
        return days * 86400 + secs
    }

    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
