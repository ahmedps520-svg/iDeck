import SwiftUI

/// iDeck visual language: deep black, charcoal surfaces, one restrained accent.
enum Theme {
    static let background = Color(red: 0.027, green: 0.027, blue: 0.035)      // #07070A
    static let surface = Color(red: 0.086, green: 0.090, blue: 0.106)         // #16171B
    static let surfaceRaised = Color(red: 0.122, green: 0.126, blue: 0.145)   // #1F2025
    static let stroke = Color.white.opacity(0.07)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.38)
    static let accent = Color(red: 0.36, green: 0.80, blue: 1.0)              // #5CCCFF
    static let accentDeep = Color(red: 0.18, green: 0.45, blue: 0.95)
    static let success = Color(red: 0.36, green: 0.86, blue: 0.56)
    static let warning = Color(red: 1.0, green: 0.74, blue: 0.30)
    static let danger = Color(red: 1.0, green: 0.38, blue: 0.40)

    static let corner: CGFloat = 18
    static let accentGradient = LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.stroke))
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(.title3, design: .rounded).weight(.semibold)).foregroundStyle(Theme.textPrimary)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(Theme.textSecondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatTile: View {
    var label: String
    var value: String
    var tint: Color = Theme.accent
    var detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(Theme.textTertiary)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit()).foregroundStyle(tint)
            if let detail { Text(detail).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke))
    }
}

struct StatusPill: View {
    var text: String
    var color: Color
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded).weight(.bold))
            .padding(.horizontal, 22).padding(.vertical, 14)
            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(.black)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke))
            .foregroundStyle(Theme.textPrimary)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Tiny line chart for live metrics.
struct Sparkline: View {
    var values: [Double]
    var maxValue: Double
    var color: Color = Theme.accent
    var body: some View {
        GeometryReader { geo in
            let pts = values.suffix(60)
            Path { p in
                guard pts.count > 1 else { return }
                let step = geo.size.width / CGFloat(max(1, pts.count - 1))
                for (i, v) in pts.enumerated() {
                    let x = CGFloat(i) * step
                    let y = geo.size.height * (1 - CGFloat(min(1, max(0, v / max(maxValue, 0.0001)))))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

extension RuntimeController.Phase {
    var label: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .stopped: return "Ready"
        case .needsJIT: return "JIT required"
        case .needsRelaunch: return "Restart iDeck"
        case .starting(let s), .booting(let s): return s
        case .running: return "Running"
        case .stopping: return "Shutting down"
        case .failed: return "Error"
        }
    }

    var color: Color {
        switch self {
        case .running: return Theme.success
        case .starting, .booting, .stopping: return Theme.accent
        case .failed, .needsJIT: return Theme.danger
        case .needsRelaunch: return Theme.warning
        default: return Theme.textSecondary
        }
    }
}
