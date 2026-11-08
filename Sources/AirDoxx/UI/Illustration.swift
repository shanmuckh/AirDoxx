import SwiftUI

/// MacBook showing the AirDoxx phone window, next to an Android phone on its lock screen.
/// `beam` animates little packets flowing from the phone to the Mac.
struct MirrorIllustration: View {
    var beam = false
    var phoneUnlocked = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                HStack(alignment: .center, spacing: 52) {
                    MacBookDrawing(t: t)
                        .frame(width: 452, height: 268)
                    AndroidPhoneDrawing(t: t, unlocked: phoneUnlocked)
                        .frame(width: 104, height: 206)
                        .offset(y: -22 + 3 * sin(t * 1.2))
                }
                if beam {
                    BeamDots(t: t)
                        .frame(width: 70, height: 40)
                        .offset(x: 252, y: -36)
                }
            }
        }
    }
}

private struct BeamDots: View {
    let t: Double
    var body: some View {
        ZStack {
            ForEach(0..<5, id: \.self) { i in
                let p = (t * 0.6 + Double(i) / 5).truncatingRemainder(dividingBy: 1)
                Circle()
                    .fill(AirDoxxColor.accent)
                    .frame(width: 7, height: 7)
                    .shadow(color: AirDoxxColor.accent, radius: 6)
                    .opacity(sin(p * .pi))
                    .offset(x: 38 - 76 * p, y: -10 * sin(p * .pi))
            }
        }
    }
}

private struct MacBookDrawing: View {
    let t: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let screenW = w * 0.83, screenH = h * 0.92
            ZStack(alignment: .top) {
                // Lid + display
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(white: 0.06))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(white: 0.42), lineWidth: 2))
                    .frame(width: screenW, height: screenH)
                desktop(width: screenW - 18, height: screenH - 16)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.top, 9)
                // notch
                UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5)
                    .fill(Color(white: 0.06))
                    .frame(width: 44, height: 9)
                    .padding(.top, 9)
                // Base
                VStack(spacing: 0) {
                    Spacer()
                    ZStack(alignment: .top) {
                        UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12)
                            .fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.40)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: w, height: h * 0.085)
                        UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                            .fill(Color(white: 0.30))
                            .frame(width: w * 0.15, height: h * 0.025)
                    }
                }
            }
            .frame(width: w, height: h)
        }
    }

    private func desktop(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.30, green: 0.27, blue: 0.62),
                                    Color(red: 0.52, green: 0.29, blue: 0.55),
                                    Color(red: 0.72, green: 0.38, blue: 0.62)],
                           startPoint: .top, endPoint: .bottom)
            // menu bar
            HStack(spacing: 5) {
                ForEach([6, 12, 10, 8, 6, 16, 8], id: \.self) { len in
                    Capsule().fill(.white.opacity(0.75)).frame(width: CGFloat(len), height: 3)
                }
                Spacer()
                ForEach([10, 4, 4, 4, 10, 12], id: \.self) { len in
                    Capsule().fill(.white.opacity(0.75)).frame(width: CGFloat(len), height: 3)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            // a document window
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(red: 0.23, green: 0.15, blue: 0.33).opacity(0.85))
                .frame(width: width * 0.5, height: height * 0.43)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.05)).frame(width: width * 0.11)
                }
                .offset(x: -width * 0.05, y: height * 0.21)
            // the AirDoxx phone window
            PhoneScreenMini(t: t)
                .frame(width: width * 0.175, height: height * 0.66)
                .offset(x: width * 0.215, y: height * 0.14)
            // dock
            HStack(spacing: 5) {
                ForEach(0..<12, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(i == 7 ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.36, green: 0.94, blue: 0.66),
                                                                              Color(red: 0.05, green: 0.55, blue: 0.53)],
                                                                     startPoint: .top, endPoint: .bottom))
                                     : AnyShapeStyle(Color.white.opacity(0.16)))
                        .frame(width: 19, height: 19)
                        .overlay {
                            if i == 7 {
                                RoundedRectangle(cornerRadius: 2).stroke(.white, lineWidth: 1.4).frame(width: 7, height: 11)
                            }
                        }
                }
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.18)))
            .offset(y: height - 38)
            // cursor clicking the AirDoxx icon
            Image(systemName: "cursorarrow")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.black)
                .background(Image(systemName: "cursorarrow").font(.system(size: 17, weight: .black)).foregroundStyle(.white))
                .offset(x: width * 0.075 + 2 * sin(t * 2), y: height - 22 + 2 * cos(t * 2))
        }
        .frame(width: width, height: height)
    }
}

/// Tiny Android home screen shown inside the Mac's AirDoxx window.
private struct PhoneScreenMini: View {
    let t: Double
    private let palette: [Color] = [.green, .white, .yellow, Color(white: 0.85), .blue, Color(white: 0.3),
                                    .mint, .cyan, .orange, .white, .red, .indigo, .purple, .blue, .teal,
                                    .orange, .pink, .yellow, .green, .white]
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.95, green: 0.77, blue: 0.55),
                                        Color(red: 0.88, green: 0.45, blue: 0.62)],
                               startPoint: .top, endPoint: .bottom)
                VStack(spacing: w * 0.07) {
                    Circle().fill(.black.opacity(0.7)).frame(width: w * 0.06).padding(.top, w * 0.05)
                    ForEach(0..<5, id: \.self) { row in
                        HStack(spacing: w * 0.07) {
                            ForEach(0..<4, id: \.self) { col in
                                let i = row * 4 + col
                                RoundedRectangle(cornerRadius: w * 0.04, style: .continuous)
                                    .fill(palette[i])
                                    .frame(width: w * 0.16, height: w * 0.16)
                                    .scaleEffect(1 + 0.08 * max(0, sin(t * 2 - Double(i) * 0.35)))
                            }
                        }
                    }
                    Spacer()
                    HStack(spacing: w * 0.07) {
                        ForEach([Color.green, .blue, .green, .white], id: \.self) { c in
                            RoundedRectangle(cornerRadius: w * 0.04, style: .continuous).fill(c)
                                .frame(width: w * 0.16, height: w * 0.16)
                        }
                    }
                    .padding(w * 0.04)
                    .background(RoundedRectangle(cornerRadius: w * 0.08, style: .continuous).fill(.white.opacity(0.3)))
                    .padding(.bottom, w * 0.06)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: w * 0.12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: w * 0.12, style: .continuous).strokeBorder(.black.opacity(0.25), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        }
    }
}

/// An Android phone on its lock screen (time + date).
private struct AndroidPhoneDrawing: View {
    let t: Double
    let unlocked: Bool
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: w * 0.17, style: .continuous)
                    .fill(Color(white: 0.05))
                LinearGradient(colors: [Color(red: 0.12, green: 0.45, blue: 0.40),
                                        Color(red: 0.13, green: 0.25, blue: 0.33),
                                        Color(red: 0.25, green: 0.17, blue: 0.30)],
                               startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: w * 0.14, style: .continuous))
                    .padding(w * 0.045)
                Circle().fill(.black).frame(width: w * 0.08).padding(.top, w * 0.09)
                VStack(spacing: 2) {
                    Text(Date(), format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                        .font(.system(size: w * 0.27, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                    Text(Date(), format: .dateTime.weekday(.wide).day().month(.abbreviated))
                        .font(.system(size: w * 0.075, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.top, w * 0.3)
                VStack {
                    Spacer()
                    Image(systemName: unlocked ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: w * 0.1))
                        .foregroundStyle(.white.opacity(0.55))
                    Capsule().fill(.white.opacity(0.6)).frame(width: w * 0.32, height: 3)
                        .padding(.bottom, w * 0.08)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: w * 0.17, style: .continuous)
                .strokeBorder(Color(white: 0.35), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
        }
    }
}
