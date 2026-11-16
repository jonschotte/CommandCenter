import SwiftUI

/// Shared look. Three color jobs, kept apart so they don't get confused:
///  • Status: the dot and card border (green working, orange needs you, blue your turn, gray idle).
///  • Group: the icon tile and the stripe on a card's left edge use the group's color.
///  • System: each meter has its own color, the same everywhere it appears.
enum Theme {
    static let cpu = Color(red: 0.2, green: 0.62, blue: 1.0)       // sky blue
    static let memory = Color(red: 0.62, green: 0.38, blue: 1.0)   // violet
    static let gpu = Color(red: 1.0, green: 0.38, blue: 0.6)       // pink
    static let storage = Color(red: 0.1, green: 0.78, blue: 0.68)  // teal
    static let network = Color(red: 1.0, green: 0.7, blue: 0.2)
    /// Icon color for terminals that aren't in a group.
    static let ungrouped = Color.indigo

    /// Group color for a terminal (its icon and card stripe).
    static func identity(_ key: String) -> Color { GroupStore.shared.group(for: key)?.color ?? ungrouped }

    static let groupColors: [Color] = [.purple, .blue, .teal, .green, .orange, .pink, .red, .indigo, .mint, .yellow]
    static let groupColorNames = ["Purple", "Blue", "Teal", "Green", "Orange", "Pink", "Red", "Indigo", "Mint", "Yellow"]

    /// Icons are neutral: color is reserved for status (see SessionActivity.color).
    static func kindColor(_ k: AgentKind) -> Color { Color(nsColor: .systemGray) }

    /// Meter color: neutral, red when nearly full.
    static func level(_ v: Double, base: Color) -> Color { v > 0.9 ? .red : base }
}

/// A status dot that breathes while something is happening. The ring animation runs in Core Animation
/// (the window server), so it costs the app no CPU, unlike a SwiftUI repeatForever animation.
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 8
    var animating = true
    var body: some View {
        ZStack {
            if animating { PulseRing(color: NSColor(color), size: size).frame(width: size * 3, height: size * 3) }
            Circle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

private struct PulseRing: NSViewRepresentable {
    let color: NSColor
    let size: CGFloat
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let ring = CALayer()
        ring.name = "ring"
        v.layer?.addSublayer(ring)
        configure(ring)
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        if let ring = v.layer?.sublayers?.first(where: { $0.name == "ring" }) { configure(ring) }
    }
    private func configure(_ ring: CALayer) {
        let box = size * 3
        ring.frame = CGRect(x: (box - size) / 2, y: (box - size) / 2, width: size, height: size)
        ring.cornerRadius = size / 2
        ring.backgroundColor = color.withAlphaComponent(0.5).cgColor
        guard ring.animation(forKey: "pulse") == nil else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 1; scale.toValue = 2.6
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.8; fade.toValue = 0
        let g = CAAnimationGroup(); g.animations = [scale, fade]; g.duration = 1.4
        g.timingFunction = CAMediaTimingFunction(name: .easeOut); g.repeatCount = .infinity
        g.isRemovedOnCompletion = false
        ring.add(g, forKey: "pulse")
    }
}

struct ActivityDot: View {
    let activity: SessionActivity
    var size: CGFloat = 8
    var body: some View {
        PulsingDot(color: activity.color, size: size, animating: activity == .working || activity == .needsYou)
            .id(activity.label) // restart the animation when the state changes
    }
}

/// Rounded icon tile with a gradient fill.
struct IconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28).fill(color.gradient))
            .shadow(color: color.opacity(0.35), radius: 4, y: 2)
    }
}

/// Card with a soft tinted glow; used across the dashboard.
struct GlowCard: ViewModifier {
    var tint: Color = .accentColor
    var highlighted = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [tint.opacity(0.12), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)))
            )
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(
                LinearGradient(colors: [tint.opacity(highlighted ? 0.9 : 0.45), tint.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: highlighted ? 1.5 : 1))
            .shadow(color: tint.opacity(highlighted ? 0.35 : 0.12), radius: highlighted ? 12 : 6, y: 3)
    }
}

extension View {
    func glowCard(_ tint: Color = .accentColor, highlighted: Bool = false) -> some View {
        modifier(GlowCard(tint: tint, highlighted: highlighted))
    }
}

/// Circular gauge for the hero stats.
struct RingGauge: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 7
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle().trim(from: 0, to: min(max(fraction, 0.001), 1))
                .stroke(AngularGradient(colors: [color.opacity(0.6), color], center: .center), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.5), radius: 4)
        }
    }
}
