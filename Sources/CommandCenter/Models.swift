import Foundation
import AppKit

struct LocalModel: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let format: String      // "MLX", "Safetensors", "GGUF"
    let modelType: String   // from config.json (qwen3, whisper, …)
    let sizeBytes: UInt64
    let source: String      // "LM Studio", "Hugging Face", "Custom"

    var isChatCapable: Bool {
        format != "GGUF" && !["whisper", "clip", "siglip", "bert", "t5"].contains(modelType.lowercased())
    }
}

struct Endpoint: Identifiable, Hashable {
    var id: String { baseURL }
    let name: String
    let baseURL: String     // e.g. http://127.0.0.1:8080/v1
    var models: [String]
}

struct ChatMessage: Identifiable {
    let id = UUID()
    var role: String
    var content: String
}

enum ServerState: Equatable {
    case stopped, starting, running, failed(String)
    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Loading model…"
        case .running: return "Running"
        case .failed(let m): return "Failed: \(m)"
        }
    }
}

final class ModelManager: ObservableObject {
    static weak var shared: ModelManager?
    static var serverRunning: Bool { shared?.serverProcess?.isRunning == true }

    @Published var models: [LocalModel] = []
    @Published var isScanning = false
    @Published var engineInstalled = false
    @Published var customFolders: [String] = UserDefaults.standard.stringArray(forKey: "customModelFolders") ?? []

    // Server
    @Published var serverState: ServerState = .stopped
    @Published var serverModel: LocalModel?
    @Published var serverLog: [String] = []
    @Published var port: Int = UserDefaults.standard.object(forKey: "serverPort") as? Int ?? 8080 {
        didSet { UserDefaults.standard.set(port, forKey: "serverPort") }
    }
    @Published var exposeOnNetwork: Bool = UserDefaults.standard.bool(forKey: "exposeOnNetwork") {
        didSet { UserDefaults.standard.set(exposeOnNetwork, forKey: "exposeOnNetwork") }
    }
    private(set) var serverProcess: Process?

    // Chat
    @Published var endpoints: [Endpoint] = []
    @Published var chatEndpoint: Endpoint?
    @Published var chatModel: String = ""
    @Published var messages: [ChatMessage] = []
    @Published var systemPrompt: String = ""
    @Published var isGenerating = false
    @Published var chatError: String?
    private var chatTask: Task<Void, Never>?

    static let appSupport: String = {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/CommandCenter")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()
    static var venv: String { (appSupport as NSString).appendingPathComponent("venv") }
    static var venvBin: String { (venv as NSString).appendingPathComponent("bin") }

    static var installCommand: String {
        let v = shellQuote(venv)
        return """
        set -e; echo '▶ Installing uv (Python manager)…'; \
        if [ ! -x "$HOME/.local/bin/uv" ]; then curl -LsSf https://astral.sh/uv/install.sh | sh; fi; \
        echo '▶ Creating Python 3.12 environment…'; "$HOME/.local/bin/uv" venv --python 3.12 \(v); \
        echo '▶ Installing mlx-lm…'; "$HOME/.local/bin/uv" pip install --python \(v)/bin/python -U mlx-lm; \
        echo; echo '✅ MLX engine installed. Go back to Models and press Refresh.'
        """
    }

    init() { ModelManager.shared = self }

    var lanAddress: String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let p = ptr {
            let name = String(cString: p.pointee.ifa_name)
            if name.hasPrefix("en"), let a = p.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                return String(cString: host)
            }
            ptr = p.pointee.ifa_next
        }
        return nil
    }

    var localBaseURL: String { "http://127.0.0.1:\(port)/v1" }

    // MARK: Discovery

    func refresh() {
        engineInstalled = FileManager.default.isExecutableFile(atPath: Self.venvBin + "/mlx_lm.server")
        isScanning = true
        let folders = customFolders
        DispatchQueue.global(qos: .utility).async {
            let found = Self.discover(customFolders: folders)
            DispatchQueue.main.async {
                self.models = found
                self.isScanning = false
            }
        }
        probeEndpoints()
    }

    func addFolder(_ path: String) {
        guard !customFolders.contains(path) else { return }
        customFolders.append(path)
        UserDefaults.standard.set(customFolders, forKey: "customModelFolders")
        refresh()
    }

    func removeFolder(_ path: String) {
        customFolders.removeAll { $0 == path }
        UserDefaults.standard.set(customFolders, forKey: "customModelFolders")
        refresh()
    }

    static func discover(customFolders: [String]) -> [LocalModel] {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        var out: [LocalModel] = []
        var seen = Set<String>()

        func add(dir: String, name: String, source: String) {
            guard !seen.contains(dir), let files = try? fm.contentsOfDirectory(atPath: dir) else { return }
            let gguf = files.filter { $0.lowercased().hasSuffix(".gguf") }
            let hasWeights = files.contains { $0.hasSuffix(".safetensors") }
            let hasConfig = files.contains("config.json")
            if hasConfig && hasWeights {
                var modelType = ""
                var quantized = false
                if let data = fm.contents(atPath: dir + "/config.json"),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    modelType = json["model_type"] as? String ?? ""
                    quantized = json["quantization"] != nil || json["quantization_config"] != nil
                }
                let isMLX = quantized && (dir.lowercased().contains("mlx") || source == "LM Studio") || dir.lowercased().contains("mlx")
                seen.insert(dir)
                out.append(LocalModel(name: name, path: dir, format: isMLX ? "MLX" : "Safetensors", modelType: modelType,
                                      sizeBytes: folderSize(dir), source: source))
            } else if !gguf.isEmpty {
                for g in gguf where !g.lowercased().contains("mmproj") {
                    let p = dir + "/" + g
                    seen.insert(p)
                    out.append(LocalModel(name: name + " · " + g, path: p, format: "GGUF", modelType: "",
                                          sizeBytes: fileSize(p), source: source))
                }
            }
        }

        func walk(_ root: String, depth: Int, source: String) {
            guard depth >= 0, let items = try? fm.contentsOfDirectory(atPath: root) else { return }
            if items.contains("config.json") || items.contains(where: { $0.hasSuffix(".gguf") }) {
                let name = root.replacingOccurrences(of: home + "/.lmstudio/models/", with: "")
                add(dir: root, name: name, source: source)
                return
            }
            for i in items where !i.hasPrefix(".") {
                var isDir: ObjCBool = false
                let p = root + "/" + i
                if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { walk(p, depth: depth - 1, source: source) }
            }
        }

        walk(home + "/.lmstudio/models", depth: 3, source: "LM Studio")

        let hub = home + "/.cache/huggingface/hub"
        for repo in (try? fm.contentsOfDirectory(atPath: hub)) ?? [] where repo.hasPrefix("models--") {
            let name = repo.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
            let snaps = hub + "/" + repo + "/snapshots"
            for snap in (try? fm.contentsOfDirectory(atPath: snaps)) ?? [] {
                add(dir: snaps + "/" + snap, name: name, source: "Hugging Face")
            }
        }
        for folder in customFolders { walk(folder, depth: 3, source: "Custom") }
        return out.sorted { ($0.isChatCapable ? 0 : 1, $0.name) < ($1.isChatCapable ? 0 : 1, $1.name) }
    }

    static func fileSize(_ path: String) -> UInt64 {
        let resolved = (path as NSString).resolvingSymlinksInPath
        return (try? FileManager.default.attributesOfItem(atPath: resolved)[.size] as? UInt64) ?? 0
    }

    static func folderSize(_ dir: String) -> UInt64 {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.reduce(0) { $0 + fileSize(dir + "/" + $1) }
    }

    // MARK: Server

    func startServer(model: LocalModel) {
        stopServer()
        guard engineInstalled else { serverState = .failed("MLX engine not installed"); return }
        var note: String?
        if !Self.portIsFree(port) {
            let taken = port
            guard let free = (port + 1...port + 100).first(where: Self.portIsFree) else {
                serverState = .failed("port \(port) is in use by another app"); return
            }
            port = free
            note = "Port \(taken) is already used by another app, so the server is using \(free). Update apps that point at the old port."
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.venvBin + "/mlx_lm.server")
        p.arguments = ["--model", model.path, "--host", exposeOnNetwork ? "0.0.0.0" : "127.0.0.1", "--port", String(port)]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HUB_OFFLINE"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.appendLog(text) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.serverProcess === proc else { return }
                self.serverState = proc.terminationStatus == 0 || proc.terminationReason == .uncaughtSignal
                    ? .stopped : .failed("exit code \(proc.terminationStatus) — see log")
                self.serverProcess = nil
                self.probeEndpoints()
            }
        }
        serverLog = (note.map { ["⚠︎ " + $0] } ?? []) + ["$ mlx_lm.server " + p.arguments!.joined(separator: " ")]
        do {
            try p.run()
            serverProcess = p
            serverModel = model
            serverState = .starting
            waitForServer()
        } catch {
            serverState = .failed(error.localizedDescription)
        }
    }

    func stopServer() {
        if let p = serverProcess, p.isRunning { p.terminate() }
        serverProcess = nil
        serverState = .stopped
    }

    private func appendLog(_ text: String) {
        serverLog.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        if serverLog.count > 800 { serverLog.removeFirst(serverLog.count - 800) }
    }

    private func waitForServer(attempt: Int = 0) {
        guard serverProcess?.isRunning == true else { return }
        Task {
            let ok = await Self.fetchModels(base: localBaseURL) != nil
            await MainActor.run {
                if ok {
                    self.serverState = .running
                    self.probeEndpoints()
                } else if attempt < 600 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.waitForServer(attempt: attempt + 1) }
                }
            }
        }
    }

    // MARK: Endpoints (built-in server, LM Studio, Ollama)

    func probeEndpoints() {
        let candidates: [(String, String)] = [
            ("Command Center (MLX)", localBaseURL),
            ("LM Studio", "http://127.0.0.1:1234/v1"),
            ("Ollama", "http://127.0.0.1:11434/v1"),
        ]
        Task {
            var acc: [Endpoint] = []
            for (name, base) in candidates {
                if let models = await Self.fetchModels(base: base) {
                    acc.append(Endpoint(name: name, baseURL: base, models: models))
                }
            }
            let found = acc
            await MainActor.run {
                self.endpoints = found
                if let cur = self.chatEndpoint, let updated = found.first(where: { $0.baseURL == cur.baseURL }) {
                    self.chatEndpoint = updated
                } else {
                    self.chatEndpoint = found.first
                }
                if let ep = self.chatEndpoint, !ep.models.contains(self.chatModel) {
                    self.chatModel = ep.models.first ?? ""
                }
            }
        }
    }

    /// True if nothing is listening on this TCP port (checks both loopback and all interfaces).
    static func portIsFree(_ port: Int) -> Bool {
        for any in [false, true] {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = any ? INADDR_ANY : inet_addr("127.0.0.1")
            let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            if rc != 0 { return false }
        }
        // An IPv6 listener (like Node's default) doesn't always block an IPv4 bind, so also try connecting.
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var a6 = sockaddr_in6()
        a6.sin6_family = sa_family_t(AF_INET6)
        a6.sin6_port = in_port_t(UInt16(port).bigEndian)
        a6.sin6_addr = in6addr_loopback
        let rc = withUnsafePointer(to: &a6) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        return rc != 0
    }

    static func fetchModels(base: String) async -> [String]? {
        guard let url = URL(string: base + "/models") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 1.5
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return nil }
        return list.compactMap { $0["id"] as? String }
    }

    // MARK: Chat

    func send(_ text: String) {
        guard let ep = chatEndpoint, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        messages.append(ChatMessage(role: "user", content: text))
        messages.append(ChatMessage(role: "assistant", content: ""))
        isGenerating = true
        chatError = nil
        var history: [[String: String]] = []
        if !systemPrompt.isEmpty { history.append(["role": "system", "content": systemPrompt]) }
        history += messages.dropLast().map { ["role": $0.role, "content": $0.content] }
        let body: [String: Any] = ["model": chatModel, "messages": history, "stream": true, "max_tokens": 4096]
        let base = ep.baseURL

        chatTask = Task {
            do {
                var req = URLRequest(url: URL(string: base + "/chat/completions")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                req.timeoutInterval = 600
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    throw NSError(domain: "chat", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(http.statusCode)"])
                }
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let d = payload.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let choice = (json["choices"] as? [[String: Any]])?.first,
                          let delta = choice["delta"] as? [String: Any] else { continue }
                    let piece = (delta["content"] as? String) ?? ""
                    let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String) ?? ""
                    if piece.isEmpty && reasoning.isEmpty { continue }
                    await MainActor.run {
                        guard let i = self.messages.indices.last else { return }
                        self.messages[i].content += reasoning.isEmpty ? piece : reasoning
                    }
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run { self.chatError = error.localizedDescription }
            }
            await MainActor.run { self.isGenerating = false }
        }
    }

    func stopGenerating() {
        chatTask?.cancel()
        isGenerating = false
    }

    func clearChat() {
        stopGenerating()
        messages = []
        chatError = nil
    }
}
