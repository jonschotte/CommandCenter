import SwiftUI
import AppKit
import Darwin
import SwiftTerm

// Chief bridge: two links between Command Center and Chief (Jonathan's Chief of Staff).
//
// 1. Command Center's own control socket, `~/.commandcenter/control.sock` (NDJSON, one request per
//    line, same user only). Chief's app, CLI and MCP tools use it to list, read and type into the
//    terminals that run here, and to open new ones. It never closes or stops a terminal.
// 2. A "Chief" sidebar section showing the sessions hosted by ChiefHost (its daemon owns those
//    terminals; we attach over its control socket, so they appear here like any other terminal).

typealias CCJSON = [String: Any]

enum CCPaths {
    /// Overridable for tests so a test copy never touches the real sessions.
    static let stateDir: String = {
        if let d = ProcessInfo.processInfo.environment["COMMANDCENTER_STATE_DIR"], !d.isEmpty { return d }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".commandcenter")
    }()
    static var controlSocket: String { stateDir + "/control.sock" }
    static var chiefHostSocket: String {
        ProcessInfo.processInfo.environment["CHIEFHOST_SOCKET"]
            ?? NSHomeDirectory() + "/Library/Application Support/ChiefHost/control.sock"
    }
}

private func ccUnixAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = b }
        raw[bytes.count] = 0
    }
    return addr
}

private func ccWriteAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
        var off = 0
        while off < buf.count {
            let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
            if n < 0 { if errno == EINTR { continue }; return false }
            off += n
        }
        return true
    }
}

private func ccLine(_ obj: CCJSON) -> Data {
    var d = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
    d.append(0x0A)
    return d
}

enum CCKeys {
    static func bytes(_ key: String, applicationCursor: Bool) -> [UInt8]? {
        let k = key.lowercased()
        let arrow: (String) -> [UInt8] = { Array(((applicationCursor ? "\u{1B}O" : "\u{1B}[") + $0).utf8) }
        switch k {
        case "enter", "return": return [0x0D]
        case "esc", "escape": return [0x1B]
        case "tab": return [0x09]
        case "shift-tab": return Array("\u{1B}[Z".utf8)
        case "up": return arrow("A")
        case "down": return arrow("B")
        case "right": return arrow("C")
        case "left": return arrow("D")
        case "backspace": return [0x7F]
        case "space": return [0x20]
        default: break
        }
        if k.hasPrefix("ctrl-"), k.count == 6, let c = k.last, let a = c.asciiValue, c >= "a", c <= "z" { return [a - 96] }
        if key.count == 1, let a = key.first?.asciiValue, a >= 0x20, a < 0x7F { return [a] }
        return nil
    }
}

private func stripControls(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for u in s.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
        let v = u.value
        if v == 0x0A || v == 0x09 || (v >= 0x20 && v != 0x7F && !(v >= 0x80 && v <= 0x9F)) { out.append(u) }
    }
    return String(out)
}

// MARK: - Control socket server

struct CCFailure: Error { let code: String; let message: String }

final class CommandCenterControlServer {
    static let shared = CommandCenterControlServer()
    private var listenFD: Int32 = -1

    func start() {
        let path = CCPaths.controlSocket
        try? FileManager.default.createDirectory(atPath: CCPaths.stateDir, withIntermediateDirectories: true)
        // Another Command Center already answering? Leave its socket alone.
        if SessionVault.isAlive(path) { NSLog("Command Center control socket already in use: \(path)"); return }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = ccUnixAddress(path) else { return }
        // Close-on-exec: otherwise every terminal started from the app inherits this listening socket,
        // keeps it alive after the app quits, and the next launch thinks it's "already in use".
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0, listen(fd, 16) == 0 else { close(fd); return }
        chmod(path, 0o600)
        listenFD = fd
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "CC control accept"
        t.start()
    }

    private func acceptLoop() {
        while true {
            let c = accept(listenFD, nil, nil)
            if c < 0 { if errno == EINTR { continue }; return }
            _ = fcntl(c, F_SETFD, FD_CLOEXEC)
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { close(c); continue }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let t = Thread { [weak self] in self?.serve(c) }
            t.name = "CC control conn"
            t.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &tmp, tmp.count)
            if n < 0 { if errno == EINTR { continue }; return }
            if n == 0 { return }
            buf.append(contentsOf: tmp[0..<n])
            if buf.count > 4 * 1024 * 1024 { return }
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: buf.startIndex..<nl)
                buf.removeSubrange(buf.startIndex...nl)
                if line.isEmpty { continue }
                let reply = handleLine(line)
                if !ccWriteAll(fd, ccLine(reply)) { return }
            }
        }
    }

    private func handleLine(_ line: Data) -> CCJSON {
        guard let req = (try? JSONSerialization.jsonObject(with: line)) as? CCJSON else {
            return ["error": ["code": "bad_json", "message": "each line must be one JSON object"]]
        }
        let id = req["id"] ?? NSNull()
        let method = req["method"] as? String ?? ""
        let params = req["params"] as? CCJSON ?? [:]
        var result: Result<CCJSON, CCFailure> = .failure(CCFailure(code: "internal", message: "no result"))
        // Everything touches SwiftUI/AppKit state, so it runs on the main thread.
        DispatchQueue.main.sync { result = Result { try self.dispatch(method, params) }.mapError { ($0 as? CCFailure) ?? CCFailure(code: "internal", message: "\($0)") } }
        // `send` waits a moment between the text and Enter (Claude Code treats one burst as a paste).
        if case .success(let r) = result, let enter = r["_pendingEnter"] as? String {
            usleep(150_000)
            DispatchQueue.main.sync { _ = try? self.dispatch("terminals.keys", ["id": enter, "keys": ["enter"]]) }
            var clean = r; clean.removeValue(forKey: "_pendingEnter")
            return ["id": id, "result": clean]
        }
        switch result {
        case .success(let r): return ["id": id, "result": r]
        case .failure(let f): return ["id": id, "error": ["code": f.code, "message": f.message]]
        }
    }

    private var store: SessionStore {
        get throws {
            guard let s = SessionStore.shared else { throw CCFailure(code: "starting", message: "Command Center is still starting") }
            return s
        }
    }

    private func find(_ params: CCJSON) throws -> Session {
        let st = try store
        guard let key = (params["id"] as? String) ?? (params["name"] as? String), !key.isEmpty else {
            throw CCFailure(code: "bad_request", message: "id or name required")
        }
        if let s = st.sessions.first(where: { $0.id.uuidString.lowercased() == key.lowercased() || SessionVault.key($0.id) == key.lowercased() }) { return s }
        let byName = st.sessions.filter { $0.name == key }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 { throw CCFailure(code: "ambiguous", message: "\(byName.count) terminals are named \(key); use the id") }
        throw CCFailure(code: "not_found", message: "no terminal \(key)")
    }

    static func describe(_ s: Session) -> CCJSON {
        var r: CCJSON = [
            "id": s.id.uuidString, "shortId": SessionVault.key(s.id), "name": s.name, "folder": s.currentDirectory,
            "kind": s.spec.kind.rawValue, "activity": s.activity.label, "running": s.isRunning,
            "title": s.title, "startedAt": ISO8601DateFormatter().string(from: s.started),
            "needsAttention": s.needsAttention, "cpu": s.cpu, "rssBytes": s.rssBytes,
        ]
        if !s.spec.modelLabel.isEmpty { r["model"] = s.spec.modelLabel }
        if !s.claudeMessage.isEmpty { r["message"] = s.claudeMessage }
        if let g = GroupStore.shared.group(for: GroupKey.of(s)) { r["group"] = g.name }
        return r
    }

    private func screenLines(_ s: Session, _ n: Int) -> [String] {
        let t = s.terminal.getTerminal()
        var out: [String] = []
        for row in 0..<t.rows { out.append(t.getLine(row: row)?.translateToString(trimRight: true) ?? "") }
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
        return Array(out.suffix(n))
    }

    private func write(_ s: Session, _ bytes: [UInt8]) {
        s.terminal.send(source: s.terminal, data: bytes[...])
    }

    func dispatch(_ method: String, _ p: CCJSON) throws -> CCJSON {
        switch method {
        case "ping":
            return ["pong": true, "app": "Command Center", "protocol": 1, "pid": Int(getpid())]

        case "terminals.list":
            let st = try store
            var r: CCJSON = ["terminals": st.sessions.map(Self.describe)]
            if let scanner = ProcessScanner.shared {
                r["outside"] = scanner.agents.filter { !$0.inApp && $0.category == .agent && $0.host != "ChiefHost" }.map { a -> CCJSON in
                    ["pid": Int(a.pid), "name": a.name, "folder": a.cwd, "host": a.host, "uptimeSeconds": Int(a.elapsed)]
                }
            }
            return r

        case "terminals.read":
            let s = try find(p)
            let n = min(max((p["lines"] as? Int) ?? 40, 1), 500)
            return ["terminal": Self.describe(s), "lines": screenLines(s, n)]

        case "terminals.send":
            let s = try find(p)
            guard s.isRunning else { throw CCFailure(code: "not_running", message: "\(s.name) has exited") }
            guard let text = p["text"] as? String, !text.isEmpty else { throw CCFailure(code: "bad_request", message: "text required") }
            if let caller = p["caller"] as? String, caller.lowercased() == s.id.uuidString.lowercased() {
                throw CCFailure(code: "self", message: "a terminal can't type into itself")
            }
            let clean = stripControls(text)
            // Several lines go in as one bracketed paste so a shell doesn't run them one by one.
            let body = clean.contains("\n") && s.terminal.getTerminal().bracketedPasteMode
                ? "\u{1B}[200~" + clean + "\u{1B}[201~" : clean
            write(s, Array(body.utf8))
            s.needsAttention = false
            var r: CCJSON = ["sent": clean.utf8.count, "terminal": s.name]
            if (p["enter"] as? Bool) ?? true { r["_pendingEnter"] = s.id.uuidString; r["enter"] = true }
            return r

        case "terminals.keys":
            let s = try find(p)
            guard s.isRunning else { throw CCFailure(code: "not_running", message: "\(s.name) has exited") }
            let keys = (p["keys"] as? [String]) ?? ((p["keys"] as? String)?.split(separator: " ").map(String.init) ?? [])
            var bytes: [UInt8] = []
            let appCursor = s.terminal.getTerminal().applicationCursor
            for k in keys {
                guard let b = CCKeys.bytes(k, applicationCursor: appCursor) else { throw CCFailure(code: "bad_request", message: "unknown key \(k)") }
                bytes += b
            }
            guard !bytes.isEmpty else { throw CCFailure(code: "bad_request", message: "keys required") }
            write(s, bytes)
            return ["sent": keys]

        case "terminals.open":
            let st = try store
            let folder = (p["folder"] as? String).map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory()
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
                throw CCFailure(code: "bad_request", message: "folder not found: \(folder)")
            }
            let kindName = (p["kind"] as? String ?? "shell").lowercased()
            let name = (p["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (folder as NSString).lastPathComponent
            let spec: LaunchSpec
            switch kindName {
            case "claude":
                var cmd = "claude"
                if let m = p["model"] as? String, !m.isEmpty { cmd += " --model " + shellQuote(m) }
                spec = LaunchSpec(name: name, directory: folder, kind: .claude, model: p["model"] as? String ?? "",
                                  modelLabel: p["model"] as? String ?? "", command: cmd)
            case "shell":
                spec = LaunchSpec(name: name, directory: folder, kind: .shell, model: "", modelLabel: "", command: "")
            case "command":
                guard let c = p["command"] as? String, !c.isEmpty else { throw CCFailure(code: "bad_request", message: "command required") }
                spec = LaunchSpec(name: name, directory: folder, kind: .custom, model: "", modelLabel: "", command: c)
            default:
                throw CCFailure(code: "bad_request", message: "kind must be shell, claude or command")
            }
            let previous = st.selection
            let s = st.launch(spec)
            if (p["select"] as? Bool) != true { st.selection = previous }
            if let g = p["group"] as? String, let grp = GroupStore.shared.groups.first(where: { $0.name == g }) {
                GroupStore.shared.assign(GroupKey.of(s), to: grp)
            }
            return ["terminal": Self.describe(s)]

        case "terminals.show":
            let st = try store
            let s = try find(p)
            st.selection = .session(s.id)
            return ["shown": s.name]

        default:
            throw CCFailure(code: "unknown_method", message: method)
        }
    }
}

// MARK: - ChiefHost link (Chief's session host)

private final class CHClient {
    let fd: Int32
    private var buf = Data()
    private var nextId = 1

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = ccUnixAddress(path) else { throw CCFailure(code: "io", message: "socket") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if rc != 0 { close(fd); throw CCFailure(code: "not_running", message: "ChiefHost isn't running") }
    }
    deinit { close(fd) }
    func shutdownNow() { shutdown(fd, SHUT_RDWR) }

    func call(_ method: String, _ params: CCJSON, timeout: TimeInterval?, onEvent: ((CCJSON) -> Void)? = nil) throws -> CCJSON {
        let id = nextId; nextId += 1
        guard ccWriteAll(fd, ccLine(["id": id, "method": method, "params": params])) else { throw CCFailure(code: "io", message: "write") }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        var tmp = [UInt8](repeating: 0, count: 65536)
        while true {
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: buf.startIndex..<nl)
                buf.removeSubrange(buf.startIndex...nl)
                guard let m = (try? JSONSerialization.jsonObject(with: line)) as? CCJSON, (m["id"] as? Int) == id else { continue }
                if let ev = m["event"] as? CCJSON { onEvent?(ev); continue }
                if let e = m["error"] as? CCJSON { throw CCFailure(code: e["code"] as? String ?? "error", message: e["message"] as? String ?? "") }
                return m["result"] as? CCJSON ?? [:]
            }
            var ms: Int32 = -1
            if let deadline { let left = deadline.timeIntervalSinceNow; if left <= 0 { throw CCFailure(code: "timeout", message: "timed out") }; ms = Int32(left * 1000) }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, ms)
            if pr < 0 { if errno == EINTR { continue }; throw CCFailure(code: "io", message: "poll") }
            if pr == 0 { throw CCFailure(code: "timeout", message: "timed out") }
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { throw CCFailure(code: "io", message: "ChiefHost closed the connection") }
            buf.append(contentsOf: tmp[0..<n])
        }
    }

    static func oneShot(_ method: String, _ params: CCJSON = [:]) throws -> CCJSON {
        try CHClient(path: CCPaths.chiefHostSocket).call(method, params, timeout: 10)
    }
}

struct ChiefSessionInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let cwd: String
    let status: String
    let blockedReason: String?
    let backend: String
    let model: String?
    let costUSD: Double?

    var activity: SessionActivity {
        switch status {
        case "working", "starting": return .working
        case "blocked": return .needsYou
        case "done": return .yourTurn
        case "stopped", "error": return .exited
        default: return .idle
        }
    }
    var statusLabel: String { status == "blocked" ? "Needs you (\(blockedReason ?? "?"))" : status.capitalized }
}

final class ChiefHostLink: ObservableObject {
    static let shared = ChiefHostLink()
    @Published var sessions: [ChiefSessionInfo] = []
    @Published var connected = false
    private var timer: Timer?
    private let queue = DispatchQueue(label: "cc.chiefhost.poll")

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        queue.async {
            let r = try? CHClient.oneShot("sessions.list")
            let list = (r?["sessions"] as? [CCJSON] ?? []).map { s in
                ChiefSessionInfo(id: s["id"] as? String ?? "", name: s["name"] as? String ?? "", cwd: s["cwd"] as? String ?? "",
                                 status: s["status"] as? String ?? "idle", blockedReason: s["blockedReason"] as? String,
                                 backend: s["backend"] as? String ?? "claude", model: s["model"] as? String,
                                 costUSD: (s["costUSD"] as? NSNumber)?.doubleValue)
            }
            DispatchQueue.main.async {
                if self.connected != (r != nil) { self.connected = r != nil }
                if self.sessions != list { self.sessions = list }
            }
        }
    }

    func perform(_ method: String, id: String) {
        queue.async { _ = try? CHClient.oneShot(method, ["target": id]); self.refresh() }
    }

    static func openChiefHostApp() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", NSHomeDirectory() + "/Applications/ChiefHost.app"]
        try? p.run()
    }
}

struct ChiefSessionRow: View {
    let info: ChiefSessionInfo
    var body: some View {
        HStack(spacing: 8) {
            ActivityDot(activity: info.activity, size: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.name).lineLimit(1)
                Text(abbreviatePath(info.cwd)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if info.status == "blocked" { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
        }
    }
}

/// A ChiefHost session shown as a live terminal. ChiefHost's daemon owns the process; closing this
/// view only detaches.
struct ChiefSessionView: View {
    @ObservedObject var link = ChiefHostLink.shared
    let id: String

    var body: some View {
        if let info = link.sessions.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    IconBadge(symbol: "person.crop.circle.badge.checkmark", color: .purple, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(info.name).font(.headline).lineLimit(1)
                            Text("Chief").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.purple.gradient))
                            StatusPill(activity: info.activity)
                            if let m = info.model, !m.isEmpty {
                                Text(m).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(.quaternary))
                            }
                        }
                        HStack(spacing: 10) {
                            Text(abbreviatePath(info.cwd)).lineLimit(1).truncationMode(.middle)
                            Text("· hosted by ChiefHost")
                            if let c = info.costUSD, c > 0 { Text(String(format: "· ≈$%.2f", c)) }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button { reveal(info.cwd) } label: { Image(systemName: "folder") }.help("Reveal folder in Finder")
                    if info.status == "stopped" || info.status == "error" {
                        Button { link.perform("session.restart", id: id) } label: { Image(systemName: "play.fill") }.help("Start again (resumes the conversation)")
                    } else {
                        Button { link.perform("session.restart", id: id) } label: { Image(systemName: "arrow.clockwise") }.help("Restart (resumes the conversation)")
                        Button { link.perform("session.stop", id: id) } label: { Image(systemName: "stop.fill") }.help("Stop")
                    }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14).padding(.vertical, 10)
                Rectangle().fill(info.activity == .idle || info.activity == .exited ? Color(nsColor: .separatorColor) : info.activity.color)
                    .frame(height: info.activity == .idle || info.activity == .exited ? 1 : 2)
                ChiefTerminalPane(sessionId: id).id(id)
                    .frame(minWidth: 200, maxWidth: .infinity, minHeight: 150, maxHeight: .infinity)
                    .background(Color(nsColor: TerminalProfile.current.background))
                    .clipped()
            }
            .navigationTitle(info.name)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "moon.zzz").font(.largeTitle).foregroundStyle(.secondary)
                Text(link.connected ? "This Chief session was removed." : "ChiefHost isn't running.").font(.headline)
                if !link.connected { Button("Start ChiefHost") { ChiefHostLink.openChiefHostApp() } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ChiefTerminalPane: NSViewRepresentable {
    let sessionId: String
    func makeCoordinator() -> Coordinator { Coordinator(sessionId: sessionId) }

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        TerminalProfile.current.apply(to: tv)
        tv.terminalDelegate = context.coordinator
        context.coordinator.attach(tv)
        return tv
    }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) { coordinator.detach() }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let sessionId: String
        weak var view: TerminalView?
        private let lock = NSLock()
        private var client: CHClient?
        private var detached = false
        private let inputQueue = DispatchQueue(label: "cc.chiefhost.input")
        private var inputClient: CHClient?

        init(sessionId: String) { self.sessionId = sessionId }

        func attach(_ tv: TerminalView) {
            view = tv
            let term = tv.getTerminal()
            let cols = term.cols, rows = term.rows, sid = sessionId
            let t = Thread { [weak self] in
                guard let self else { return }
                do {
                    let c = try CHClient(path: CCPaths.chiefHostSocket)
                    self.lock.lock()
                    if self.detached { self.lock.unlock(); return }
                    self.client = c
                    self.lock.unlock()
                    _ = try c.call("session.attach", ["target": sid, "cols": cols, "rows": rows], timeout: nil) { [weak self] ev in
                        switch ev["type"] as? String {
                        case "snapshot":
                            let lines = ev["lines"] as? [String] ?? []
                            let cx = ev["cursorX"] as? Int ?? 0, cy = ev["cursorY"] as? Int ?? 0
                            let text = "\u{1B}[2J\u{1B}[H" + lines.joined(separator: "\r\n") + "\u{1B}[\(cy + 1);\(cx + 1)H"
                            DispatchQueue.main.async { self?.view?.feed(text: text) }
                        case "output":
                            if let b = ev["data"] as? String, let d = Data(base64Encoded: b) {
                                let bytes = [UInt8](d)
                                DispatchQueue.main.async { self?.view?.feed(byteArray: bytes[...]) }
                            }
                        default: break
                        }
                    }
                } catch {
                    DispatchQueue.main.async { self.view?.feed(text: "\r\n[Couldn't attach to ChiefHost: \((error as? CCFailure)?.message ?? "\(error)")]\r\n") }
                }
            }
            t.name = "CC ChiefHost attach"
            t.start()
        }

        func detach() {
            lock.lock(); detached = true; client?.shutdownNow(); client = nil; lock.unlock()
        }

        private func sendToHost(_ method: String, _ params: CCJSON) {
            inputQueue.async { [weak self] in
                guard let self else { return }
                for _ in 0..<2 {
                    do {
                        if self.inputClient == nil { self.inputClient = try CHClient(path: CCPaths.chiefHostSocket) }
                        _ = try self.inputClient!.call(method, params, timeout: 10)
                        return
                    } catch { self.inputClient = nil }
                }
            }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            sendToHost("session.input", ["target": sessionId, "data": Data(data).base64EncodedString()])
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            sendToHost("session.resize", ["target": sessionId, "cols": newCols, "rows": newRows])
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
