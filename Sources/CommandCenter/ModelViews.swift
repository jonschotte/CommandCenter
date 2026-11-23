import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Models & server

struct ModelsView: View {
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var store: SessionStore
    @State private var selectedPath: String = ""
    @State private var showLog = false

    var chatModels: [LocalModel] { models.models.filter { $0.isChatCapable } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !models.engineInstalled { engineCard }
                serverCard
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Models on this Mac").font(.headline)
                        if models.isScanning { ProgressView().controlSize(.small) }
                        Spacer()
                        Button { addFolder() } label: { Label("Add Folder…", systemImage: "folder.badge.plus") }
                        Button { models.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    }
                    VStack(spacing: 0) {
                        ForEach(models.models) { m in
                            ModelLine(model: m)
                            if m.id != models.models.last?.id { Divider() }
                        }
                    }
                    .card()
                    Text("Scanned: ~/.lmstudio/models, ~/.cache/huggingface/hub" + (models.customFolders.isEmpty ? "" : ", " + models.customFolders.map(abbreviatePath).joined(separator: ", ")))
                        .font(.caption).foregroundStyle(.secondary)
                    if !models.customFolders.isEmpty {
                        HStack {
                            ForEach(models.customFolders, id: \.self) { f in
                                Button { models.removeFolder(f) } label: { Label(abbreviatePath(f), systemImage: "xmark.circle") }
                                    .buttonStyle(.borderless).font(.caption)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Models & Server")
        .onAppear {
            models.refresh()
            if selectedPath.isEmpty { selectedPath = models.serverModel?.path ?? chatModels.first?.path ?? "" }
        }
        .onChange(of: models.models) { _, _ in
            if selectedPath.isEmpty { selectedPath = chatModels.first?.path ?? "" }
        }
    }

    private var engineCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "bolt.horizontal.circle").font(.largeTitle).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Install the MLX engine").font(.headline)
                Text("Runs your MLX models on Apple Silicon. Installs uv, Python 3.12, and mlx-lm into ~/Library/Application Support/CommandCenter. The install runs in a terminal session so you can watch it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Install Engine") {
                store.launch(LaunchSpec(name: "Install MLX engine", directory: ModelManager.appSupport, kind: .custom,
                                        model: "", modelLabel: "installer", command: ModelManager.installCommand))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16).card()
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Model server").font(.headline)
                Circle().fill(stateColor).frame(width: 8, height: 8)
                Text(models.serverState.label).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(showLog ? "Hide Log" : "Show Log") { showLog.toggle() }.buttonStyle(.borderless)
            }
            HStack {
                Picker("Model", selection: $selectedPath) {
                    ForEach(chatModels) { m in Text("\(m.name)  ·  \(formatBytes(m.sizeBytes))").tag(m.path) }
                }
                .frame(maxWidth: 480)
                TextField("Port", value: $models.port, format: .number.grouping(.never))
                    .frame(width: 70).textFieldStyle(.roundedBorder)
                Toggle("Allow other devices on my network", isOn: $models.exposeOnNetwork).toggleStyle(.checkbox)
                Spacer()
                if models.serverProcess != nil {
                    Button("Stop", role: .destructive) { models.stopServer() }
                } else {
                    Button("Start Server") {
                        if let m = chatModels.first(where: { $0.path == selectedPath }) { models.startServer(model: m) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!models.engineInstalled || selectedPath.isEmpty)
                }
            }
            if models.serverState == .running {
                HStack {
                    Text("OpenAI-compatible API at").foregroundStyle(.secondary)
                    Text(models.localBaseURL).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button { copy(models.localBaseURL) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                }
                .font(.callout)
            }
            if showLog {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(models.serverLog.enumerated()), id: \.offset) { i, line in
                                Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .frame(height: 180)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.85)))
                    .foregroundStyle(.white.opacity(0.85))
                    .onChange(of: models.serverLog.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
        }
        .padding(16).card()
    }

    private var stateColor: Color {
        switch models.serverState {
        case .running: return .green
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .gray
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Add"
        if panel.runModal() == .OK, let url = panel.url { models.addFolder(url.path) }
    }
}

struct ModelLine: View {
    @EnvironmentObject var models: ModelManager
    let model: LocalModel
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.isChatCapable ? "cube.box" : "waveform").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).lineLimit(1)
                HStack(spacing: 6) {
                    Tag(model.format)
                    if !model.modelType.isEmpty { Tag(model.modelType) }
                    Tag(model.source)
                    if !model.isChatCapable { Text(model.format == "GGUF" ? "needs LM Studio or Ollama" : "not a chat model").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            if models.serverModel?.path == model.path && models.serverProcess != nil {
                Text("Serving").font(.caption).foregroundStyle(.green)
            }
            Text(formatBytes(model.sizeBytes)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Button { reveal(model.path) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Reveal in Finder")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct Tag: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(.quaternary))
    }
}

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

// MARK: - Chat

struct ChatView: View {
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var store: SessionStore
    @State private var input = ""
    @State private var showSystem = false
    @State private var attachments: [Data] = []   // JPEG, ready to send
    @State private var pasteMonitor: Any?
    @State private var dropTargeted = false
    @StateObject private var summarizer = Summarizer()
    @State private var showSummary = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if models.endpoints.isEmpty {
                    Label("No local model server running.", systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    Button("Start one") { store.selection = .models }
                } else {
                    Picker("Server", selection: Binding(get: { models.chatEndpoint?.baseURL ?? "" }, set: { url in
                        models.chatEndpoint = models.endpoints.first { $0.baseURL == url }
                        models.chatModel = models.chatEndpoint?.models.first ?? ""
                    })) {
                        ForEach(models.endpoints) { Text($0.name).tag($0.baseURL) }
                    }
                    .frame(maxWidth: 260)
                    Picker("Model", selection: $models.chatModel) {
                        ForEach(models.chatEndpoint?.models ?? [], id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) }
                    }
                    .frame(maxWidth: 360)
                }
                Spacer()
                Button { models.probeEndpoints() } label: { Image(systemName: "arrow.clockwise") }.help("Re-detect servers")
                Button { summarize() } label: { Image(systemName: "list.bullet.clipboard") }
                    .help("Summarize this chat (uses the selected local model, so it stays on this Mac)")
                    .disabled(models.messages.isEmpty || models.chatEndpoint == nil)
                Button { showSystem.toggle() } label: { Image(systemName: "text.badge.star") }.help("System prompt")
                Button { models.clearChat() } label: { Image(systemName: "trash") }.help("Clear chat")
            }
            .buttonStyle(.borderless)
            .padding(12)
            if showSystem {
                TextField("System prompt (optional)", text: $models.systemPrompt, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.roundedBorder).padding([.horizontal, .bottom], 12)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if models.messages.isEmpty {
                            Text("Chat with any local model served by Command Center, LM Studio, or Ollama.")
                                .foregroundStyle(.secondary).padding(.top, 40).frame(maxWidth: .infinity)
                        }
                        ForEach(models.messages) { m in MessageBubble(message: m).id(m.id) }
                        if let e = models.chatError {
                            Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: models.messages.last?.content) { _, _ in
                    if let id = models.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            Divider()
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { i, data in
                            ZStack(alignment: .topTrailing) {
                                if let img = NSImage(data: data) {
                                    Image(nsImage: img).resizable().scaledToFill()
                                        .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                Button { attachments.remove(at: i) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain).padding(3)
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.top, 10)
                }
            }
            HStack(alignment: .bottom) {
                Button { chooseImages() } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.borderless)
                    .help("Attach images (you can also paste with ⌘V or drop them here). Needs a vision model.")
                    .padding(.bottom, 8)
                TextField(attachments.isEmpty ? "Message…" : "Ask about the image…", text: $input, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .onSubmit(send)
                if models.isGenerating {
                    Button("Stop") { models.stopGenerating() }
                } else {
                    Button("Send", action: send).keyboardShortcut(.return, modifiers: .command)
                        .disabled(models.chatEndpoint == nil || (input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty))
                }
            }
            .padding(12)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .background(Theme.accent.opacity(0.06)).padding(6).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            handleDrop(providers); return true
        }
        .onAppear(perform: installPasteMonitor)
        .onDisappear {
            if let m = pasteMonitor { NSEvent.removeMonitor(m); pasteMonitor = nil }
        }
        .sheet(isPresented: $showSummary) { SummarySheet(summarizer: summarizer, regenerate: summarize) }
        .navigationTitle("Chat")
    }

    private func send() {
        guard !models.isGenerating else { return }
        let t = input, imgs = attachments
        guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imgs.isEmpty else { return }
        input = ""
        attachments = []
        models.send(t, images: imgs)
    }

    private func summarize() {
        guard let ep = models.chatEndpoint else { return }
        summarizer.runLocal(base: ep.baseURL, model: models.chatModel, text: models.chatTranscript, source: "Chat")
        showSummary = true
    }

    private func attach(_ data: Data) {
        if let jpeg = ImageAttach.jpegForModel(data) { attachments.append(jpeg) }
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { if let d = try? Data(contentsOf: url) { attach(d) } }
    }

    /// ⌘V with an image on the clipboard attaches it; text pastes normally.
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  store.selection == .chat, NSApp.keyWindow?.attachedSheet == nil else { return event }
            let pb = NSPasteboard.general
            let imageFiles = ImageAttach.fileURLs(pb).filter { ImageAttach.imageExtensions.contains($0.pathExtension.lowercased()) }
            if !imageFiles.isEmpty {
                for u in imageFiles { if let d = try? Data(contentsOf: u) { attach(d) } }
                return nil
            }
            if pb.string(forType: .string) == nil, let png = ImageAttach.imagePNG(pb) {
                attach(png); return nil
            }
            return event
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, ImageAttach.imageExtensions.contains(url.pathExtension.lowercased()),
                          let d = try? Data(contentsOf: url) else { return }
                    DispatchQueue.main.async { attach(d) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { d, _ in
                    guard let d else { return }
                    DispatchQueue.main.async { attach(d) }
                }
            }
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.role == "user" ? "person.circle.fill" : "cpu")
                .font(.title3).foregroundStyle(message.role == "user" ? Theme.accent : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(message.role == "user" ? "You" : "Model").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if !message.images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(message.images.enumerated()), id: \.offset) { _, d in
                            if let img = NSImage(data: d) {
                                Image(nsImage: img).resizable().scaledToFit()
                                    .frame(maxWidth: 180, maxHeight: 140).clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                if !message.content.isEmpty || message.images.isEmpty {
                    Text(message.content.isEmpty ? "…" : message.content).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - API access

struct APIView: View {
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var store: SessionStore

    var body: some View {
        let host = models.exposeOnNetwork ? (models.lanAddress ?? "127.0.0.1") : "127.0.0.1"
        let base = "http://\(host):\(models.port)/v1"
        let modelID = models.serverModel?.path ?? "<model>"
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Your apps can use local models through an OpenAI-compatible API. Any OpenAI client library works. Point it at the base URL below.")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Endpoints detected").font(.headline)
                    if models.endpoints.isEmpty {
                        HStack {
                            Text("Nothing running yet.").foregroundStyle(.secondary)
                            Button("Start the model server") { store.selection = .models }
                        }
                    }
                    ForEach(models.endpoints) { ep in
                        HStack {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text(ep.name).frame(width: 180, alignment: .leading)
                            Text(ep.baseURL).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Button { copy(ep.baseURL) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                            Spacer()
                            Text("\(ep.models.count) model(s)").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16).card()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Network access").font(.headline)
                    Toggle("Allow other devices on my network (applies the next time the server starts)", isOn: $models.exposeOnNetwork)
                    if models.exposeOnNetwork {
                        Label("No API key protects the server. Anyone on your network can use it. Turn this on only for trusted networks.",
                              systemImage: "exclamationmark.shield").foregroundStyle(.orange).font(.callout)
                    }
                }
                .padding(16).card()

                CodeBlock(title: "curl", code: """
                curl \(base)/chat/completions \\
                  -H "Content-Type: application/json" \\
                  -d '{"model": "\(modelID)", "messages": [{"role": "user", "content": "Hello!"}]}'
                """)
                CodeBlock(title: "Python (openai)", code: """
                from openai import OpenAI

                client = OpenAI(base_url="\(base)", api_key="not-needed")
                resp = client.chat.completions.create(
                    model="\(modelID)",
                    messages=[{"role": "user", "content": "Hello!"}],
                )
                print(resp.choices[0].message.content)
                """)
                CodeBlock(title: "JavaScript (openai)", code: """
                import OpenAI from "openai";

                const client = new OpenAI({ baseURL: "\(base)", apiKey: "not-needed" });
                const resp = await client.chat.completions.create({
                  model: "\(modelID)",
                  messages: [{ role: "user", content: "Hello!" }],
                });
                console.log(resp.choices[0].message.content);
                """)
            }
            .padding(20)
        }
        .navigationTitle("API Access")
    }
}

struct CodeBlock: View {
    let title: String
    let code: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button { copy(code) } label: { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(.borderless)
            }
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        }
        .padding(16).card()
    }
}
