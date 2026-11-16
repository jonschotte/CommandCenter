import SwiftUI
import AppKit

@main
struct CommandCenterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var sessions = SessionStore()
    @StateObject private var scanner = ProcessScanner()
    @StateObject private var system = SystemMonitor()
    @StateObject private var models = ModelManager()
    @StateObject private var events = AgentEvents()

    var body: some Scene {
        WindowGroup("Command Center") {
            ContentView()
                .environmentObject(sessions)
                .environmentObject(scanner)
                .environmentObject(system)
                .environmentObject(models)
                .environmentObject(events)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear {
                    events.sessions = sessions
                    events.scanner = scanner
                    events.start()
                    scanner.sessions = sessions
                    scanner.start()
                    system.start()
                    models.refresh()
                    CommandCenterControlServer.shared.start()
                    ChiefHostLink.shared.start()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Session…") { sessions.showNewSession = true }
                    .keyboardShortcut("t", modifiers: .command)
                Button("New Terminal") { sessions.newTerminal() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            CommandMenu("Terminal") {
                Button("Find…") { TerminalCommands.find(.showFindInterface) }.keyboardShortcut("f")
                Button("Find Next") { TerminalCommands.find(.nextMatch) }.keyboardShortcut("g")
                Button("Find Previous") { TerminalCommands.find(.previousMatch) }.keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button("Clear Scrollback") { TerminalCommands.clear() }.keyboardShortcut("k")
                Divider()
                Button("Bigger Text") { TerminalProfile.changeSize(by: 1) }.keyboardShortcut("+")
                Button("Smaller Text") { TerminalProfile.changeSize(by: -1) }.keyboardShortcut("-")
                Button("Default Text Size") { TerminalProfile.changeSize(by: nil) }.keyboardShortcut("0")
            }
        }
        Settings {
            SettingsView()
                .environmentObject(events)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (no bundle): become a real foreground app.
        NSApp.setActivationPolicy(.regular)
        // COMMANDCENTER_BACKGROUND=1 (tests, `open -g --env`) means "don't take the foreground".
        if ProcessInfo.processInfo.environment["COMMANDCENTER_BACKGROUND"] != "1" {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = SessionStore.liveCount
        let serverUp = ModelManager.serverRunning
        guard running > 0 || serverUp else { return .terminateNow }
        let persistent = SessionVault.keeper != nil
        let alert = NSAlert()
        alert.messageText = "Quit Command Center?"
        var lines: [String] = []
        if running > 0 {
            lines.append(persistent
                ? "\(running) session(s) will keep running in the background and reconnect when you reopen Command Center."
                : "\(running) session(s) running inside the app will be stopped.")
        }
        if serverUp { lines.append("The local model server will be stopped.") }
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if persistent && running > 0 { alert.addButton(withTitle: "Stop Sessions & Quit") }
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .terminateNow
        case .alertThirdButtonReturn:
            SessionStore.shared?.stopAllNow()
            return .terminateNow
        default: return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ModelManager.shared?.stopServer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
