import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var events: AgentEvents

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Notify when Claude needs permission", isOn: $events.notifyOnPermission)
                Toggle("Notify when Claude finishes a task", isOn: $events.notifyOnDone)
                Toggle("Play a sound", isOn: $events.playSound)
                Text("You won't be notified about the session you're currently looking at.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open macOS Notification Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            }
            Section("Claude sessions started outside Command Center") {
                Text("Claude sessions started in Command Center always report their status. To get status and alerts from Claude sessions you start in Terminal, Cursor, or elsewhere, add Command Center's hook to your Claude Code settings (~/.claude/settings.json). A backup is saved first, and turning this off removes only Command Center's entries. Applies to sessions started after you turn it on.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Track all Claude Code sessions", isOn: Binding(
                    get: { events.globalHooksInstalled },
                    set: { events.setGlobalHooks($0) }))
                if let e = events.lastError {
                    Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}
