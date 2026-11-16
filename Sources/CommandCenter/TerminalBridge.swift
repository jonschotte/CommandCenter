import Foundation
import AppKit

/// Remote-controls tabs in Terminal.app / iTerm2 via AppleScript, matched by their tty.
/// Lets Command Center mirror and type into sessions it didn't start.
enum TerminalBridge {
    enum Host: String { case terminal = "Terminal", iterm = "iTerm2" }

    enum SpecialKey: String, CaseIterable, Identifiable {
        case escape = "Esc", ctrlC = "⌃C", up = "↑", down = "↓", shiftTab = "⇧Tab", tab = "Tab", enter = "Enter"
        var id: String { rawValue }
        var appleScript: String {
            switch self {
            case .escape: return "key code 53"
            case .ctrlC: return "keystroke \"c\" using control down"
            case .up: return "key code 126"
            case .down: return "key code 125"
            case .shiftTab: return "key code 48 using shift down"
            case .tab: return "key code 48"
            case .enter: return "key code 36"
            }
        }
        var help: String {
            switch self {
            case .escape: return "Escape (interrupts Claude)"
            case .ctrlC: return "Control-C"
            case .up: return "Up arrow"
            case .down: return "Down arrow"
            case .shiftTab: return "Shift-Tab (cycles Claude's permission mode)"
            case .tab: return "Tab"
            case .enter: return "Return"
            }
        }
    }

    static func host(for name: String) -> Host? {
        switch name {
        case "Terminal": return .terminal
        case "iTerm2", "iTerm": return .iterm
        default: return nil
        }
    }

    private static let queue = DispatchQueue(label: "terminal-bridge")

    static func devPath(_ tty: String) -> String { tty.hasPrefix("/dev/") ? tty : "/dev/" + tty }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Wraps `body` so it runs with `t` bound to the tab/session whose tty matches.
    private static func script(_ host: Host, tty: String, body: String, notFound: String = "return \"__NOTFOUND__\"") -> String {
        let dev = devPath(tty)
        switch host {
        case .terminal:
            return """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(dev)" then
                            \(body)
                        end if
                    end repeat
                end repeat
            end tell
            \(notFound)
            """
        case .iterm:
            return """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with tb in tabs of w
                        repeat with t in sessions of tb
                            if tty of t is "\(dev)" then
                                \(body)
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            \(notFound)
            """
        }
    }

    private static func run(_ source: String) -> Result<String, BridgeError> {
        var err: NSDictionary?
        guard let s = NSAppleScript(source: source) else { return .failure("script error") }
        let out = s.executeAndReturnError(&err)
        if let err {
            let num = err[NSAppleScript.errorNumber] as? Int ?? 0
            let msg = err[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
            if num == -1743 { return .failure("Command Center isn't allowed to control this terminal yet. Allow it in System Settings → Privacy & Security → Automation.") }
            if num == -1719 || num == 1002 || msg.contains("assistive") {
                return .failure("Special keys need Accessibility permission. Add Command Center in System Settings → Privacy & Security → Accessibility.")
            }
            return .failure(BridgeError(msg))
        }
        let str = out.stringValue ?? ""
        if str == "__NOTFOUND__" { return .failure("That terminal tab is no longer open.") }
        return .success(str)
    }

    /// Text of the tab (visible screen + scrollback for Terminal.app; full contents for iTerm2).
    static func snapshot(_ host: Host, tty: String, completion: @escaping (Result<String, BridgeError>) -> Void) {
        let body = host == .terminal ? "set h to history of t\n return h" : "set h to contents of t\n return h"
        queue.async {
            let r = run(script(host, tty: tty, body: body))
            DispatchQueue.main.async { completion(r) }
        }
    }

    /// Types `text` into the tab, followed by Return.
    static func send(_ host: Host, tty: String, text: String, completion: @escaping (Result<String, BridgeError>) -> Void) {
        let body = host == .terminal
            ? "do script \"\(esc(text))\" in t\n return \"ok\""
            : "tell t to write text \"\(esc(text))\"\n return \"ok\""
        queue.async {
            let r = run(script(host, tty: tty, body: body))
            DispatchQueue.main.async { completion(r) }
        }
    }

    /// Brings the tab to the front of its app.
    static func focus(_ host: Host, tty: String, completion: ((Result<String, BridgeError>) -> Void)? = nil) {
        let body: String
        switch host {
        case .terminal:
            body = "set selected of t to true\n set index of w to 1\n set frontmost of w to true\n activate\n return \"ok\""
        case .iterm:
            body = "tell tb to select\n tell t to select\n select w\n activate\n return \"ok\""
        }
        queue.async {
            let r = run(script(host, tty: tty, body: body))
            DispatchQueue.main.async { completion?(r) }
        }
    }

    /// Closes the tab (call after its processes are stopped so the terminal doesn't ask to confirm).
    static func closeTab(_ host: Host, tty: String, completion: @escaping (Result<String, BridgeError>) -> Void) {
        let body: String
        switch host {
        case .terminal:
            body = """
            if (count of tabs of w) is 1 then
                close w
            else
                set selected of t to true
                set index of w to 1
                activate
                delay 0.2
                tell application "System Events" to keystroke "w" using command down
            end if
            return "ok"
            """
        case .iterm:
            body = "tell t to close\n return \"ok\""
        }
        queue.async {
            let r = run(script(host, tty: tty, body: body))
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                completion(r)
            }
        }
    }

    /// Sends a special key: focuses the tab, presses the key via System Events, then returns to Command Center.
    static func sendKey(_ host: Host, tty: String, key: SpecialKey, completion: @escaping (Result<String, BridgeError>) -> Void) {
        queue.async {
            var r = run(script(host, tty: tty, body: host == .terminal
                ? "set selected of t to true\n set index of w to 1\n return \"ok\""
                : "tell tb to select\n tell t to select\n select w\n return \"ok\""))
            if case .success = r {
                r = run("""
                tell application "\(host.rawValue)" to activate
                delay 0.15
                tell application "System Events" to \(key.appleScript)
                return "ok"
                """)
            }
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                completion(r)
            }
        }
    }
}

struct BridgeError: Error, ExpressibleByStringLiteral {
    let message: String
    init(_ message: String) { self.message = message }
    init(stringLiteral value: String) { message = value }
}
