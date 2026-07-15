import SwiftUI

/// Launch splash: the Bifrost bridge-arc draws itself across the void, two
/// endpoints (Mac ↔ phone) spark to life, and the wordmark rises in — then it
/// cross-fades into the app. Norse "Bifröst" = the rainbow bridge between worlds.
struct SplashView: View {
    var onFinished: () -> Void

    @State private var arc: CGFloat = 0
    @State private var endpointsLit = false
    @State private var wordmark = false
    @State private var glow = false
    @State private var fadeOut = false

    private let bridge = Gradient(colors: [
        Color(red: 0.36, green: 0.32, blue: 1.0),
        Color(red: 0.55, green: 0.40, blue: 1.0),
        Color(red: 0.35, green: 0.75, blue: 1.0),
        Color(red: 0.30, green: 0.90, blue: 0.80),
    ])

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            RadialGradient(
                colors: [Color(red: 0.49, green: 0.42, blue: 1.0).opacity(glow ? 0.30 : 0.06), .clear],
                center: .center, startRadius: 2, endRadius: 360
            )
            .blendMode(.screen)
            .ignoresSafeArea()

            VStack(spacing: 40) {
                ZStack {
                    BridgeArc()
                        .trim(from: 0, to: arc)
                        .stroke(
                            LinearGradient(gradient: bridge, startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .shadow(color: Color(red: 0.5, green: 0.5, blue: 1.0).opacity(0.7), radius: 12)
                    endpoint(at: .leading)
                    endpoint(at: .trailing)
                }
                .frame(width: 260, height: 130)

                HStack(spacing: 3) {
                    ForEach(Array("BIFROST".enumerated()), id: \.offset) { index, char in
                        Text(String(char))
                            .font(.system(size: 30, weight: .light, design: .monospaced))
                            .tracking(6)
                            .foregroundStyle(.white)
                            .opacity(wordmark ? 1 : 0)
                            .offset(y: wordmark ? 0 : 8)
                            .animation(.easeOut(duration: 0.5).delay(Double(index) * 0.06), value: wordmark)
                    }
                }
                .padding(.leading, 6)
            }
        }
        .opacity(fadeOut ? 0 : 1)
        .onAppear(perform: run)
    }

    private func endpoint(at edge: HorizontalAlignment) -> some View {
        // Dots sit at the two ends of the arc's baseline.
        GeometryReader { geo in
            Circle()
                .fill(.white)
                .frame(width: 9, height: 9)
                .shadow(color: Color(red: 0.5, green: 0.6, blue: 1.0), radius: endpointsLit ? 8 : 0)
                .opacity(endpointsLit ? 1 : 0)
                .scaleEffect(endpointsLit ? 1 : 0.3)
                .position(
                    x: edge == .leading ? 2 : geo.size.width - 2,
                    y: geo.size.height - 2
                )
        }
    }

    private func run() {
        // Let the repeating animation own the false→true change so it actually pulses.
        withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { glow = true }
        withAnimation(.easeInOut(duration: 1.15)) { arc = 1 }
        withAnimation(.easeOut(duration: 0.5).delay(0.95)) { endpointsLit = true }
        wordmark = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeInOut(duration: 0.55)) { fadeOut = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { onFinished() }
        }
    }
}

/// A gentle arch — the rainbow bridge — spanning left to right.
private struct BridgeArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: rect.minX, y: rect.maxY)
        let end = CGPoint(x: rect.maxX, y: rect.maxY)
        let control = CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.15)
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }
}
