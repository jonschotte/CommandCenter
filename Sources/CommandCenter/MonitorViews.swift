import SwiftUI
import Charts

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var scanner: ProcessScanner
    @EnvironmentObject var system: SystemMonitor
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var events: AgentEvents
    @ObservedObject var groups = GroupStore.shared
    @State private var moveAgent: DetectedAgent?

    var external: [DetectedAgent] { scanner.agents.filter { !$0.inApp && $0.category == .agent } }
    let tileColumns = [GridItem(.adaptive(minimum: 270), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                    GaugeCard(title: "CPU", symbol: "cpu", color: Theme.cpu, fraction: system.cpuTotal,
                              value: "\(Int(system.cpuTotal * 100))%",
                              detail: String(format: "Load %.1f · %.1f · %.1f", system.loadAverage.0, system.loadAverage.1, system.loadAverage.2),
                              history: system.cpuHistory) { store.selection = .system }
                    GaugeCard(title: "Memory", symbol: "memorychip", color: Theme.memory, fraction: system.memFraction,
                              value: formatBytes(system.memUsed), detail: "of \(formatBytes(system.memTotal)) · see what's using it",
                              history: system.memHistory) { store.selection = .memory }
                    GaugeCard(title: "GPU", symbol: "square.stack.3d.up.fill", color: Theme.gpu, fraction: system.gpuUtil,
                              value: "\(Int(system.gpuUtil * 100))%", detail: "\(formatBytes(system.gpuMemInUse)) GPU memory in use",
                              history: system.gpuHistory) { store.selection = .system }
                    if let root = system.volumes.first(where: { $0.path == "/" }) ?? system.volumes.first {
                        GaugeCard(title: "Storage", symbol: "internaldrive.fill", color: Theme.storage, fraction: root.fraction,
                                  value: "\(formatBytes(root.available)) free", detail: "\(formatBytes(root.used)) of \(formatBytes(root.total)) used",
                                  history: nil) { store.selection = .system }
                    }
                }

                if store.sessions.isEmpty && external.isEmpty {
                    EmptyHint(text: "No terminals yet. Open a terminal, or start a session with Claude or a local model.", symbol: "terminal")
                }

                ForEach(groups.groups) { g in
                    let ss = store.sessions.filter { groups.assignments[GroupKey.of($0)] == g.id }
                    let xs = external.filter { groups.assignments[GroupKey.of($0)] == g.id }
                    if !ss.isEmpty || !xs.isEmpty {
                        tileSection(title: g.name, color: g.color, group: g, sessions: ss, agents: xs)
                    }
                }
                let ungroupedS = store.sessions.filter { groups.group(for: GroupKey.of($0)) == nil }
                let ungroupedX = external.filter { groups.group(for: GroupKey.of($0)) == nil }
                if !ungroupedS.isEmpty {
                    tileSection(title: groups.groups.isEmpty ? "Sessions" : "Ungrouped", color: .accentColor, group: nil, sessions: ungroupedS, agents: [])
                }
                if !ungroupedX.isEmpty {
                    tileSection(title: "Running in other terminals", color: .secondary, group: nil, sessions: [], agents: ungroupedX)
                }

                modelServer
            }
            .padding(22)
        }
        .navigationTitle("Dashboard")
        .moveHereDialog(agent: $moveAgent)
    }

    // MARK: Hero

    private var counts: (working: Int, needs: Int, turn: Int, idle: Int) {
        var w = 0, n = 0, t = 0, i = 0
        let all = store.sessions.map(\.activity) + external.map { externalActivity($0, events: events) }
        for a in all {
            switch a { case .working: w += 1; case .needsYou: n += 1; case .yourTurn: t += 1; default: i += 1 }
        }
        return (w, n, t, i)
    }

    private var hero: some View {
        let c = counts
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Command Center").font(.largeTitle.weight(.bold))
                    .foregroundStyle(LinearGradient(colors: [.indigo, .purple, .pink], startPoint: .leading, endPoint: .trailing))
                Spacer()
                Button { store.newTerminal() } label: { Label("New Terminal", systemImage: "terminal") }
                Button { store.showNewSession = true } label: { Label("New Session", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            HStack(spacing: 16) {
                Text("\(store.sessions.count + external.count) terminals").foregroundStyle(.secondary)
                StatusCount(activity: .working, count: c.working)
                StatusCount(activity: .needsYou, count: c.needs)
                StatusCount(activity: .yourTurn, count: c.turn)
                StatusCount(activity: .idle, count: c.idle)
            }
            .font(.callout)
        }
    }

    // MARK: Tiles

    @ViewBuilder
    private func tileSection(title: String, color: Color, group: SessionGroup?, sessions: [Session], agents: [DetectedAgent]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(color.gradient).frame(width: 12, height: 12)
                Text(title).font(.title3.weight(.semibold))
                Text("\(sessions.count + agents.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 1).background(Capsule().fill(.quaternary))
                Spacer()
                if let group {
                    Menu { GroupContextMenu(group: group) } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
            }
            LazyVGrid(columns: tileColumns, spacing: 14) {
                ForEach(sessions) { s in SessionTile(session: s) }
                ForEach(agents) { a in AgentTile(agent: a, onMove: { moveAgent = a }) }
            }
        }
        .dropDestination(for: String.self) { keys, _ in
            for k in keys { groups.assign(k, to: group) }
            return true
        }
    }

    private var modelServer: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: "shippingbox.fill", color: Theme.memory)
            VStack(alignment: .leading, spacing: 1) {
                Text("Local model server").fontWeight(.medium)
                HStack(spacing: 6) {
                    PulsingDot(color: models.serverState == .running ? .green : .gray, size: 6, animating: models.serverState == .running)
                    Text(models.serverState.label).foregroundStyle(models.serverState == .running ? .green : .secondary)
                    if let m = models.serverModel, models.serverState != .stopped {
                        Text("· " + m.name).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.caption)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(14)
        .glowCard(Theme.memory)
        .clickableRow { store.selection = .models }
    }
}

/// "● 2 working" — the dashboard's status summary, which doubles as the color legend.
struct StatusCount: View {
    let activity: SessionActivity
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(activity.color).frame(width: 8, height: 8)
            Text("\(count)").fontWeight(.bold).monospacedDigit()
            Text(activity.label.lowercased())
        }
        .foregroundStyle(count > 0 ? activity.color : .secondary)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(activity.color.opacity(count > 0 ? 0.16 : 0.06)))
        .overlay(Capsule().strokeBorder(activity.color.opacity(count > 0 ? 0.4 : 0.15)))
        .help(activity.explanation)
    }
}

/// Group color along a card's left edge.
struct GroupStripe: View {
    let color: Color
    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14)
            .fill(color.gradient).frame(width: 5)
    }
}

struct GaugeCard: View {
    let title: String
    let symbol: String
    let color: Color
    let fraction: Double
    let value: String
    let detail: String
    let history: [Sample]?
    let action: () -> Void

    var body: some View {
        let tint = Theme.level(fraction, base: color)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RingGauge(fraction: fraction, color: tint, lineWidth: 6)
                    Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.uppercased()).font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.secondary)
                    Text(value).font(.system(.title2, design: .rounded).weight(.bold).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
            }
            if let history, history.count > 1 {
                Chart(history) { s in
                    AreaMark(x: .value("t", s.id), y: .value("v", s.value))
                        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.45), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("t", s.id), y: .value("v", s.value))
                        .foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: 36)
            } else {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(tint.opacity(0.15))
                        Capsule().fill(LinearGradient(colors: [tint.opacity(0.6), tint], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, g.size.width * min(max(fraction, 0), 1)))
                    }
                }
                .frame(height: 8).padding(.vertical, 14)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glowCard(tint)
        .clickableRow(action: action)
    }
}

/// A terminal as a card: status, folder, live preview of its last lines, stats.
struct SessionTile: View {
    @EnvironmentObject var store: SessionStore
    @ObservedObject var session: Session
    @ObservedObject private var groups = GroupStore.shared
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconBadge(symbol: session.spec.kind.symbol, color: Theme.identity(GroupKey.of(session)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name).font(.headline).lineLimit(1)
                    Text(abbreviatePath(session.currentDirectory)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                StatusPill(activity: session.activity)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                TerminalPreview(lines: session.preview(lines: 4))
            }
            HStack(spacing: 12) {
                if !session.spec.modelLabel.isEmpty { Tag(session.spec.modelLabel) }
                if session.needsAttention { Label("Waiting", systemImage: "bell.badge.fill").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Label(String(format: "%.0f%%", session.cpu), systemImage: "cpu").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Label(formatBytes(session.rssBytes), systemImage: "memorychip").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .overlay(alignment: .leading) { GroupStripe(color: Theme.identity(GroupKey.of(session))) }
        .glowCard(session.activity.tileTint, highlighted: hovering || session.activity == .needsYou)
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.snappy(duration: 0.2), value: hovering)
        .onHover { hovering = $0 }
        .clickableRow { store.selection = .session(session.id) }
        .draggable(GroupKey.of(session))
        .contextMenu {
            Button("Open") { store.selection = .session(session.id) }
            Button("Restart") { store.restart(session) }
            Button("Reveal in Finder") { reveal(session.currentDirectory) }
            GroupMenu(key: GroupKey.of(session))
            Divider()
            Button("Close Session…", role: .destructive) { store.requestClose(session) }
        }
        .help("Open \(session.name)")
    }
}

struct AgentTile: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var events: AgentEvents
    let agent: DetectedAgent
    let onMove: () -> Void
    @ObservedObject private var groups = GroupStore.shared
    @State private var hovering = false

    var body: some View {
        let activity = externalActivity(agent, events: events)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconBadge(symbol: "sparkles", color: Theme.identity(GroupKey.of(agent)))
                VStack(alignment: .leading, spacing: 1) {
                    Text((agent.cwd as NSString).lastPathComponent.isEmpty ? agent.name : (agent.cwd as NSString).lastPathComponent)
                        .font(.headline).lineLimit(1)
                    Text("\(agent.name) · \(agent.host)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                StatusPill(activity: activity)
            }
            if let msg = events.external[agent.pid]?.1, !msg.isEmpty {
                Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 12) {
                Button { onMove() } label: { Label("Move Here", systemImage: "arrow.down.right.and.arrow.up.left.square") }
                    .buttonStyle(.borderless).font(.caption.weight(.medium))
                Spacer()
                Label(formatDuration(agent.elapsed), systemImage: "clock").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Label(formatBytes(agent.rssBytes), systemImage: "memorychip").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .overlay(alignment: .leading) { GroupStripe(color: Theme.identity(GroupKey.of(agent))) }
        .glowCard(activity.tileTint, highlighted: hovering || activity == .needsYou)
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.snappy(duration: 0.2), value: hovering)
        .onHover { hovering = $0 }
        .clickableRow { store.selection = .external(agent.pid) }
        .draggable(GroupKey.of(agent))
        .contextMenu {
            Button("Open") { store.selection = .external(agent.pid) }
            Button("Move Here…") { onMove() }
            Button("Reveal Folder in Finder") { reveal(agent.cwd) }
            GroupMenu(key: GroupKey.of(agent))
            Divider()
            Button(TerminalBridge.host(for: agent.host) != nil ? "Close Terminal Tab…" : "Stop Agent…", role: .destructive) {
                store.requestExternalClose(agent)
            }
        }
    }
}

struct TerminalPreview: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if lines.isEmpty {
                Text("…").foregroundStyle(.white.opacity(0.4))
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                Text(l).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(Color(white: 0.85).opacity(0.55 + 0.45 * Double(i + 1) / Double(max(lines.count, 1))))
            }
        }
        .font(.system(size: 10.5, design: .monospaced))
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.08, green: 0.08, blue: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.06)))
    }
}

struct AgentLine: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var scanner: ProcessScanner
    let agent: DetectedAgent
    @State private var confirmKill = false
    @State private var confirmMove: DetectedAgent?

    /// Agents can be opened: in-app ones jump to their session, outside ones open the live mirror.
    private var canOpen: Bool { agent.category == .agent }

    private func open() {
        if agent.inApp, let s = store.sessions.first(where: { s in
            [s.rootPid, s.pid].contains { $0 > 0 && (scanner.descendants(of: $0)).contains(agent.pid) }
        }) {
            store.selection = .session(s.id)
        } else {
            store.selection = .external(agent.pid)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: agent.category == .agent ? "sparkles" : "cpu").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name).fontWeight(.medium)
                    Text(agent.host).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                    Text("pid \(agent.pid)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Text(agent.cwd.isEmpty ? agent.args : abbreviatePath(agent.cwd))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(agent.args)
            }
            Spacer()
            StatText(label: "Up", value: formatDuration(agent.elapsed))
            StatText(label: "CPU", value: String(format: "%.0f%%", agent.cpu))
            StatText(label: "RAM", value: formatBytes(agent.rssBytes))

            Menu {
                if !agent.cwd.isEmpty {
                    Button("Reveal Folder in Finder") { reveal(agent.cwd) }
                    if agent.category == .agent && !agent.inApp {
                        Button("Move Here…") { confirmMove = agent }
                    }
                    Button("Open Terminal in This Folder") { store.newTerminal(in: agent.cwd) }
                }
                Button("Copy Command Line") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(agent.args, forType: .string)
                }
                Divider()
                Button("Stop (SIGTERM)") { confirmKill = true }
                Button("Force Kill (SIGKILL)", role: .destructive) { scanner.terminate(agent.pid, force: true) }
                if TerminalBridge.host(for: agent.host) != nil && !agent.inApp {
                    Button("Close Terminal Tab…", role: .destructive) { store.requestExternalClose(agent) }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .clickableRow(enabled: canOpen) { open() }
        .help(canOpen ? "Open this session" : "")
        .moveHereDialog(agent: $confirmMove)
        .confirmationDialog("Stop \(agent.name) (pid \(agent.pid))?", isPresented: $confirmKill) {
            Button("Stop", role: .destructive) { scanner.terminate(agent.pid) }
        } message: {
            Text("Running in \(agent.host) at \(abbreviatePath(agent.cwd)). Unsaved work in that session may be lost.")
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let fraction: Double
    let detail: String
    let history: [Sample]?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            if let history, history.count > 1 {
                Chart(history) { s in
                    AreaMark(x: .value("t", s.id), y: .value("v", s.value))
                        .foregroundStyle(meterColor(fraction).opacity(0.25))
                    LineMark(x: .value("t", s.id), y: .value("v", s.value))
                        .foregroundStyle(meterColor(fraction))
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: 40)
            } else {
                ProgressView(value: min(max(fraction, 0), 1)).tint(meterColor(fraction)).frame(height: 40)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct EmptyHint: View {
    let text: String
    let symbol: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).card()
    }
}

extension View {
    func card() -> some View {
        background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
    }
}

// MARK: - All agents

struct AgentsView: View {
    @EnvironmentObject var scanner: ProcessScanner
    @State private var showInApp = true

    var shown: [DetectedAgent] { scanner.agents.filter { showInApp || !$0.inApp } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Every coding agent and model server running on this Mac, wherever it was started.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Include in-app sessions", isOn: $showInApp).toggleStyle(.checkbox)
                }
                ForEach([AgentCategory.agent, .modelServer], id: \.self) { cat in
                    let list = shown.filter { $0.category == cat }
                    Text(cat == .agent ? "Agents (\(list.count))" : "Model servers (\(list.count))").font(.headline)
                    if list.isEmpty {
                        EmptyHint(text: cat == .agent ? "No agents detected." : "No model servers detected.", symbol: "moon.zzz")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(list) { a in
                                AgentLine(agent: a)
                                if a.id != list.last?.id { Divider() }
                            }
                        }
                        .card()
                    }
                }
                Text("Agents started in other terminals can be watched and stopped here, but not typed into. That's a macOS limit. Click one, then Move Here, to run it as a full terminal in Command Center.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .navigationTitle("All Running Agents")
    }
}

// MARK: - System

struct SystemView: View {
    @EnvironmentObject var system: SystemMonitor
    @EnvironmentObject var scanner: ProcessScanner

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 12) {
                    BigChart(title: "CPU", value: "\(Int(system.cpuTotal * 100))%", history: system.cpuHistory, color: .blue)
                    BigChart(title: "Memory", value: "\(Int(system.memFraction * 100))%", history: system.memHistory, color: .purple)
                    BigChart(title: "GPU", value: "\(Int(system.gpuUtil * 100))%", history: system.gpuHistory, color: .orange)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("CPU cores").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 6)], spacing: 6) {
                        ForEach(Array(system.cpuCores.enumerated()), id: \.offset) { i, v in
                            VStack(spacing: 3) {
                                GeometryReader { g in
                                    ZStack(alignment: .bottom) {
                                        RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                                        RoundedRectangle(cornerRadius: 3).fill(meterColor(v)).frame(height: g.size.height * v)
                                    }
                                }
                                .frame(height: 40)
                                Text("\(i)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(14).card()

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Memory").font(.headline)
                        KV("Used", formatBytes(system.memUsed) + " of " + formatBytes(system.memTotal))
                        KV("App memory", formatBytes(system.memApp))
                        KV("Wired", formatBytes(system.memWired))
                        KV("Compressed", formatBytes(system.memCompressed))
                        KV("Cached files", formatBytes(system.memCached))
                        KV("Swap", formatBytes(system.swapUsed) + " of " + formatBytes(system.swapTotal))
                        KV("GPU memory in use", formatBytes(system.gpuMemInUse))
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).card()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("General").font(.headline)
                        KV("Processes", "\(scanner.processCount)")
                        KV("Load average", String(format: "%.2f  %.2f  %.2f", system.loadAverage.0, system.loadAverage.1, system.loadAverage.2))
                        KV("Network ↓", formatBytes(UInt64(max(0, system.netIn))) + "/s")
                        KV("Network ↑", formatBytes(UInt64(max(0, system.netOut))) + "/s")
                        KV("Thermal state", thermalLabel)
                        KV("Uptime", formatDuration(system.uptime))
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).card()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Storage").font(.headline)
                    ForEach(system.volumes) { v in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(v.name).fontWeight(.medium)
                                Text(v.path).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(formatBytes(v.available)) free of \(formatBytes(v.total))").font(.caption.monospacedDigit())
                            }
                            ProgressView(value: v.fraction).tint(meterColor(v.fraction))
                        }
                    }
                }
                .padding(14).card()

                HStack(alignment: .top, spacing: 12) {
                    ProcList(title: "Top memory", procs: scanner.topByMemory) { formatBytes($0.memory) }
                    ProcList(title: "Top CPU", procs: scanner.topByCPU) { String(format: "%.1f%%", $0.cpu) }
                }
            }
            .padding(20)
        }
        .navigationTitle("System")
    }

    var thermalLabel: String {
        switch system.thermal {
        case .nominal: return "Normal"
        case .fair: return "Fair"
        case .serious: return "Serious (throttling)"
        case .critical: return "Critical"
        @unknown default: return "—"
        }
    }
}

struct KV: View {
    let k: String, v: String
    init(_ k: String, _ v: String) { self.k = k; self.v = v }
    var body: some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).monospacedDigit()
        }
        .font(.callout)
    }
}

struct BigChart: View {
    let title: String
    let value: String
    let history: [Sample]
    let color: Color
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(value).font(.title3.monospacedDigit().weight(.semibold))
            }
            Chart(history) { s in
                AreaMark(x: .value("t", s.id), y: .value("%", s.value)).foregroundStyle(color.opacity(0.2))
                LineMark(x: .value("t", s.id), y: .value("%", s.value)).foregroundStyle(color)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(values: [0, 50, 100]) }
            .frame(height: 110)
        }
        .padding(14).frame(maxWidth: .infinity).card()
    }
}

struct ProcList: View {
    let title: String
    let procs: [ProcInfo]
    let metric: (ProcInfo) -> String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(procs, id: \.pid) { p in
                HStack {
                    Text(p.displayName).lineLimit(1).help(p.args)
                    Spacer()
                    Text(metric(p)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).card()
    }
}


/// Makes a whole row clickable, with a hover highlight and pointing-hand cursor.
struct ClickableRow: ViewModifier {
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering && enabled ? Color.accentColor.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
            .onHover { h in
                hovering = h
                guard enabled else { return }
                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onTapGesture { if enabled { action() } }
    }
}

extension View {
    func clickableRow(enabled: Bool = true, action: @escaping () -> Void) -> some View {
        modifier(ClickableRow(enabled: enabled, action: action))
    }
}
