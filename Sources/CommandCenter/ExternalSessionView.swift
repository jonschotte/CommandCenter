import SwiftUI
import AppKit

/// Live mirror + remote control of an agent running in Terminal.app or iTerm2.
struct ExternalSessionView: View {
    @EnvironmentObject var scanner: ProcessScanner
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var events: AgentEvents
    let pid: pid_t

    @State private var text = ""
    @State private var input = ""
    @State private var confirmMove: DetectedAgent?
    @State private var error: String?
    @State private var lastChange = Date.distantPast
    @State private var followTail = true
    @FocusState private var inputFocused: Bool

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var agent: DetectedAgent? { scanner.agents.first { $0.pid == pid } }

    var body: some View {
        if let agent {
            content(agent)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "moon.zzz").font(.largeTitle).foregroundStyle(.secondary)
                Text("This session has ended.").font(.headline)
                Button("Back to Dashboard") { store.selection = .dashboard }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func content(_ agent: DetectedAgent) -> some View {
        let host = TerminalBridge.host(for: agent.host)
        VStack(spacing: 0) {
            header(agent, host: host)
            Divider()
            if let host, agent.tty != "??" {
                mirror
                    .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.orange.opacity(0.08))
                }
                Divider()
                controls(agent, host: host)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Command Center can't mirror or type into sessions running in \(agent.host).")
                        .font(.headline)
                    Text("Only Terminal.app and iTerm2 allow remote control. To get a full terminal, move this session into Command Center.")
                        .foregroundStyle(.secondary)
                    Button("Move Here…") { confirmMove = agent }.buttonStyle(.borderedProminent)
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onReceive(poll) { _ in refresh(agent, host: host) }
        .onAppear { refresh(agent, host: host); inputFocused = true }
        .onChange(of: pid) { _, _ in text = ""; error = nil; refresh(agent, host: host) }
        .navigationTitle("\(agent.name) · \((agent.cwd as NSString).lastPathComponent)")
        .moveHereDialog(agent: $confirmMove)
    }

    private func header(_ agent: DetectedAgent, host: TerminalBridge.Host?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text((agent.cwd as NSString).lastPathComponent.isEmpty ? agent.name : (agent.cwd as NSString).lastPathComponent)
                        .font(.headline)
                    StatusPill(activity: events.external[agent.pid] != nil ? externalActivity(agent, events: events)
                               : (Date().timeIntervalSince(lastChange) < 2.5 ? .working : .idle))
                    Tag("\(agent.host) · \(agent.tty)")
                }
                Text(agent.args).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            StatText(label: "Up", value: formatDuration(agent.elapsed))
            StatText(label: "CPU", value: String(format: "%.0f%%", agent.cpu))
            StatText(label: "RAM", value: formatBytes(agent.rssBytes))
            Divider().frame(height: 28)
            Button { confirmMove = agent } label: { Label("Move Here", systemImage: "arrow.down.right.and.arrow.up.left.square") }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .help("Run this as a full terminal inside Command Center")
            if let host {
                Button { TerminalBridge.focus(host, tty: agent.tty) } label: { Image(systemName: "macwindow") }
                    .help("Show this tab in \(agent.host)")
            }
            SummarizeButton(label: (agent.cwd as NSString).lastPathComponent,
                            claudePid: { agent.name == "claude" ? agent.pid : nil },
                            terminalText: { text })
            Button { reveal(agent.cwd) } label: { Image(systemName: "folder") }.help("Reveal folder in Finder")
            Button { store.requestExternalClose(agent) } label: { Image(systemName: "xmark") }
                .help(host != nil ? "Stop and close this \(agent.host) tab" : "Stop this agent")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var mirror: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                Text(text.isEmpty ? "Connecting…" : text)
                    .font(Font(TerminalProfile.current.font))
                    .foregroundStyle(Color(nsColor: TerminalProfile.current.foreground))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)   // wrap long lines to the window width
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                Color.clear.frame(height: 1).id("bottom")
            }
            .background(Color(nsColor: TerminalProfile.current.background))
            .onChange(of: text) { _, _ in if followTail { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func controls(_ agent: DetectedAgent, host: TerminalBridge.Host) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom) {
                TextField("Type to \(agent.name) in \(agent.host)… (Return sends)", text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .focused($inputFocused)
                    .onSubmit { send(agent, host: host) }
                Button("Send") { send(agent, host: host) }.keyboardShortcut(.return, modifiers: .command)
            }
            HStack(spacing: 6) {
                ForEach(TerminalBridge.SpecialKey.allCases) { k in
                    Button(k.rawValue) {
                        TerminalBridge.sendKey(host, tty: agent.tty, key: k) { handle($0) }
                    }
                    .help(k.help)
                    .controlSize(.small)
                }
                Spacer()
                Toggle("Follow output", isOn: $followTail).toggleStyle(.checkbox).controlSize(.small)
            }
        }
        .padding(12)
    }

    private func refresh(_ agent: DetectedAgent, host: TerminalBridge.Host?) {
        guard let host, agent.tty != "??" else { return }
        TerminalBridge.snapshot(host, tty: agent.tty) { r in
            switch r {
            case .success(let s):
                let trimmed = Self.tail(s, lines: 3000)
                if trimmed != text { text = trimmed; lastChange = Date() }
                if error?.contains("Accessibility") != true { error = nil }
            case .failure(let e):
                error = e.message
            }
        }
    }

    private func send(_ agent: DetectedAgent, host: TerminalBridge.Host) {
        let t = input
        guard !t.isEmpty else { return }
        input = ""
        TerminalBridge.send(host, tty: agent.tty, text: t) { r in
            handle(r)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refresh(agent, host: host) }
        }
    }

    private func handle(_ r: Result<String, BridgeError>) {
        if case .failure(let e) = r { error = e.message } else { error = nil }
    }

    static func tail(_ s: String, lines: Int) -> String {
        var trimmed = s
        while trimmed.hasSuffix("\n") { trimmed.removeLast() }
        let parts = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        return parts.count > lines ? parts.suffix(lines).joined(separator: "\n") : trimmed
    }
}

/// "Move Here": reopen an outside session as a full terminal in Command Center.
struct MoveHereDialog: ViewModifier {
    @EnvironmentObject var store: SessionStore
    @Binding var agent: DetectedAgent?
    func body(content: Content) -> some View {
        content.confirmationDialog("Move this session into Command Center?",
                                   isPresented: Binding(get: { agent != nil }, set: { if !$0 { agent = nil } })) {
            if let a = agent {
                Button(TerminalBridge.host(for: a.host) != nil ? "Move Here & Close \(a.host) Tab" : "Move Here & Stop Original") {
                    store.moveHere(a, closeOriginal: true); agent = nil
                }
                Button("Open a Copy Here, Keep Original") { store.moveHere(a, closeOriginal: false); agent = nil }
            }
        } message: {
            if let a = agent {
                Text(a.name == "claude"
                     ? "Reopens the same Claude conversation (\(abbreviatePath(a.cwd))) in a full terminal here. Anything Claude is doing right now is interrupted; the conversation history is kept."
                     : "Starts \(a.name) again in \(abbreviatePath(a.cwd)) in a full terminal here.")
            }
        }
    }
}

extension View {
    func moveHereDialog(agent: Binding<DetectedAgent?>) -> some View { modifier(MoveHereDialog(agent: agent)) }
}
