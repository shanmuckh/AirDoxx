import SwiftUI

/// What the phone-shaped window shows while it isn't mirroring: the drifting blurred backdrop with
/// a small spinner (like iPhone Mirroring), plus short prompts when the phone needs attention.
struct StatusView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            AuroraBackground()
            content
                .padding(.horizontal, 26)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .unauthorized(let name):
            VStack(spacing: 14) {
                Image(systemName: "lock.iphone").font(.system(size: 40, weight: .light)).opacity(0.85)
                Text("Allow on \(name)").font(.system(size: 17, weight: .semibold))
                Text("Unlock your phone and tap Allow on “Allow USB debugging?”. Tick “Always allow from this computer”.")
                    .font(.system(size: 13)).opacity(0.65)
                SpokeSpinner(size: 20).padding(.top, 6)
            }
            .transition(.opacity)

        case .choose(let devices):
            VStack(spacing: 10) {
                Text("Choose a Phone").font(.system(size: 17, weight: .semibold)).padding(.bottom, 6)
                ForEach(devices) { device in
                    Button { model.connect(device) } label: {
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
            .transition(.opacity)

        case .connecting(let name):
            VStack(spacing: 16) {
                SpokeSpinner()
                Text(name).font(.system(size: 12, weight: .medium)).opacity(0.45)
            }

        default:
            SpokeSpinner()
        }
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
