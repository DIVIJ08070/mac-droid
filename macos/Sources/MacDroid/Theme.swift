import SwiftUI

// MARK: - Design language shared across the app.
// Pure black canvas, monospace type, translucent white cards, pill buttons.

enum Theme {
    static let cardFill = Color.white.opacity(0.07)
    static let cardStroke = Color.white.opacity(0.10)
    static let dim = Color.white.opacity(0.5)
    static let faint = Color.white.opacity(0.4)
    static let cornerRadius: CGFloat = 14

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Small uppercase section label with wide letter-spacing.

struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.mono(10))
            .tracking(3)
            .foregroundStyle(Theme.faint)
    }
}

// MARK: - Card container.

struct CardModifier: ViewModifier {
    var fillOpacity: Double = 0.07

    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(fillOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
    }
}

extension View {
    func card(fillOpacity: Double = 0.07) -> some View {
        modifier(CardModifier(fillOpacity: fillOpacity))
    }
}

// MARK: - Pill buttons. Primary: white pill, black text. Secondary: translucent.

struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }

    var kind: Kind = .secondary
    var size: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind, size: size)
    }

    private struct PillBody: View {
        let configuration: ButtonStyle.Configuration
        let kind: Kind
        let size: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Theme.mono(size, .medium))
                .foregroundStyle(kind == .primary ? Color.black : Color.white)
                .padding(.horizontal, size + 6)
                .padding(.vertical, size * 0.66)
                .background(
                    Capsule().fill(
                        kind == .primary
                            ? Color.white.opacity(hovering ? 0.85 : 1.0)
                            : Color.white.opacity(hovering ? 0.20 : 0.12)
                    )
                )
                .overlay(
                    Capsule().strokeBorder(
                        Color.white.opacity(kind == .primary ? 0 : 0.12),
                        lineWidth: 1
                    )
                )
                .scaleEffect(configuration.isPressed ? 0.96 : (hovering ? 1.02 : 1.0))
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Solid accent pill button (used for the marquee Desktop Mode action).

struct SolidButtonStyle: ButtonStyle {
    var fill: Color

    func makeBody(configuration: Configuration) -> some View {
        SolidBody(configuration: configuration, fill: fill)
    }

    private struct SolidBody: View {
        let configuration: ButtonStyle.Configuration
        let fill: Color
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Theme.mono(13, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Capsule().fill(fill.opacity(hovering ? 0.85 : 1.0)))
                .scaleEffect(configuration.isPressed ? 0.96 : (hovering ? 1.03 : 1.0))
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Ongoing-call control pill.
// Hang up is a red/destructive tint. Mute/Speaker highlight (filled green) when
// `active` reflects the phone's real reported state, so the pill mirrors the
// phone instead of an optimistic guess.

struct CallControlStyle: ButtonStyle {
    var active: Bool = false
    var destructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        CallBody(configuration: configuration, active: active, destructive: destructive)
    }

    private struct CallBody: View {
        let configuration: ButtonStyle.Configuration
        let active: Bool
        let destructive: Bool
        @State private var hovering = false

        private static let red = Color(red: 1.0, green: 0.35, blue: 0.35)
        private static let green = Color(red: 0.45, green: 0.95, blue: 0.6)

        private var fill: Color {
            if destructive { return Self.red.opacity(hovering ? 0.28 : 0.18) }
            if active { return Self.green.opacity(hovering ? 0.32 : 0.22) }
            return Color.white.opacity(hovering ? 0.20 : 0.12)
        }
        private var stroke: Color {
            if destructive { return Self.red.opacity(0.5) }
            if active { return Self.green.opacity(0.55) }
            return Color.white.opacity(0.12)
        }
        private var foreground: Color {
            if destructive { return Self.red }
            if active { return Self.green }
            return Color.white
        }

        var body: some View {
            configuration.label
                .font(Theme.mono(11, .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.96 : (hovering ? 1.02 : 1.0))
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .animation(.easeOut(duration: 0.15), value: active)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Entrance animation: fade + slide-up on appear, staggered by delay.

struct RiseIn: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 16)
            .onAppear {
                withAnimation(.easeOut(duration: 0.6).delay(delay)) { shown = true }
            }
    }
}

extension View {
    func riseIn(delay: Double = 0) -> some View {
        modifier(RiseIn(delay: delay))
    }
}

// MARK: - Pulsing status dot.

struct PulsingDot: View {
    var color: Color = .white
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.6), lineWidth: 1)
                    .scaleEffect(pulsing ? 2.8 : 1)
                    .opacity(pulsing ? 0 : 0.8)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    pulsing = true
                }
            }
    }
}
