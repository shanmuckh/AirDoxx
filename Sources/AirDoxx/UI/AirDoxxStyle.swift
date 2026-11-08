import SwiftUI

enum AirDoxxColor {
    static let accent = Color(red: 0.22, green: 0.80, blue: 0.40)        // iPhone-Mirroring-style green
    static let accentDeep = Color(red: 0.10, green: 0.60, blue: 0.45)
    static let windowBackground = Color(red: 0.13, green: 0.13, blue: 0.14)
    static let secondaryButton = Color(white: 0.24)
}

/// Slowly drifting, heavily blurred colour fields: the "connecting" backdrop in the phone window.
struct AuroraBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    Color(red: 0.10, green: 0.10, blue: 0.16)
                    blob(Color(red: 0.24, green: 0.25, blue: 0.42), w * 1.1, x: w * (0.15 + 0.10 * sin(t * 0.21)), y: h * (0.18 + 0.06 * cos(t * 0.17)))
                    blob(Color(red: 0.07, green: 0.08, blue: 0.13), w * 1.2, x: w * (0.80 + 0.08 * cos(t * 0.15)), y: h * (0.45 + 0.08 * sin(t * 0.19)))
                    blob(Color(red: 0.20, green: 0.22, blue: 0.40), w * 0.9, x: w * (0.60 + 0.12 * sin(t * 0.13 + 1)), y: h * (0.68 + 0.05 * cos(t * 0.23)))
                    blob(Color(red: 0.05, green: 0.07, blue: 0.14), w * 1.0, x: w * (0.25 + 0.10 * cos(t * 0.18 + 2)), y: h * (0.88 + 0.04 * sin(t * 0.2)))
                    blob(Color(red: 0.24, green: 0.32, blue: 0.48), w * 0.7, x: w * (0.95 + 0.05 * sin(t * 0.25)), y: h * (0.95 + 0.03 * cos(t * 0.3)))
                }
                .blur(radius: w * 0.16)
                .frame(width: w, height: h)
                .clipped()
            }
        }
    }

    private func blob(_ color: Color, _ size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Ellipse()
            .fill(color)
            .frame(width: size, height: size * 0.55)
            .rotationEffect(.degrees(-28))
            .position(x: x, y: y)
    }
}

struct PrimaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            .frame(minWidth: 116)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.88, blue: 0.52),
                                                  Color(red: 0.13, green: 0.70, blue: 0.47)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05)],
                                                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    .shadow(color: AirDoxxColor.accent.opacity(configuration.isPressed ? 0.2 : 0.45), radius: 14, y: 4)
            )
            .brightness(configuration.isPressed ? -0.08 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

struct SecondaryPillButtonStyle: ButtonStyle {
    var outlined = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .frame(minWidth: 116)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(.white.opacity(configuration.isPressed ? 0.14 : 0.07)))
                    .overlay(Capsule().strokeBorder(
                        outlined ? AnyShapeStyle(AirDoxxColor.accent.opacity(0.75))
                                 : AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)],
                                                                startPoint: .top, endPoint: .bottom)),
                        lineWidth: outlined ? 2 : 1))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Frosted-glass surface with a light-catching edge, used for cards and rows.
struct GlassCard: ViewModifier {
    var radius: CGFloat = 20
    var highlighted = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.08), .white.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(highlighted
                                  ? AnyShapeStyle(AirDoxxColor.accent.opacity(0.6))
                                  : AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)],
                                                                 startPoint: .top, endPoint: .bottom)),
                                  lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
    }
}

extension View {
    func glassCard(radius: CGFloat = 20, highlighted: Bool = false) -> some View {
        modifier(GlassCard(radius: radius, highlighted: highlighted))
    }
}

/// Soft drifting glow behind the hub window's content.
struct HubGlow: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    Circle().fill(AirDoxxColor.accent.opacity(0.22))
                        .frame(width: w * 0.7).position(x: w * (0.3 + 0.08 * sin(t * 0.2)), y: h * (0.12 + 0.05 * cos(t * 0.17)))
                    Circle().fill(Color(red: 0.25, green: 0.45, blue: 1.0).opacity(0.16))
                        .frame(width: w * 0.6).position(x: w * (0.8 + 0.06 * cos(t * 0.15)), y: h * (0.3 + 0.06 * sin(t * 0.21)))
                    Circle().fill(Color(red: 0.6, green: 0.35, blue: 1.0).opacity(0.10))
                        .frame(width: w * 0.5).position(x: w * (0.5 + 0.1 * sin(t * 0.12 + 1)), y: h * (0.95 + 0.04 * cos(t * 0.2)))
                }
                .blur(radius: 90)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Small grey spinner like macOS's indeterminate progress indicator, drawn so it can be tinted.
struct SpokeSpinner: View {
    var size: CGFloat = 26
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { timeline in
            let step = Int(timeline.date.timeIntervalSinceReferenceDate * 12) % 8
            ZStack {
                ForEach(0..<8, id: \.self) { i in
                    Capsule()
                        .fill(Color.white.opacity(0.18 + 0.6 * Double((i - step + 8) % 8) / 7.0))
                        .frame(width: size * 0.11, height: size * 0.3)
                        .offset(y: -size * 0.32)
                        .rotationEffect(.degrees(Double(i) * 45))
                }
            }
            .frame(width: size, height: size)
        }
    }
}
