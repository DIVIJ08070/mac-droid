import SwiftUI

/// Full-window first-launch flow. Shown until "hasCompletedOnboarding" is set;
/// can be replayed from the main screen.
struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var page = 0

    private struct Page {
        let label: String
        let headingTop: String
        let headingBottom: String
        let body: String
        let icon: String
    }

    private let pages: [Page] = [
        Page(
            label: "Welcome",
            headingTop: "Your Mac.",
            headingBottom: "And Android.",
            body: "Clipboard, files, audio and remote input between your Mac and your phone — over your own Wi-Fi.\nNo cloud. No account. No wires.",
            icon: "laptopcomputer.and.iphone"
        ),
        Page(
            label: "Step 1 — The phone",
            headingTop: "One app",
            headingBottom: "on each side.",
            body: "Install Bifrost on your Android phone.\nThen connect the two any way you like: same Wi-Fi, the phone's hotspot, a USB cable, or Tailscale from anywhere.",
            icon: "wifi"
        ),
        Page(
            label: "Step 2 — Pairing",
            headingTop: "Pair once.",
            headingBottom: "Reconnect forever.",
            body: "Your phone will show this Mac in its list. Tap Connect — a 6-digit code appears on both screens. Click Accept here.\nOnly once. Reconnects are automatic.",
            icon: "link"
        ),
        Page(
            label: "Step 3 — Permissions",
            headingTop: "Grant once.",
            headingBottom: "Forget forever.",
            body: "Features ask for macOS permissions on first use — Accessibility for the trackpad, Screen & System Audio Recording for audio and screen.\nGrant once, forget forever.",
            icon: "lock.shield"
        ),
    ]

    private var isLastPage: Bool { page == pages.count - 1 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar: wordmark + skip.
                HStack {
                    Text("BIFROST")
                        .font(Theme.mono(11, .medium))
                        .tracking(4)
                        .foregroundStyle(Theme.faint)
                    Spacer()
                    Button("Skip") { onFinish() }
                        .buttonStyle(.plain)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)

                Spacer()

                pageContent(pages[page])
                    .id(page)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        )
                    )

                Spacer()

                // Page dots.
                HStack(spacing: 8) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        Circle()
                            .fill(Color.white.opacity(index == page ? 0.9 : 0.2))
                            .frame(width: 6, height: 6)
                            .animation(.easeOut(duration: 0.25), value: page)
                    }
                }
                .padding(.bottom, 24)

                // Navigation.
                HStack(spacing: 12) {
                    if page > 0 {
                        Button("Back") {
                            withAnimation(.easeOut(duration: 0.35)) { page -= 1 }
                        }
                        .buttonStyle(PillButtonStyle(kind: .secondary, size: 13))
                    }
                    Button(isLastPage ? "Get started" : "Continue") {
                        if isLastPage {
                            onFinish()
                        } else {
                            withAnimation(.easeOut(duration: 0.35)) { page += 1 }
                        }
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary, size: 13))
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.bottom, 36)
            }
        }
    }

    private func pageContent(_ item: Page) -> some View {
        VStack(spacing: 22) {
            Image(systemName: item.icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius + 4, style: .continuous)
                        .fill(Theme.cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius + 4, style: .continuous)
                        .strokeBorder(Theme.cardStroke, lineWidth: 1)
                )
                .riseIn(delay: 0.0)

            SectionLabel(item.label)
                .riseIn(delay: 0.1)

            VStack(spacing: 2) {
                Text(item.headingTop)
                Text(item.headingBottom)
            }
            .font(Theme.mono(34, .light))
            .tracking(-0.5)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .riseIn(delay: 0.2)

            Text(item.body)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
                .lineSpacing(6)
                .frame(maxWidth: 440)
                .riseIn(delay: 0.3)
        }
        .padding(.horizontal, 40)
    }
}
