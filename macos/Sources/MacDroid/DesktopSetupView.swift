import SwiftUI

/// Step-by-step Desktop Mode setup with live status checks: the desktop engine
/// (scrcpy), Wireless debugging on the phone, and one-time ADB pairing — all
/// doable without leaving the app.
struct DesktopSetupView: View {
    @ObservedObject var server: ServerManager
    @Environment(\.dismiss) private var dismiss
    @State private var pairCode = ""

    private let accent = Color(red: 0.49, green: 0.42, blue: 1.0)
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var allReady: Bool { server.setupScrcpyReady && server.setupPhoneReady }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 14))
                    .foregroundStyle(accent)
                Text("DESKTOP MODE SETUP")
                    .font(Theme.mono(12, .semibold))
                    .tracking(3)
                    .foregroundStyle(.white)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(PillButtonStyle(kind: .secondary, size: 11))
            }

            Text("Two minutes, one time. After this, “Open Desktop” just works.")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.dim)

            step(number: "01", title: "Desktop engine", done: server.setupScrcpyReady) {
                if server.setupScrcpyReady {
                    doneLine("scrcpy is installed.")
                } else {
                    Text("Bifrost renders the desktop with scrcpy (free, open source).")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.dim)
                    Button {
                        server.installDesktopEngine()
                    } label: {
                        HStack(spacing: 6) {
                            if server.desktopStarting {
                                ProgressView().controlSize(.small)
                                Text("Installing — a few minutes…")
                            } else {
                                Image(systemName: "arrow.down.circle")
                                Text("Install automatically")
                            }
                        }
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary, size: 12))
                    .disabled(server.desktopStarting)
                }
            }

            step(number: "02", title: "Wireless debugging on the phone", done: server.setupPhoneReady) {
                if server.setupPhoneReady {
                    doneLine("Phone reachable over ADB.")
                } else {
                    bullet("Settings → About phone → Software information → tap “Build number” 7 times (skip if you already see Developer options)")
                    bullet("Settings → Developer options → turn ON “Wireless debugging” — same Wi-Fi or the phone's hotspot. With a USB cable, plain “USB debugging” is enough.")
                }
            }

            step(number: "03", title: "Pair this Mac — first time only", done: server.setupPhoneReady) {
                if server.setupPhoneReady {
                    doneLine("Paired and connected.")
                } else if server.setupPairingEndpoint != nil {
                    Text("Phone found ✓ — type the 6-digit code from the phone's pairing dialog:")
                        .font(Theme.mono(11))
                        .foregroundStyle(.white)
                    HStack(spacing: 8) {
                        TextField("000000", text: $pairCode)
                            .textFieldStyle(.plain)
                            .font(Theme.mono(16))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(width: 110)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)))
                        Button(server.setupPairing ? "Pairing…" : "Pair") {
                            server.pairPhone(code: pairCode.trimmingCharacters(in: .whitespaces))
                        }
                        .buttonStyle(PillButtonStyle(kind: .primary, size: 12))
                        .disabled(server.setupPairing || pairCode.trimmingCharacters(in: .whitespaces).count < 6)
                    }
                } else {
                    HStack(spacing: 8) {
                        PulsingDot(color: .white)
                        Text("On the phone: Wireless debugging → “Pair device with pairing code”. Bifrost will spot it automatically…")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let message = server.setupMessage {
                    Text(message)
                        .font(Theme.mono(11))
                        .foregroundStyle(message.contains("✓") ? Color(red: 0.45, green: 0.95, blue: 0.6) : Theme.dim)
                }
            }

            Button {
                server.launchDesktopMode()
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.forward.app")
                    Text(allReady ? "Open Desktop" : "Complete the steps above first")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SolidButtonStyle(fill: accent))
            .disabled(!allReady)
        }
        .padding(24)
        .frame(width: 540)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear { server.refreshDesktopSetup() }
        .onReceive(refresh) { _ in server.refreshDesktopSetup() }
    }

    // MARK: bits

    @ViewBuilder
    private func step<Content: View>(
        number: String, title: String, done: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 0.45, green: 0.95, blue: 0.6))
                } else {
                    Text(number)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.faint)
                }
                Text(title.uppercased())
                    .font(Theme.mono(10, .semibold))
                    .tracking(2)
                    .foregroundStyle(done ? Theme.dim : .white)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card(fillOpacity: done ? 0.03 : 0.07)
    }

    private func doneLine(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.dim)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("·").font(Theme.mono(11)).foregroundStyle(Theme.faint)
            Text(text)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.dim)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
