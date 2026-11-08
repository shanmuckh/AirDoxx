import AppKit
import SwiftUI

/// State for the wide AirDoxx window: first-run setup pages and the "Unable to Connect" page.
final class HubModel: ObservableObject {
    enum Page: Int, Comparable {
        case welcome, permissions, phoneSetup, connect, unavailable, disconnected
        static func < (a: Page, b: Page) -> Bool { a.rawValue < b.rawValue }
    }

    @Published var page: Page = .welcome
    @Published var forward = true
    @Published var keysAllowed = MacKeyInterceptor.hasPermission
    @Published var notificationsAllowed = false
    @Published var qrImage: NSImage?
    @Published var pairingStatus = "Waiting for your phone to scan…"
    @Published var unavailableDetail = ""

    let app: AppModel
    private var pairing: WirelessPairing?
    private var permissionTimer: Timer?

    init(app: AppModel) {
        self.app = app
        NotificationBridge.permissionStatus { [weak self] ok in self?.notificationsAllowed = ok }
    }

    func go(_ page: Page) {
        forward = page > self.page
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { self.page = page }
        if page == .permissions { startPermissionWatch() } else { permissionTimer?.invalidate() }
        if page == .connect { startPairing() } else { stopPairing() }
    }

    // MARK: Permissions (asked here, inside the app, instead of hunting through System Settings)

    func allowKeys() {
        MacKeyInterceptor.requestPermission()
        startPermissionWatch()
    }

    func allowNotifications() {
        NotificationBridge.requestPermission { [weak self] ok in
            withAnimation { self?.notificationsAllowed = ok }
            if !ok, let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func startPermissionWatch() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let keys = MacKeyInterceptor.hasPermission
            if keys != self.keysAllowed { withAnimation { self.keysAllowed = keys } }
            NotificationBridge.permissionStatus { ok in
                if ok != self.notificationsAllowed { withAnimation { self.notificationsAllowed = ok } }
            }
        }
    }

    // MARK: Wireless pairing (QR)

    private func startPairing() {
        let p = WirelessPairing()
        p.onStatus = { [weak self] text in withAnimation { self?.pairingStatus = text } }
        p.onPaired = { [weak self] _ in
            withAnimation { self?.pairingStatus = "Paired! Your phone will now connect automatically." }
        }
        pairing = p
        qrImage = p.qrImage(size: 360)
        pairingStatus = "Waiting for your phone to scan…"
        p.start()
    }

    private func stopPairing() {
        pairing?.stop()
        pairing = nil
    }
}

final class HubWindowController: NSWindowController, NSWindowDelegate {
    let model: HubModel

    init(app: AppModel) {
        model = HubModel(app: app)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.title = "AirDoxx"
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        // Real frosted glass: the desktop blurs through behind the content.
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        let host = NSHostingView(rootView: HubView(model: model, app: app))
        host.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            host.topAnchor.constraint(equalTo: glass.topAnchor),
            host.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        window.contentView = glass
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(page: HubModel.Page, detail: String = "") {
        model.unavailableDetail = detail
        if window?.isVisible != true {
            model.page = page
            model.go(page)
        } else if model.page != page {
            model.go(page)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
    }
}

// MARK: - Views

struct HubView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var app: AppModel

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black.opacity(0.35), Color.black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            HubGlow().ignoresSafeArea()
            if model.page <= .connect {
                StepDots(current: model.page.rawValue, count: 4)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 16)
            }
            Group {
                switch model.page {
                case .welcome: WelcomePage(model: model)
                case .permissions: PermissionsPage(model: model)
                case .phoneSetup: PhoneSetupPage(model: model)
                case .connect: ConnectPage(model: model, app: app)
                case .unavailable: UnavailablePage(model: model)
                case .disconnected: DisconnectedPage(model: model)
                }
            }
            .id(model.page)
            .transition(.asymmetric(
                insertion: .move(edge: model.forward ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: model.forward ? .leading : .trailing).combined(with: .opacity)))
        }
        .frame(width: 760, height: 640)
        .preferredColorScheme(.dark)
    }
}

/// Shared layout: art on top, a text block, and a bottom button row (iPhone Mirroring style).
private struct HubPage<Art: View, Body: View, Leading: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var art: Art
    @ViewBuilder var content: Body
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            art
                .frame(height: 330)
                .padding(.top, 40)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(.white)
                content
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 430, alignment: .leading)
            .padding(.top, 34)
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                leading
                Spacer()
                trailing
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
    }
}

private struct WelcomePage: View {
    @ObservedObject var model: HubModel
    var body: some View {
        HubPage(title: "Welcome to AirDoxx") {
            MirrorIllustration(beam: true, phoneUnlocked: true)
        } content: {
            Text("Use your Android phone right from your Mac. See its screen, hear its sound, get its notifications, and control it with your keyboard and trackpad.")
        } leading: {
            Button("Learn More…") { model.app.learnMore() }.buttonStyle(SecondaryPillButtonStyle(outlined: true))
        } trailing: {
            Button("Continue") { model.go(.permissions) }.buttonStyle(PrimaryPillButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct PermissionsPage: View {
    @ObservedObject var model: HubModel
    var body: some View {
        HubPage(title: "Allow AirDoxx on This Mac") {
            VStack(spacing: 14) {
                PermissionRow(symbol: "keyboard", title: "Keyboard & Control Keys",
                              detail: "Type on your phone, and send volume, brightness, media and search keys to it.",
                              granted: model.keysAllowed, action: model.allowKeys)
                PermissionRow(symbol: "bell.badge", title: "Notifications",
                              detail: "Show your phone's notifications on this Mac.",
                              granted: model.notificationsAllowed, action: model.allowNotifications)
            }
            .frame(width: 560)
            .padding(.top, 50)
        } content: {
            Text("macOS asks once. For keyboard keys, switch AirDoxx on in the panel that opens, then come back – it updates by itself.")
        } leading: {
            Button("Back") { model.go(.welcome) }.buttonStyle(SecondaryPillButtonStyle())
        } trailing: {
            Button("Continue") { model.go(.phoneSetup) }.buttonStyle(PrimaryPillButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(AirDoxxColor.accent)
                .frame(width: 46, height: 46)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [AirDoxxColor.accent.opacity(0.25), AirDoxxColor.accent.opacity(0.08)],
                                     startPoint: .top, endPoint: .bottom)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text(detail).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AirDoxxColor.accent)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("Allow", action: action)
                    .buttonStyle(PrimaryPillButtonStyle())
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(16)
        .glassCard(radius: 18, highlighted: granted)
    }
}

private struct PhoneSetupPage: View {
    @ObservedObject var model: HubModel
    private let steps: [(String, String)] = [
        ("gearshape", "Open Settings › About phone and tap Build number 7 times."),
        ("hammer", "Go to Settings › Developer options."),
        ("cable.connector", "Turn on USB debugging. On Xiaomi, also turn on USB debugging (Security settings)."),
        ("wifi", "Optional: turn on Wireless debugging to pair over Wi-Fi."),
    ]
    var body: some View {
        HubPage(title: "Turn On Developer Options") {
            TimelineView(.animation(minimumInterval: 1.0 / 10.0)) { timeline in
                let active = Int(timeline.date.timeIntervalSinceReferenceDate / 1.6) % steps.count
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(spacing: 14) {
                            ZStack {
                                Circle().fill(index == active ? AirDoxxColor.accent : .white.opacity(0.08))
                                Text("\(index + 1)").font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(index == active ? .black : .white.opacity(0.7))
                            }
                            .frame(width: 30, height: 30)
                            Image(systemName: step.0).frame(width: 22).foregroundStyle(.white.opacity(0.7))
                            Text(step.1).font(.system(size: 14)).foregroundStyle(.white.opacity(index == active ? 1 : 0.6))
                            Spacer()
                        }
                        .padding(12)
                        .glassCard(radius: 14, highlighted: index == active)
                        .scaleEffect(index == active ? 1.02 : 1)
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: active)
                    }
                }
                .frame(width: 580)
                .padding(.top, 28)
            }
        } content: {
            Text("AirDoxx talks to your phone through Android's developer connection. You only need to do this once.")
        } leading: {
            Button("Learn More…") { NSWorkspace.shared.open(AirDoxxLinks.setupGuide) }
                .buttonStyle(SecondaryPillButtonStyle(outlined: true))
        } trailing: {
            Button("Back") { model.go(.permissions) }.buttonStyle(SecondaryPillButtonStyle())
            Button("Continue") { model.go(.connect) }.buttonStyle(PrimaryPillButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct ConnectPage: View {
    @ObservedObject var model: HubModel
    @ObservedObject var app: AppModel

    private var usbStatus: (String, Bool) {
        switch app.state {
        case .mirroring(let name): return ("Connected to \(name)", true)
        case .connecting(let name): return ("Connecting to \(name)…", false)
        case .unauthorized: return ("Tap Allow on your phone", false)
        case .choose: return ("Phone found", false)
        default: return ("Plug in your phone…", false)
        }
    }

    var body: some View {
        HubPage(title: "Connect Your Phone") {
            HStack(spacing: 20) {
                ConnectCard(symbol: "cable.connector", title: "With a USB cable",
                            detail: "Plug your phone into this Mac and tap Allow on the phone. AirDoxx then switches to Wi-Fi so you can unplug it.") {
                    StatusLine(text: usbStatus.0, done: usbStatus.1)
                }
                ConnectCard(symbol: "qrcode", title: "Over Wi-Fi (Android 11+)",
                            detail: "On the phone: Developer options › Wireless debugging › Pair device with QR code.") {
                    VStack(spacing: 10) {
                        if let image = model.qrImage {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 118, height: 118)
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 10).fill(.white))
                        }
                        StatusLine(text: model.pairingStatus, done: model.pairingStatus.hasPrefix("Paired!"))
                    }
                }
            }
            .frame(width: 680)
            .padding(.top, 6)
        } content: {
            Text("You only pair once. After that, AirDoxx finds your phone by itself whenever both are on the same Wi-Fi.")
        } leading: {
            Button("Learn More…") { NSWorkspace.shared.open(AirDoxxLinks.setupGuide) }
                .buttonStyle(SecondaryPillButtonStyle(outlined: true))
        } trailing: {
            Button("Back") { model.go(.phoneSetup) }.buttonStyle(SecondaryPillButtonStyle())
            Button(app.isMirroring ? "Start Mirroring" : "Skip") { app.finishSetup() }
                .buttonStyle(PrimaryPillButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct ConnectCard<Footer: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var footer: Footer
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(AirDoxxColor.accent)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            Text(detail).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack { Spacer(); footer; Spacer() }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard()
    }
}

private struct StatusLine: View {
    let text: String
    let done: Bool
    var body: some View {
        HStack(spacing: 8) {
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(AirDoxxColor.accent)
            } else {
                SpokeSpinner(size: 14)
            }
            Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.85))
        }
        .animation(.easeInOut, value: done)
    }
}

private struct UnavailablePage: View {
    @ObservedObject var model: HubModel
    var body: some View {
        HubPage(title: "Unable to Connect to Android Phone") {
            MirrorIllustration()
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Text("To use AirDoxx, make sure your Android phone is nearby, turned on, with USB debugging enabled, and connected to this Mac with a cable or on the same Wi-Fi network.")
                if let first = model.unavailableDetail.split(separator: "\n").first, !first.isEmpty {
                    Text(String(first))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(2)
                }
            }
        } leading: {
            Button("Learn More…") { model.app.learnMore() }.buttonStyle(SecondaryPillButtonStyle(outlined: true))
        } trailing: {
            Button("Not Now") { model.app.notNow() }.buttonStyle(SecondaryPillButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Try Again") { model.app.tryAgain() }.buttonStyle(PrimaryPillButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct DisconnectedPage: View {
    @ObservedObject var model: HubModel
    var body: some View {
        HubPage(title: "Disconnected from \(model.unavailableDetail.isEmpty ? "Your Phone" : model.unavailableDetail)") {
            MirrorIllustration()
                .saturation(0.35)
                .opacity(0.8)
        } content: {
            Text("Your phone is still paired. Reconnect any time – or disconnect permanently to make AirDoxx forget it.")
        } leading: {
            Button("Disconnect Permanently…") { model.app.forgetPhone() }
                .buttonStyle(SecondaryPillButtonStyle(outlined: true))
        } trailing: {
            Button("Quit") { model.app.notNow() }.buttonStyle(SecondaryPillButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Reconnect") { model.app.reconnect() }.buttonStyle(PrimaryPillButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Page indicator for the setup flow.
private struct StepDots: View {
    let current: Int
    let count: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? AnyShapeStyle(AirDoxxColor.accent) : AnyShapeStyle(.white.opacity(0.22)))
                    .frame(width: i == current ? 22 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: current)
    }
}
