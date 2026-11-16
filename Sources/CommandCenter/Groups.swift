import SwiftUI

/// A user-made folder of terminals (in-app sessions and terminals running elsewhere).
struct SessionGroup: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var colorIndex: Int
    var collapsed = false
    var color: Color { Theme.groupColors[colorIndex % Theme.groupColors.count] }
}

/// Groups are keyed by a string so in-app and outside terminals can share them:
///   "s:<session uuid>"   for Command Center sessions
///   "x:<claude session id>" (or "x:pid<n>") for terminals running elsewhere
enum GroupKey {
    static func of(_ s: Session) -> String { "s:" + s.id.uuidString }
    static func of(_ a: DetectedAgent) -> String {
        if a.name == "claude", let id = claudeID(a.pid) { return "x:" + id }
        return "x:pid\(a.pid)"
    }
    private static var cache: [pid_t: String] = [:]
    private static func claudeID(_ pid: pid_t) -> String? {
        if let c = cache[pid] { return c }
        let id = SessionStore.claudeSessionID(pid: pid)
        if let id { cache[pid] = id }
        return id
    }
}

final class GroupStore: ObservableObject {
    static let shared = GroupStore()

    @Published var groups: [SessionGroup] = [] { didSet { save() } }
    @Published var assignments: [String: UUID] = [:] { didSet { save() } }
    /// Set to show the "New Group" name prompt; the key (if any) is moved into the new group.
    @Published var namingNewGroupFor: String?? = nil
    @Published var renaming: SessionGroup?

    private var loading = true

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "sessionGroups"), let g = try? JSONDecoder().decode([SessionGroup].self, from: data) { groups = g }
        if let data = d.data(forKey: "sessionGroupMap"), let m = try? JSONDecoder().decode([String: UUID].self, from: data) { assignments = m }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(groups), forKey: "sessionGroups")
        d.set(try? JSONEncoder().encode(assignments), forKey: "sessionGroupMap")
    }

    func group(for key: String) -> SessionGroup? {
        guard let id = assignments[key] else { return nil }
        return groups.first { $0.id == id }
    }

    func assign(_ key: String, to group: SessionGroup?) {
        withAnimation(.snappy) { assignments[key] = group?.id }
    }

    @discardableResult
    func create(_ name: String, moving key: String? = nil) -> SessionGroup {
        let g = SessionGroup(name: name, colorIndex: groups.count)
        withAnimation(.snappy) {
            groups.append(g)
            if let key { assignments[key] = g.id }
        }
        return g
    }

    func rename(_ g: SessionGroup, to name: String) {
        if let i = groups.firstIndex(of: g) { groups[i].name = name }
    }

    func setColor(_ g: SessionGroup, _ index: Int) {
        if let i = groups.firstIndex(where: { $0.id == g.id }) { groups[i].colorIndex = index }
    }

    func toggleCollapsed(_ g: SessionGroup) {
        if let i = groups.firstIndex(where: { $0.id == g.id }) { withAnimation(.snappy) { groups[i].collapsed.toggle() } }
    }

    func binding(expanded g: SessionGroup) -> Binding<Bool> {
        Binding(get: { !(self.groups.first { $0.id == g.id }?.collapsed ?? false) },
                set: { v in if let i = self.groups.firstIndex(where: { $0.id == g.id }) { self.groups[i].collapsed = !v } })
    }

    /// Deleting a group keeps its terminals; they just become ungrouped.
    func delete(_ g: SessionGroup) {
        withAnimation(.snappy) {
            groups.removeAll { $0.id == g.id }
            assignments = assignments.filter { $0.value != g.id }
        }
    }

    func move(_ g: SessionGroup, by offset: Int) {
        guard let i = groups.firstIndex(where: { $0.id == g.id }) else { return }
        let j = i + offset
        guard groups.indices.contains(j) else { return }
        withAnimation(.snappy) { groups.swapAt(i, j) }
    }

    /// Carry a terminal's group over when it's restarted or moved into the app.
    func transfer(from old: String, to new: String) {
        if let g = assignments[old] { assignments[new] = g; assignments[old] = nil }
    }

    func forget(_ key: String) { assignments[key] = nil }
}

/// "Move to Group" menu, shared by every terminal row.
struct GroupMenu: View {
    @ObservedObject var groups = GroupStore.shared
    let key: String
    var body: some View {
        Menu("Move to Group") {
            ForEach(groups.groups) { g in
                Button {
                    groups.assign(key, to: g)
                } label: {
                    if groups.assignments[key] == g.id { Label(g.name, systemImage: "checkmark") } else { Text(g.name) }
                }
            }
            if !groups.groups.isEmpty { Divider() }
            Button("New Group…") { groups.namingNewGroupFor = .some(key) }
            if groups.assignments[key] != nil {
                Button("Remove from Group") { groups.assign(key, to: nil) }
            }
        }
    }
}

/// Sidebar header for a group: color, name, live status, and its own menu. Accepts dropped terminals.
struct GroupHeader: View {
    @EnvironmentObject var store: SessionStore
    @ObservedObject var groups = GroupStore.shared
    let group: SessionGroup
    let count: Int
    let busy: Int
    let attention: Int
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(group.color.gradient).frame(width: 10, height: 10)
            Text(group.name).lineLimit(1)
            if busy > 0 { PulsingDot(color: .green, size: 6).help("\(busy) working") }
            if attention > 0 { Image(systemName: "bell.badge.fill").font(.caption2).foregroundStyle(.orange) }
            Spacer(minLength: 0)
            Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(targeted ? group.color.opacity(0.25) : .clear))
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { keys, _ in
            for k in keys { groups.assign(k, to: group) }
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu { GroupContextMenu(group: group) }
    }
}

struct GroupContextMenu: View {
    @EnvironmentObject var store: SessionStore
    @ObservedObject var groups = GroupStore.shared
    let group: SessionGroup
    var body: some View {
        Button("New Terminal in Group") {
            let s = store.newTerminal()
            groups.assign(GroupKey.of(s), to: group)
        }
        Button("Rename…") { groups.renaming = group }
        Menu("Color") {
            ForEach(Theme.groupColors.indices, id: \.self) { i in
                Button { groups.setColor(group, i) } label: {
                    Label(Theme.groupColorNames[i], systemImage: group.colorIndex % Theme.groupColors.count == i ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        }
        Button("Move Up") { groups.move(group, by: -1) }
        Button("Move Down") { groups.move(group, by: 1) }
        Divider()
        Button("Delete Group (keeps terminals)", role: .destructive) { groups.delete(group) }
    }
}

/// Name prompt for new groups and renames.
struct GroupPrompts: ViewModifier {
    @ObservedObject var groups = GroupStore.shared
    @State private var name = ""
    func body(content: Content) -> some View {
        content
            .alert("New Group", isPresented: Binding(get: { groups.namingNewGroupFor != nil }, set: { if !$0 { groups.namingNewGroupFor = nil } })) {
                TextField("Name", text: $name)
                Button("Create") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    groups.create(n.isEmpty ? "Group \(groups.groups.count + 1)" : n, moving: groups.namingNewGroupFor ?? nil)
                    groups.namingNewGroupFor = nil; name = ""
                }
                Button("Cancel", role: .cancel) { groups.namingNewGroupFor = nil; name = "" }
            } message: { Text("Group terminals by project, client, or anything you like. You can also drag terminals onto a group.") }
            .alert("Rename Group", isPresented: Binding(get: { groups.renaming != nil }, set: { if !$0 { groups.renaming = nil } })) {
                TextField("Name", text: $name)
                Button("Rename") {
                    if let g = groups.renaming, !name.trimmingCharacters(in: .whitespaces).isEmpty { groups.rename(g, to: name) }
                    groups.renaming = nil; name = ""
                }
                Button("Cancel", role: .cancel) { groups.renaming = nil; name = "" }
            }
            .onChange(of: groups.renaming) { _, g in if let g { name = g.name } }
    }
}

extension View {
    func groupPrompts() -> some View { modifier(GroupPrompts()) }
}
