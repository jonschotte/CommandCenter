import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SwiftTerm

// MARK: - Images: saving pasted/dropped images, encoding them for chat

enum ImageAttach {
    static let pasteDir: String = {
        let d = CCPaths.stateDir + "/pastes"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }()

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp"]

    /// File URLs on a pasteboard (Finder copy or drag).
    static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Raw image data on a pasteboard (screenshot to clipboard, "Copy Image"), as PNG.
    static func imagePNG(_ pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }

    /// Writes image data to ~/.commandcenter/pastes and returns the path.
    static func save(_ png: Data) -> String? {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let path = pasteDir + "/paste-\(f.string(from: Date())).png"
        do { try png.write(to: URL(fileURLWithPath: path)); return path } catch { return nil }
    }

    /// Path escaped the way Terminal.app does when you drop a file (backslash before special characters).
    static func shellEscaped(_ path: String) -> String {
        var out = ""
        for ch in path {
            if " \\'\"()[]{}&;|<>*?$`!#~".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Image paths from a pasteboard: image files first, otherwise raw image data saved to a file.
    static func imagePaths(_ pb: NSPasteboard, includeAllFiles: Bool) -> [String] {
        let urls = fileURLs(pb)
        if !urls.isEmpty {
            return urls.filter { includeAllFiles || imageExtensions.contains($0.pathExtension.lowercased()) }.map(\.path)
        }
        if let png = imagePNG(pb), let p = save(png) { return [p] }
        return []
    }

    /// Downscales to at most 1568 px on the long side and encodes as JPEG, for sending to a model.
    static func jpegForModel(_ data: Data) -> Data? {
        guard let img = NSImage(data: data), let src = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let maxSide: CGFloat = 1568
        let w = CGFloat(src.width), h = CGFloat(src.height)
        let scale = min(1, maxSide / max(w, h))
        let nw = Int(w * scale), nh = Int(h * scale)
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: nw, height: nh))
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}

// MARK: - Transcripts

enum Transcript {
    /// Finds ~/.claude/projects/*/<sessionId>.jsonl for a running Claude process.
    static func claudeFile(pid: pid_t) -> String? {
        guard let id = SessionStore.claudeSessionID(pid: pid) else { return nil }
        let root = NSHomeDirectory() + "/.claude/projects"
        for dir in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            let p = root + "/" + dir + "/" + id + ".jsonl"
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    /// The conversation as plain text: what you asked, what Claude said, and a one-line note per tool call.
    static func claudeText(pid: pid_t) -> String? {
        guard let path = claudeFile(pid: pid), let data = FileManager.default.contents(atPath: path),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        var out: [String] = []
        for line in raw.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  let msg = obj["message"] as? [String: Any] else { continue }
            if obj["isMeta"] as? Bool == true { continue }
            if let s = msg["content"] as? String {
                if s.hasPrefix("<") && (s.contains("<command-") || s.contains("<local-command")) { continue }
                out.append((type == "user" ? "USER: " : "CLAUDE: ") + s)
            } else if let parts = msg["content"] as? [[String: Any]] {
                for p in parts {
                    switch p["type"] as? String {
                    case "text":
                        if let t = p["text"] as? String, !t.isEmpty { out.append((type == "user" ? "USER: " : "CLAUDE: ") + t) }
                    case "image":
                        if type == "user" { out.append("USER: [attached an image]") }
                    case "tool_use":
                        let name = p["name"] as? String ?? "tool"
                        let input = p["input"] as? [String: Any] ?? [:]
                        let detail = (input["description"] ?? input["command"] ?? input["file_path"] ?? input["pattern"] ?? input["prompt"]) as? String ?? ""
                        out.append("  [\(name)] " + String(detail.replacingOccurrences(of: "\n", with: " ").prefix(160)))
                    default: break
                    }
                }
            }
        }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }

    /// Everything in a terminal's scrollback, with blank runs collapsed.
    static func terminalText(_ tv: TerminalView) -> String {
        let data = tv.getTerminal().getBufferAsData(kind: .normal)
        let s = String(data: data, encoding: .utf8) ?? ""
        var lines: [Substring] = []
        for l in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty, lines.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { continue }
            lines.append(l)
        }
        return lines.joined(separator: "\n")
    }

    /// Keeps the start and the (more important) end when a transcript is too long.
    static func clip(_ s: String, max: Int = 150_000) -> String {
        guard s.count > max else { return s }
        let head = s.prefix(max / 5), tail = s.suffix(max - max / 5)
        return head + "\n\n[… middle of the conversation omitted for length …]\n\n" + tail
    }
}

// MARK: - Summarizer (runs `claude -p`)

@MainActor
final class Summarizer: ObservableObject {
    enum State: Equatable { case idle, working, done(String), failed(String) }
    @Published var state: State = .idle
    @Published var source = ""
    @Published var engine = "Claude"
    private var process: Process?
    private var task: Task<Void, Never>?

    static let prompt = """
    Below is a transcript of a work session (a chat with an AI assistant or a terminal). Summarize it for the person who \
    did the work so they can remember what happened. Use Markdown with these sections:
    **Goal**: one or two sentences.
    **What got done**: bullets, concrete (files, commands, decisions, results).
    **Open items / next steps**: bullets, or "None".
    **Key details to remember**: names, paths, numbers, gotchas. Skip if nothing notable.
    Be concise and only state what the transcript supports. Don't invent anything.
    """

    func run(text: String, source: String) {
        cancel()
        self.source = source
        engine = "Claude"
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed("There's nothing to summarize yet."); return
        }
        state = .working
        let input = Self.prompt + "\n\n<transcript>\n" + Transcript.clip(text) + "\n</transcript>"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // A login shell so `claude` is found on the user's PATH; no tools, no saved session, quick model.
        p.arguments = ["-lc", "exec claude -p --model haiku --no-session-persistence --tools ''"]
        p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CC_SESSION_ID")
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        process = p
        do { try p.run() } catch { state = .failed("Couldn't start claude: \(error.localizedDescription)"); return }
        let payload = Data(input.utf8)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            inPipe.fileHandleForWriting.write(payload)
            try? inPipe.fileHandleForWriting.close()
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let o = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let e = String(data: err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status = p.terminationStatus, reason = p.terminationReason
            Task { @MainActor in
                guard let self, self.process === p else { return }
                self.process = nil
                if reason == .uncaughtSignal { self.state = .idle; return }
                if status == 0 && !o.isEmpty { self.state = .done(o) }
                else { self.state = .failed(e.isEmpty ? (o.isEmpty ? "claude exited with status \(status)." : o) : e) }
            }
        }
    }

    /// Summarizes with a local OpenAI-compatible server instead, so a local chat stays on this Mac.
    func runLocal(base: String, model: String, text: String, source: String) {
        cancel()
        self.source = source
        engine = (model as NSString).lastPathComponent
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed("There's nothing to summarize yet."); return
        }
        state = .working
        let body: [String: Any] = ["model": model, "stream": false, "max_tokens": 1500, "messages": [
            ["role": "system", "content": Self.prompt],
            ["role": "user", "content": "<transcript>\n" + Transcript.clip(text, max: 40_000) + "\n</transcript>"],
        ]]
        task = Task { [weak self] in
            do {
                var req = URLRequest(url: URL(string: base + "/chat/completions")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                req.timeoutInterval = 600
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    throw NSError(domain: "summary", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(http.statusCode)"])
                }
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let msg = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
                var out = (msg?["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                // Reasoning models: drop the <think> block.
                if let r = out.range(of: "</think>") { out = String(out[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
                guard !Task.isCancelled else { return }
                self?.state = out.isEmpty ? .failed("The model returned an empty summary.") : .done(out)
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self?.state = .failed(error.localizedDescription) }
            }
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
        task?.cancel()
        task = nil
        state = .idle
    }
}

struct SummarySheet: View {
    @ObservedObject var summarizer: Summarizer
    var regenerate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "list.bullet.clipboard").foregroundStyle(Theme.accent)
                Text("Summary").font(.title3.weight(.semibold))
                if !summarizer.source.isEmpty {
                    Text(summarizer.source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            Divider()
            Group {
                switch summarizer.state {
                case .idle, .working:
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Summarizing with \(summarizer.engine)…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .done(let text):
                    ScrollView {
                        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .failed(let msg):
                    Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(minHeight: 260)
            HStack {
                if case .done(let text) = summarizer.state {
                    Button { copyToClipboard(text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
                Button { regenerate() } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                    .disabled(summarizer.state == .working)
                Spacer()
                Button("Close") { summarizer.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 620, height: 520)
    }
}

func copyToClipboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

/// Header button that opens a summary of a Claude conversation (by pid) or, failing that, the terminal text.
struct SummarizeButton: View {
    var label: String
    var claudePid: () -> pid_t?
    var terminalText: () -> String?
    @StateObject private var summarizer = Summarizer()
    @State private var showing = false

    var body: some View {
        Button { start(); showing = true } label: { Image(systemName: "list.bullet.clipboard") }
            .help("Summarize this session")
            .sheet(isPresented: $showing) { SummarySheet(summarizer: summarizer, regenerate: start) }
    }

    private func start() {
        if let pid = claudePid(), let t = Transcript.claudeText(pid: pid) {
            summarizer.run(text: t, source: "\(label) · full Claude conversation")
        } else {
            summarizer.run(text: terminalText() ?? "", source: "\(label) · terminal output")
        }
    }
}
