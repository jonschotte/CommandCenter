import SwiftUI
import AppKit

enum SidebarItem: Hashable {
    case dashboard, session(UUID), external(Int32), chief(String), agents, system, memory, models, chat, api
}

struct ContentView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var scanner: ProcessScanner
    @EnvironmentObject var system: SystemMonitor
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var events: AgentEvents
    @ObservedObject var groups = GroupStore.shared
    @ObservedObject var chief = ChiefHostLink.shared
    @State private var moveAgent: DetectedAgent?

    @ViewBuilder private func sessionRow(_ s: Session) -> some View {
        SessionRow(session: s).tag(SidebarItem.session(s.id))
            .draggable(GroupKey.of(s))
            .contextMenu {
                Button("Restart") { store.restart(s) }
                Button("Reveal in Finder") { reveal(s.currentDirectory) }
                GroupMenu(key: GroupKey.of(s))
                Divider()
                Button("Close Session…", role: .destructive) { store.requestClose(s) }
            }
    }

    @ViewBuilder private func externalRow(_ a: DetectedAgent) -> some View {
        ExternalRow(agent: a).tag(SidebarItem.external(a.pid))
            .draggable(GroupKey.of(a))
            .contextMenu {
                Button("Move Here…") { moveAgent = a }
                if let h = TerminalBridge.host(for: a.host) {
                    Button("Show in \(a.host)") { TerminalBridge.focus(h, tty: a.tty) }
                }
                Button("Reveal Folder in Finder") { reveal(a.cwd) }
                GroupMenu(key: GroupKey.of(a))
                Divider()
                Button(TerminalBridge.host(for: a.host) != nil ? "Close Terminal Tab…" : "Stop Agent…", role: .destructive) {
                    store.requestExternalClose(a)
                }
            }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
            List(selection: $store.selection) {
                Section {
                    Label("Dashboard", systemImage: "square.grid.2x2").tag(SidebarItem.dashboard)
                }
                // ChiefHost's sessions get their own section (with a real terminal), not "Other Terminals".
                let external = scanner.agents.filter { !$0.inApp && $0.category == .agent && $0.host != "ChiefHost" }
                Section {
                    ForEach(store.sessions.filter { groups.group(for: GroupKey.of($0)) == nil }) { s in sessionRow(s) }
                    HStack(spacing: 14) {
                        Button { store.showNewSession = true } label: { Label("Session", systemImage: "plus.circle.fill") }
                            .help("New session with Claude, a local model, or a command (⌘T)")
                        Button { store.newTerminal() } label: { Label("Terminal", systemImage: "terminal.fill") }
                            .help("Open a shell right away (⇧⌘T)")
                        Button { groups.namingNewGroupFor = .some(nil) } label: { Label("Group", systemImage: "folder.badge.plus") }
                            .help("New group")
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                } header: {
                    Text("Sessions")
                        .dropDestination(for: String.self) { keys, _ in
                            for k in keys { groups.assign(k, to: nil) }
                            return true
                        }
                }
                ForEach(groups.groups) { g in
                    let inGroup = store.sessions.filter { groups.assignments[GroupKey.of($0)] == g.id }
                    let extInGroup = external.filter { groups.assignments[GroupKey.of($0)] == g.id }
                    Section(isExpanded: groups.binding(expanded: g)) {
                        ForEach(inGroup) { s in sessionRow(s) }
                        ForEach(extInGroup) { a in externalRow(a) }
                        if inGroup.isEmpty && extInGroup.isEmpty {
                            Text("Drag terminals here").font(.caption).foregroundStyle(.tertiary)
                                .dropDestination(for: String.self) { keys, _ in
                                    for k in keys { groups.assign(k, to: g) }
                                    return true
                                }
                        }
                    } header: {
                        GroupHeader(group: g, count: inGroup.count + extInGroup.count,
                                    busy: inGroup.filter { $0.activity == .working }.count + extInGroup.filter { externalActivity($0, events: events) == .working }.count,
                                    attention: inGroup.filter { $0.needsAttention }.count)
                    }
                }
                if chief.connected || !chief.sessions.isEmpty {
                    Section {
                        ForEach(chief.sessions) { c in
                            ChiefSessionRow(info: c).tag(SidebarItem.chief(c.id))
                                .contextMenu {
                                    Button("Restart (resume)") { chief.perform("session.restart", id: c.id) }
                                    Button("Stop") { chief.perform("session.stop", id: c.id) }
                                    Button("Reveal in Finder") { reveal(c.cwd) }
                                }
                        }
                        if chief.sessions.isEmpty {
                            Text("No Chief sessions running").font(.caption).foregroundStyle(.tertiary)
                        }
                    } header: {
                        HStack {
                            Text("Chief")
                            Spacer()
                            let attention = chief.sessions.filter { $0.status == "blocked" }.count
                            if attention > 0 { CountBadge(count: attention) }
                        }
                    }
                }
                let ungroupedExternal = external.filter { groups.group(for: GroupKey.of($0)) == nil }
                if !ungroupedExternal.isEmpty {
                    Section("Other Terminals") {
                        ForEach(ungroupedExternal) { a in externalRow(a) }
                    }
                }
                Section("Monitor") {
                    HStack {
                        Label("All Running Agents", systemImage: "dot.radiowaves.left.and.right")
                        Spacer()
                        CountBadge(count: scanner.agents.filter { !$0.inApp }.count)
                    }.tag(SidebarItem.agents)
                    Label("System", systemImage: "gauge.with.dots.needle.67percent").tag(SidebarItem.system)
                    Label("Memory", systemImage: "memorychip").tag(SidebarItem.memory)
                }
                Section("Local Models") {
                    Label("Models & Server", systemImage: "shippingbox").tag(SidebarItem.models)
                    Label("Chat", systemImage: "bubble.left.and.bubble.right").tag(SidebarItem.chat)
                    Label("API Access", systemImage: "network").tag(SidebarItem.api)
                }
            }
            .listStyle(.sidebar)
            Divider()
            SidebarStats()
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            detail
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .confirmationDialog("Close “\(store.pendingClose?.name ?? "")”?",
                            isPresented: Binding(get: { store.pendingClose != nil }, set: { if !$0 { store.pendingClose = nil } })) {
            Button("Stop & Close", role: .destructive) {
                if let s = store.pendingClose { store.close(s) }
                store.pendingClose = nil
            }
        } message: {
            Text("This session is still running. Closing it stops everything running in it.")
        }
        .confirmationDialog(externalCloseTitle,
                            isPresented: Binding(get: { store.pendingExternalClose != nil }, set: { if !$0 { store.pendingExternalClose = nil } })) {
            Button(TerminalBridge.host(for: store.pendingExternalClose?.host ?? "") != nil ? "Close Tab" : "Stop Agent", role: .destructive) {
                store.confirmExternalClose()
            }
        } message: {
            if let a = store.pendingExternalClose {
                Text("Stops \(a.name) (pid \(a.pid)) and anything else running in that tab, in \(abbreviatePath(a.cwd)). Unsaved work there may be lost.")
            }
        }
        .alert("Couldn't close the tab", isPresented: Binding(get: { store.closeError != nil }, set: { if !$0 { store.closeError = nil } })) {
            Button("OK") { store.closeError = nil }
        } message: { Text(store.closeError ?? "") }
        .sheet(isPresented: $store.showNewSession) {
            NewSessionSheet(preset: store.newSessionPreset)
                .onDisappear { store.newSessionPreset = nil }
        }
        .moveHereDialog(agent: $moveAgent)
        .groupPrompts()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.newTerminal() } label: { Label("New Terminal", systemImage: "terminal") }
                    .help("New terminal (⇧⌘T)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.showNewSession = true } label: { Label("New Session", systemImage: "plus") }
                    .help("New session (⌘T)")
            }
        }
        .onChange(of: store.selection) { _, sel in
            if case .session(let id) = sel { store.session(id)?.needsAttention = false }
            if sel == .chat || sel == .api || sel == .models { models.probeEndpoints() }
        }
    }

    private var externalCloseTitle: String {
        guard let a = store.pendingExternalClose else { return "" }
        return TerminalBridge.host(for: a.host) != nil ? "Close this \(a.host) tab?" : "Stop \(a.name)?"
    }

    @ViewBuilder private var detail: some View {
        switch store.selection {
        case .session(let id):
            if let s = store.session(id) { SessionDetailView(session: s) } else { DashboardView() }
        case .external(let pid): ExternalSessionView(pid: pid).id(pid)
        case .chief(let id): ChiefSessionView(id: id).id(id)
        case .agents: AgentsView()
        case .system: SystemView()
        case .memory: MemoryView()
        case .models: ModelsView()
        case .chat: ChatView()
        case .api: APIView()
        default: DashboardView()
        }
    }
}

/// Status of an outside agent: from Claude Code hooks if available, else guessed from CPU use.
func externalActivity(_ agent: DetectedAgent, events: AgentEvents) -> SessionActivity {
    if let (st, _) = events.external[agent.pid] {
        switch st {
        case .working: return .working
        case .needsPermission: return .needsYou
        case .waiting, .done: return .yourTurn
        case .ended: break
        }
    }
    return agent.cpu > 3 ? .working : .idle
}

struct ExternalRow: View {
    @EnvironmentObject var events: AgentEvents
    @ObservedObject private var groups = GroupStore.shared
    let agent: DetectedAgent
    var body: some View {
        HStack(spacing: 8) {
            IconBadge(symbol: "sparkles", color: Theme.identity(GroupKey.of(agent)), size: 22)
                .overlay(alignment: .bottomTrailing) {
                    ActivityDot(activity: externalActivity(agent, events: events), size: 7)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 10, height: 10))
                        .offset(x: 3, y: 3)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text((agent.cwd as NSString).lastPathComponent.isEmpty ? agent.name : (agent.cwd as NSString).lastPathComponent)
                    .lineLimit(1)
                Text("\(agent.name) · \(agent.host) · \(agent.tty)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if TerminalBridge.host(for: agent.host) == nil {
                Image(systemName: "eye").font(.caption).foregroundStyle(.tertiary).help("Monitor only")
            }
        }
        .padding(.vertical, 2)
    }
}

struct CountBadge: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text("\(count)").font(.caption2.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
        }
    }
}

struct SessionRow: View {
    @ObservedObject var session: Session
    @ObservedObject private var groups = GroupStore.shared
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 8) {
            IconBadge(symbol: session.spec.kind.symbol, color: Theme.identity(GroupKey.of(session)), size: 22)
                .overlay(alignment: .bottomTrailing) {
                    ActivityDot(activity: session.activity, size: 7)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 10, height: 10))
                        .offset(x: 3, y: 3)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name).lineLimit(1)
                Text(session.spec.modelLabel.isEmpty ? abbreviatePath(session.currentDirectory) : session.spec.modelLabel)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if hovering {
                Button { SessionStore.shared?.requestClose(session) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("Close session")
            }
            if session.needsAttention {
                Image(systemName: "bell.badge.fill").foregroundStyle(.orange).help("Finished work — waiting for you")
            }
        }
        .padding(.vertical, 2)
        .onHover { hovering = $0 }
    }
}

struct SidebarStats: View {
    @EnvironmentObject var system: SystemMonitor
    @EnvironmentObject var store: SessionStore
    var body: some View {
        VStack(spacing: 8) {
            MiniMeter(label: "CPU", color: Theme.cpu, value: system.cpuTotal, text: "\(Int(system.cpuTotal * 100))%")
                .contentShape(Rectangle()).onTapGesture { store.selection = .system }.help("Open System")
            MiniMeter(label: "RAM", color: Theme.memory, value: system.memFraction, text: "\(formatBytes(system.memUsed)) of \(formatBytes(system.memTotal))")
                .contentShape(Rectangle()).onTapGesture { store.selection = .memory }.help("See what's using memory")
            MiniMeter(label: "GPU", color: Theme.gpu, value: system.gpuUtil, text: "\(Int(system.gpuUtil * 100))%")
                .contentShape(Rectangle()).onTapGesture { store.selection = .system }.help("Open System")
        }
    }
}

struct MiniMeter: View {
    let label: String
    var color: Color = .accentColor
    let value: Double
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(text).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    let c = Theme.level(value, base: color)
                    Capsule().fill(LinearGradient(colors: [c.opacity(0.6), c], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(3, g.size.width * min(max(value, 0), 1)))
                        .shadow(color: c.opacity(0.6), radius: 2)
                }
            }
            .frame(height: 4)
        }
    }
}

func meterColor(_ v: Double) -> Color { v > 0.9 ? .red : v > 0.7 ? .orange : .accentColor }

func reveal(_ path: String) {
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
}

// MARK: - Session detail

struct SessionDetailView: View {
    @EnvironmentObject var store: SessionStore
    @ObservedObject var session: Session
    @ObservedObject var groups = GroupStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconBadge(symbol: session.spec.kind.symbol, color: Theme.identity(GroupKey.of(session)), size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(session.name).font(.headline).lineLimit(1)
                        if let g = groups.group(for: GroupKey.of(session)) {
                            Text(g.name).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(g.color.gradient))
                        }
                        StatusPill(activity: session.activity)
                        if !session.spec.modelLabel.isEmpty {
                            Text(session.spec.modelLabel).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(.quaternary))
                        }
                    }
                    HStack(spacing: 10) {
                        Text(abbreviatePath(session.currentDirectory)).lineLimit(1).truncationMode(.middle)
                        if !session.title.isEmpty { Text("· \(session.title)").lineLimit(1) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                StatText(label: "CPU", value: String(format: "%.0f%%", session.cpu))
                StatText(label: "RAM", value: formatBytes(session.rssBytes))
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    StatText(label: "Up", value: formatDuration(Date().timeIntervalSince(session.started)))
                }
                Divider().frame(height: 28)
                Button { reveal(session.currentDirectory) } label: { Image(systemName: "folder") }.help("Reveal folder in Finder")
                Button { store.restart(session) } label: { Image(systemName: "arrow.clockwise") }.help("Restart session")
                if session.isRunning {
                    Button { store.stop(session) } label: { Image(systemName: "stop.fill") }.help("Stop")
                }
                Button { store.requestClose(session) } label: { Image(systemName: "xmark") }.help("Close session")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.vertical, 10)
            Rectangle().fill(session.activity == .idle || session.activity == .exited ? Color(nsColor: .separatorColor) : session.activity.color)
                .frame(height: session.activity == .idle || session.activity == .exited ? 1 : 2)
            TerminalHost(session: session)
                .frame(minWidth: 200, maxWidth: .infinity, minHeight: 150, maxHeight: .infinity)
                .background(Color(nsColor: session.terminal.nativeBackgroundColor))
                .clipped()
        }
        .navigationTitle(session.name)
    }
}

struct StatusPill: View {
    let activity: SessionActivity
    var body: some View {
        HStack(spacing: 5) {
            ActivityDot(activity: activity, size: 6)
            Text(activity.label).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(activity.color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(activity.color.opacity(0.15)))
        .overlay(Capsule().strokeBorder(activity.color.opacity(0.3)))
    }
}

struct StatText: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
        .frame(minWidth: 44, alignment: .trailing)
    }
}

// MARK: - New session

struct NewSessionSheet: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var models: ModelManager
    @Environment(\.dismiss) var dismiss
    let preset: LaunchSpec?

    @State private var directory = ""
    @State private var name = ""
    @State private var kind: AgentKind = .claude
    @State private var claudeModel = ""
    @State private var customClaudeModel = ""
    @State private var continueLast = false
    @State private var skipPermissions = false
    @State private var extraArgs = ""
    @State private var localModelPath = ""
    @State private var customCommand = ""

    static let claudeModels: [(String, String)] = [
        ("", "Default"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku"), ("custom", "Other…"),
    ]

    var chatModels: [LocalModel] { models.models.filter { $0.isChatCapable } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Session").font(.title2.bold()).padding([.horizontal, .top], 20).padding(.bottom, 8)
            Form {
                Section("Project folder") {
                    HStack {
                        TextField("Folder", text: $directory, prompt: Text("Choose a folder…"))
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…", action: chooseFolder)
                        if !store.recentDirectories.isEmpty {
                            Menu {
                                ForEach(store.recentDirectories, id: \.self) { d in
                                    Button(abbreviatePath(d)) { setDirectory(d) }
                                }
                            } label: { Image(systemName: "clock.arrow.circlepath") }
                            .menuStyle(.borderlessButton).fixedSize().help("Recent folders")
                        }
                    }
                    TextField("Session name", text: $name, prompt: Text("Defaults to the folder name"))
                }
                Section("Agent") {
                    Picker("Run", selection: $kind) {
                        ForEach(AgentKind.allCases) { k in Label(k.rawValue, systemImage: k.symbol).tag(k) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch kind {
                    case .claude:
                        Picker("Model", selection: $claudeModel) {
                            ForEach(Self.claudeModels, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        if claudeModel == "custom" {
                            TextField("Model ID", text: $customClaudeModel, prompt: Text("e.g. claude-opus-5-5"))
                        }
                        Toggle("Continue the most recent conversation in this folder", isOn: $continueLast)
                        Toggle("Skip permission prompts (--dangerously-skip-permissions)", isOn: $skipPermissions)
                        TextField("Extra arguments", text: $extraArgs, prompt: Text("optional, e.g. --verbose"))
                    case .local:
                        if !models.engineInstalled {
                            Label("The MLX engine isn't installed yet. Install it from Models & Server.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        if chatModels.isEmpty {
                            Text("No local chat models found.").foregroundStyle(.secondary)
                        } else {
                            Picker("Model", selection: $localModelPath) {
                                ForEach(chatModels) { m in Text("\(m.name)  (\(formatBytes(m.sizeBytes)))").tag(m.path) }
                            }
                        }
                        Text("Opens an interactive chat with the model in a terminal (mlx_lm.chat).")
                            .font(.caption).foregroundStyle(.secondary)
                    case .shell:
                        Text("A plain zsh shell in this folder.").foregroundStyle(.secondary)
                    case .custom:
                        TextField("Command", text: $customCommand, prompt: Text("e.g. codex, aider, npm run dev"))
                    }
                }
                Section {
                    Text(previewCommand.isEmpty ? "zsh" : previewCommand)
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: { Text("Will run") }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Launch") { launch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canLaunch)
            }
            .padding(20)
        }
        .frame(width: 600, height: 600)
        .onAppear(perform: applyPreset)
    }

    private var canLaunch: Bool {
        guard !directory.isEmpty, FileManager.default.fileExists(atPath: directory) else { return false }
        switch kind {
        case .local: return !localModelPath.isEmpty
        case .custom: return !customCommand.trimmingCharacters(in: .whitespaces).isEmpty
        default: return true
        }
    }

    private var claudeModelID: String { claudeModel == "custom" ? customClaudeModel.trimmingCharacters(in: .whitespaces) : claudeModel }

    private var previewCommand: String {
        switch kind {
        case .claude:
            var parts = ["claude"]
            if !claudeModelID.isEmpty { parts += ["--model", claudeModelID] }
            if continueLast { parts.append("--continue") }
            if skipPermissions { parts.append("--dangerously-skip-permissions") }
            if !extraArgs.isEmpty { parts.append(extraArgs) }
            return parts.joined(separator: " ")
        case .local:
            guard !localModelPath.isEmpty else { return "" }
            let bin = ModelManager.venvBin + "/mlx_lm.chat"
            return "\(shellQuote(bin)) --model \(shellQuote(localModelPath))"
        case .shell: return ""
        case .custom: return customCommand
        }
    }

    private func modelLabel() -> String {
        switch kind {
        case .claude:
            if claudeModelID.isEmpty { return "Claude" }
            return "Claude · " + (Self.claudeModels.first { $0.0 == claudeModelID }?.1 ?? claudeModelID)
        case .local:
            return chatModels.first { $0.path == localModelPath }?.name.components(separatedBy: "/").last ?? "Local"
        case .shell: return ""
        case .custom: return customCommand.split(separator: " ").first.map(String.init) ?? ""
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if !directory.isEmpty { panel.directoryURL = URL(fileURLWithPath: directory) }
        if panel.runModal() == .OK, let url = panel.url { setDirectory(url.path) }
    }

    private func setDirectory(_ d: String) {
        let oldDefault = (directory as NSString).lastPathComponent
        directory = d
        if name.isEmpty || name == oldDefault { name = (d as NSString).lastPathComponent }
    }

    private func applyPreset() {
        if localModelPath.isEmpty { localModelPath = chatModels.first?.path ?? "" }
        if let p = preset {
            setDirectory(p.directory)
            kind = p.kind
            if p.kind == .custom { customCommand = p.command }
            if p.kind == .claude && p.command.contains("--continue") { continueLast = true }
            if !p.name.isEmpty { name = p.name }
        } else if directory.isEmpty, let recent = store.recentDirectories.first {
            setDirectory(recent)
        }
    }

    private func launch() {
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? (directory as NSString).lastPathComponent : name
        var command = previewCommand
        if kind == .local && !models.engineInstalled {
            command = "echo 'MLX engine not installed — open Models & Server and click Install Engine.'"
        }
        store.launch(LaunchSpec(name: finalName, directory: directory, kind: kind,
                                model: kind == .claude ? claudeModelID : localModelPath,
                                modelLabel: modelLabel(), command: command))
        dismiss()
    }
}
