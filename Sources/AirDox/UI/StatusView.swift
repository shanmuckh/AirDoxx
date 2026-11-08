import SwiftUI

/// The screen shown inside the phone outline while not mirroring
/// (searching, authorizing, choosing a phone, connecting, errors).
struct StatusView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.13), Color(white: 0.05)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 18) {
                Spacer()
                icon
                content
                Spacer()
                footer
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 30)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder private var icon: some View {
        switch model.state {
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.orange)
        case .unauthorized:
            Image(systemName: "lock.iphone")
                .font(.system(size: 54, weight: .light))
        default:
            Image(systemName: "smartphone")
                .font(.system(size: 54, weight: .light))
                .symbolEffect(.pulse, options: .repeating, isActive: isWaiting)
        }
    }

    private var isWaiting: Bool {
        switch model.state {
        case .searching, .connecting: return true
        default: return false
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .missingADB:
            title("Android tools needed")
            bodyText("AirDox needs adb to talk to your phone. Install it with Homebrew:")
            code("brew install --cask android-platform-tools")
            Button("Try Again") { model.retry() }.buttonStyle(PillButtonStyle())

        case .missingServer:
            title("Mirroring component missing")
            bodyText("The scrcpy server could not be found. Rebuild the app with scripts/build_app.sh, or install it with:")
            code("brew install scrcpy")
            Button("Try Again") { model.retry() }.buttonStyle(PillButtonStyle())

        case .searching:
            title("AirDox")
            bodyText("Connect your Android phone with a USB cable and turn on USB debugging.")
            ProgressView().controlSize(.small).tint(.white).padding(.top, 4)

        case .unauthorized(let name):
            title("Allow on your phone")
            bodyText("Unlock \(name) and tap Allow on the “Allow USB debugging?” prompt. Tick “Always allow from this computer” to skip this next time.")
            ProgressView().controlSize(.small).tint(.white)

        case .choose(let devices):
            title("Choose a phone")
            VStack(spacing: 8) {
                ForEach(devices) { device in
                    Button {
                        model.connect(device)
                    } label: {
                        HStack {
                            Image(systemName: device.isWireless ? "wifi" : "cable.connector")
                            Text(device.displayName).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").opacity(0.5)
                        }
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }

        case .connecting(let name):
            title("Connecting to \(name)…")
            ProgressView().controlSize(.small).tint(.white)

        case .mirroring:
            EmptyView()

        case .failed(let headline, let detail):
            title(headline)
            if !detail.isEmpty {
                ScrollView {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
            }
            Button("Try Again") { model.retry() }.buttonStyle(PillButtonStyle())
        }
    }

    @ViewBuilder private var footer: some View {
        switch model.state {
        case .searching, .choose, .failed:
            VStack(spacing: 10) {
                Button("Connect Wirelessly…") { model.showWirelessSheet() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Button("How to turn on USB debugging") { model.showUSBDebuggingHelp() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
        default:
            EmptyView()
        }
    }

    private func title(_ s: String) -> some View {
        Text(s).font(.system(size: 19, weight: .semibold))
    }

    private func bodyText(_ s: String) -> some View {
        Text(s).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func code(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11, design: .monospaced))
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1)))
            .textSelection(.enabled)
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.accentColor.opacity(configuration.isPressed ? 0.7 : 1)))
            .foregroundStyle(.white)
    }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(configuration.isPressed ? 0.2 : 0.1)))
            .contentShape(Rectangle())
    }
}
