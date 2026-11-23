import SwiftUI

/// "What's using my memory?" — the memory breakdown plus every app/process ranked by memory.
struct MemoryView: View {
    @EnvironmentObject var system: SystemMonitor
    @EnvironmentObject var scanner: ProcessScanner
    @State private var search = ""
    @State private var expanded: Set<String> = []
    @State private var confirmQuit: ProcInfo?

    var free: UInt64 {
        let used = system.memUsed + system.memCached
        return system.memTotal > used ? system.memTotal - used : 0
    }

    var groups: [AppMemoryGroup] {
        guard !search.isEmpty else { return scanner.memoryGroups }
        let q = search.lowercased()
        return scanner.memoryGroups.filter { g in
            g.name.lowercased().contains(q) || g.procs.contains { $0.args.lowercased().contains(q) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                breakdown
                HStack {
                    Text("What's using memory").font(.headline)
                    Spacer()
                    TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
                }
                VStack(spacing: 0) {
                    let maxTotal = max(groups.first?.total ?? 1, 1)
                    ForEach(groups.prefix(60)) { g in
                        groupRow(g, maxTotal: maxTotal)
                        if expanded.contains(g.name) {
                            ForEach(g.procs.prefix(40), id: \.pid) { p in procRow(p) }
                        }
                        Divider()
                    }
                }
                .card()
                Text("Memory is each process's physical footprint, the same number Activity Monitor shows. Helper processes are counted with their app. GPU memory used by local models appears as Wired.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .navigationTitle("Memory")
        .confirmationDialog("Quit \(confirmQuit?.displayName ?? "")?", isPresented: Binding(get: { confirmQuit != nil }, set: { if !$0 { confirmQuit = nil } })) {
            Button("Quit Process", role: .destructive) {
                if let p = confirmQuit { scanner.terminate(p.pid) }
                confirmQuit = nil
            }
            Button("Force Quit", role: .destructive) {
                if let p = confirmQuit { scanner.terminate(p.pid, force: true) }
                confirmQuit = nil
            }
        } message: {
            Text("pid \(confirmQuit?.pid ?? 0) · \(formatBytes(confirmQuit?.memory ?? 0)). Unsaved work in it may be lost.")
        }
    }

    private var breakdown: some View {
        let total = Double(max(system.memTotal, 1))
        let parts: [(String, UInt64, Color)] = [
            ("App", system.memApp, Theme.accent),
            ("Wired", system.memWired, Theme.network),
            ("Compressed", system.memCompressed, Theme.gpu),
            ("Cached files", system.memCached, Theme.steel),
            ("Free", free, Color.primary.opacity(0.12)),
        ]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(formatBytes(system.memUsed)).font(.largeTitle.weight(.semibold).monospacedDigit())
                Text("used of \(formatBytes(system.memTotal))").foregroundStyle(.secondary)
                Spacer()
                if system.swapUsed > 0 {
                    Label("Swap \(formatBytes(system.swapUsed))", systemImage: "arrow.left.arrow.right").foregroundStyle(.orange)
                }
            }
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.0) { part in
                        Rectangle().fill(part.2).frame(width: max(0, g.size.width * Double(part.1) / total))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 18)
            HStack(spacing: 18) {
                ForEach(parts, id: \.0) { part in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(part.2).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(part.0).font(.caption).foregroundStyle(.secondary)
                            Text(formatBytes(part.1)).font(.callout.monospacedDigit())
                        }
                    }
                }
            }
        }
        .padding(16).card()
    }

    private func groupRow(_ g: AppMemoryGroup, maxTotal: UInt64) -> some View {
        let isOpen = expanded.contains(g.name)
        return HStack(spacing: 10) {
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: 12)
            Image(systemName: g.isApp ? "app.dashed" : "gearshape").foregroundStyle(.secondary).frame(width: 16)
            Text(g.name).fontWeight(.medium).lineLimit(1)
            if g.procs.count > 1 {
                Text("\(g.procs.count) processes").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule().fill(Theme.accent.opacity(0.7))
                        .frame(width: max(2, geo.size.width * Double(g.total) / Double(maxTotal)))
                }
            }
            .frame(width: 160, height: 6)
            Text(formatBytes(g.total)).font(.callout.monospacedDigit()).frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if isOpen { expanded.remove(g.name) } else { expanded.insert(g.name) }
        }
    }

    private func procRow(_ p: ProcInfo) -> some View {
        HStack(spacing: 10) {
            Text("\(p.pid)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 60, alignment: .trailing)
            Text(shortArgs(p)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help(p.args)
            Spacer(minLength: 12)
            Text(String(format: "%.1f%% CPU", p.cpu)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(formatBytes(p.memory)).font(.caption.monospacedDigit()).frame(width: 90, alignment: .trailing)
            Button { confirmQuit = p } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless).help("Quit this process")
        }
        .padding(.leading, 36).padding(.trailing, 12).padding(.vertical, 4)
        .background(Color.primary.opacity(0.025))
    }

    private func shortArgs(_ p: ProcInfo) -> String {
        if let r = p.args.range(of: ".app/Contents/") {
            return String(p.args[r.upperBound...])
        }
        return abbreviatePath(p.args)
    }
}
