import AppKit
import SwiftTerm

/// The look of the user's default Terminal.app profile (font, text and background colors, the 16 ANSI colors,
/// selection color, Option-as-Meta), so terminals in Command Center look the same as the ones in Terminal.
/// Falls back to a neutral dark theme if the profile can't be read.
struct TerminalProfile {
    var font: NSFont
    var foreground: NSColor
    var background: NSColor
    var bold: NSColor?
    var selection: NSColor?
    var cursor: NSColor?
    var ansi: [NSColor]?
    var optionAsMeta = true
    var cursorStyle: CursorStyle = .steadyBlock

    static let current = load()

    private static let ansiKeys = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]

    private static func load() -> TerminalProfile {
        var p = TerminalProfile(font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                                foreground: NSColor(calibratedWhite: 0.9, alpha: 1),
                                background: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1))
        guard let d = UserDefaults(suiteName: "com.apple.Terminal"),
              let name = d.string(forKey: "Default Window Settings"),
              let profile = (d.dictionary(forKey: "Window Settings")?[name] as? [String: Any]) else { return p }

        func color(_ key: String) -> NSColor? {
            guard let data = profile[key] as? Data,
                  let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else { return nil }
            return c.usingColorSpace(.sRGB)
        }
        if let data = profile["Font"] as? Data,
           let f = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: data) {
            // Terminal's built-in profiles use SF Mono, which decodes as the system font here.
            p.font = f.isFixedPitch ? f : .monospacedSystemFont(ofSize: f.pointSize, weight: .regular)
        }
        if let c = color("TextColor") { p.foreground = c }
        // Terminal windows can be see-through; Command Center's aren't, so drop the transparency.
        if let c = color("BackgroundColor") { p.background = c.withAlphaComponent(1) }
        p.bold = color("TextBoldColor")
        p.selection = color("SelectionColor")
        p.cursor = color("CursorColor")
        let normal = ansiKeys.compactMap { color("ANSI\($0)Color") }
        let bright = ansiKeys.compactMap { color("ANSIBright\($0)Color") }
        if normal.count == 8, bright.count == 8 { p.ansi = normal + bright }
        if let meta = profile["useOptionAsMetaKey"] as? Bool { p.optionAsMeta = meta }
        // Terminal: CursorType 0 block, 1 underline, 2 bar; CursorBlink off by default.
        let blink = profile["CursorBlink"] as? Bool ?? false
        switch profile["CursorType"] as? Int ?? 0 {
        case 1: p.cursorStyle = blink ? .blinkUnderline : .steadyUnderline
        case 2: p.cursorStyle = blink ? .blinkBar : .steadyBar
        default: p.cursorStyle = blink ? .blinkBlock : .steadyBlock
        }
        return p
    }

    /// Every terminal view on screen, so text-size changes reach all of them.
    private static let views = NSHashTable<TerminalView>.weakObjects()

    /// Extra points added to the profile's font size (⌘+ / ⌘−), remembered across launches.
    static var sizeDelta: CGFloat {
        get { CGFloat(UserDefaults.standard.double(forKey: "terminalFontDelta")) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "terminalFontDelta") }
    }

    var sizedFont: NSFont {
        let size = max(8, min(36, font.pointSize + Self.sizeDelta))
        return NSFont(descriptor: font.fontDescriptor, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func changeSize(by delta: CGFloat?) {
        sizeDelta = delta.map { max(-4, min(24, sizeDelta + $0)) } ?? 0
        for tv in views.allObjects { tv.font = current.sizedFont }
        NotificationCenter.default.post(name: fontChanged, object: nil)
    }

    /// Posted after the text size changes, for views that size their own font (ChiefFitView).
    static let fontChanged = Notification.Name("TerminalProfile.fontChanged")

    func apply(to tv: TerminalView) {
        Self.views.add(tv)
        tv.font = sizedFont
        tv.getTerminal().changeScrollback(10_000)   // SwiftTerm keeps only 500 lines by default
        tv.getTerminal().setCursorStyle(cursorStyle)
        tv.nativeForegroundColor = foreground
        tv.nativeBackgroundColor = background
        tv.caretColor = cursor ?? foreground.withAlphaComponent(0.7)
        if let selection { tv.selectedTextBackgroundColor = selection }
        tv.optionAsMetaKey = optionAsMeta
        if let ansi {
            tv.installColors(ansi.map { c in
                SwiftTerm.Color(red: UInt16(c.redComponent * 65535), green: UInt16(c.greenComponent * 65535),
                                blue: UInt16(c.blueComponent * 65535))
            })
        }
    }
}

/// Terminal menu actions. They act on the terminal you're typing in, or the selected session.
enum TerminalCommands {
    static var target: TerminalView? {
        if let tv = NSApp.keyWindow?.firstResponder as? TerminalView { return tv }
        if let store = SessionStore.shared, case .session(let id)? = store.selection {
            return store.sessions.first { $0.id == id }?.terminal
        }
        return nil
    }

    static func find(_ action: NSTextFinder.Action) {
        guard let tv = target else { return }
        let item = NSMenuItem(); item.tag = action.rawValue
        tv.window?.makeFirstResponder(tv)
        tv.performTextFinderAction(item)
    }

    /// Like Terminal's ⌘K: wipe the scrollback and screen, then let the program redraw (Ctrl-L).
    static func clear() {
        guard let tv = target else { return }
        tv.feed(text: "\u{1b}[3J\u{1b}[H\u{1b}[2J")
        tv.send(txt: "\u{0c}")
    }
}
