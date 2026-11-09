import AppKit
import SwiftUI

/// Borderless window that can still become key (so it receives keyboard input).
final class MirrorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The top strip that fades in on hover (traffic lights on the left, Back / Home /
/// App Switcher on the right), and lets the user drag the window around.
final class TopBarView: NSView {
    let background = NSVisualEffectView()
    let buttonStack = NSStackView()
    var trafficLights: [NSButton] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 11
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        addSubview(background)

        let mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let b = NSWindow.standardWindowButton(type, for: mask) {
                if type == .zoomButton { b.isEnabled = false }
                trafficLights.append(b)
                addSubview(b)
            }
        }

        buttonStack.orientation = .horizontal
        buttonStack.spacing = 2
        addSubview(buttonStack)
    }

    required init?(coder: NSCoder) { fatalError() }

    @discardableResult
    func addButton(symbol: String, tooltip: String, target: AnyObject, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        let b = NSButton(image: image ?? NSImage(), target: target, action: action)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.toolTip = tooltip
        b.contentTintColor = .labelColor
        b.setFrameSize(NSSize(width: 28, height: 22))
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        buttonStack.addArrangedSubview(b)
        return b
    }

    override func layout() {
        super.layout()
        let barH: CGFloat = 28
        let bar = NSRect(x: 0, y: bounds.height - barH, width: bounds.width, height: barH)
        background.frame = bar
        var x: CGFloat = 10
        for b in trafficLights {
            let s = b.frame.size
            b.setFrameOrigin(NSPoint(x: x, y: bar.midY - s.height / 2))
            x += s.width + 6
        }
        let stackSize = buttonStack.fittingSize
        buttonStack.frame = NSRect(x: bounds.width - stackSize.width - 8, y: bar.midY - stackSize.height / 2,
                                   width: stackSize.width, height: stackSize.height)
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// Root content view: tracks hover to reveal the top bar.
final class RootView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

final class MirrorWindowController: NSWindowController, NSWindowDelegate {
    static let barHeight: CGFloat = 34   // 28pt bar + 6pt gap
    static let bezel: CGFloat = 4

    let rootView = RootView()
    let topBar = TopBarView()
    let phoneFrame = NSView()
    let screenView = PhoneScreenView()
    let statusHost: NSHostingView<StatusView>
    private let toastLabel = NSTextField(labelWithString: "")
    private let toastBackground = NSVisualEffectView()
    private var toastWorkItem: DispatchWorkItem?
    private let protectedNotice = NSVisualEffectView()
    private let protectedLabel = NSTextField(wrappingLabelWithString: "")

    /// Phone screen size in device pixels (only the ratio matters).
    private(set) var aspect = CGSize(width: 1080, height: 2400)
    /// Length of the screen's long side, in points.
    private var longSide: CGFloat
    private var hovering = false
    private var barPinned = true

    init(model: AppModel) {
        statusHost = NSHostingView(rootView: StatusView(model: model))
        longSide = MirrorWindowController.defaultLongSide()

        let window = MirrorWindow(contentRect: .zero,
                                  styleMask: [.borderless, .resizable, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.title = "AirDoxx"
        window.collectionBehavior = [.fullScreenNone]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .documentWindow   // native grow-in / shrink-out
        super.init(window: window)
        window.delegate = self

        buildViews()
        applySize(animated: false)
        window.center()
        setBarVisible(true, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func defaultLongSide() -> CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return (visible * 0.78).rounded()
    }

    private func buildViews() {
        guard let window else { return }
        rootView.wantsLayer = true
        window.contentView = rootView
        rootView.onHoverChange = { [weak self] inside in
            self?.hovering = inside
            self?.updateBar()
        }

        phoneFrame.wantsLayer = true
        phoneFrame.layer?.backgroundColor = NSColor.black.cgColor
        phoneFrame.layer?.cornerCurve = .continuous
        phoneFrame.layer?.borderColor = NSColor(white: 0.35, alpha: 0.9).cgColor
        phoneFrame.layer?.borderWidth = 1
        phoneFrame.layer?.masksToBounds = true
        rootView.addSubview(phoneFrame)

        phoneFrame.addSubview(screenView)
        statusHost.wantsLayer = true
        statusHost.layer?.masksToBounds = true
        statusHost.layer?.cornerCurve = .continuous
        phoneFrame.addSubview(statusHost)

        toastBackground.material = .hudWindow
        toastBackground.blendingMode = .withinWindow
        toastBackground.state = .active
        toastBackground.wantsLayer = true
        toastBackground.layer?.cornerRadius = 14
        toastBackground.alphaValue = 0
        toastLabel.font = .systemFont(ofSize: 12, weight: .medium)
        toastLabel.textColor = .labelColor
        toastLabel.alignment = .center
        toastLabel.lineBreakMode = .byTruncatingMiddle
        toastBackground.addSubview(toastLabel)
        phoneFrame.addSubview(toastBackground)

        protectedNotice.material = .hudWindow
        protectedNotice.blendingMode = .withinWindow
        protectedNotice.state = .active
        protectedNotice.wantsLayer = true
        protectedNotice.layer?.cornerRadius = 16
        protectedNotice.layer?.cornerCurve = .continuous
        protectedNotice.isHidden = true
        let lock = NSImageView(image: NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 30, weight: .regular)) ?? NSImage())
        lock.contentTintColor = .labelColor
        lock.identifier = NSUserInterfaceItemIdentifier("lock")
        protectedNotice.addSubview(lock)
        protectedLabel.stringValue = "This screen is protected by the app and can't be mirrored.\n\nContinue on your phone – its screen is on now."
        protectedLabel.alignment = .center
        protectedLabel.font = .systemFont(ofSize: 13, weight: .medium)
        protectedLabel.textColor = .labelColor
        protectedNotice.addSubview(protectedLabel)
        phoneFrame.addSubview(protectedNotice)

        rootView.addSubview(topBar)
        disconnectButton = topBar.addButton(symbol: "power", tooltip: "Disconnect", target: self,
                                            action: #selector(disconnectPressed))
        screenModeButton = topBar.addButton(symbol: "macbook.and.iphone", tooltip: "", target: self,
                                            action: #selector(screenModePressed))
        topBar.addButton(symbol: "rotate.right", tooltip: "Rotate: portrait / landscape (⌘R)", target: self,
                         action: #selector(rotatePressed))
        topBar.addButton(symbol: "chevron.backward", tooltip: "Back", target: self, action: #selector(backPressed))
        topBar.addButton(symbol: "house", tooltip: "Home Screen (⌘1)", target: self, action: #selector(homePressed))
        topBar.addButton(symbol: "square.on.square", tooltip: "App Switcher (⌘2)", target: self, action: #selector(recentsPressed))

        rootView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(layoutContent),
                                               name: NSView.frameDidChangeNotification, object: rootView)
    }

    var onDisconnect: (() -> Void)?
    var onForget: (() -> Void)?
    private var disconnectButton: NSButton?

    /// Power button: a small menu with "Disconnect" and "Disconnect Permanently…".
    @objc private func disconnectPressed() {
        guard let button = disconnectButton else { return }
        let menu = NSMenu()
        let a = NSMenuItem(title: "Disconnect", action: #selector(menuDisconnect), keyEquivalent: "")
        a.target = self
        a.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: nil)
        let b = NSMenuItem(title: "Disconnect Permanently…", action: #selector(menuForget), keyEquivalent: "")
        b.target = self
        b.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        menu.addItem(a)
        menu.addItem(b)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func menuDisconnect() { onDisconnect?() }
    @objc private func menuForget() { onForget?() }

    var onToggleScreenMode: (() -> Void)?
    var onRotate: (() -> Void)?
    private var screenModeButton: NSButton?
    @objc private func screenModePressed() { onToggleScreenMode?() }
    @objc private func rotatePressed() { onRotate?() }

    /// Mac only: the phone's own screen stays off. Both: phone and Mac show the same screen.
    func updateScreenModeButton(macOnly: Bool) {
        let symbol = macOnly ? "macbook" : "macbook.and.iphone"
        screenModeButton?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        screenModeButton?.toolTip = macOnly
            ? "Showing on Mac only (phone screen off) – click to show on both screens (⇧⌘P)"
            : "Showing on both screens – click to show on Mac only (⇧⌘P)"
    }
    @objc private func backPressed() { screenView.session?.pressKey(AndroidKey.back) }
    @objc private func homePressed() {
        #if DEBUG
        FileHandle.standardError.write(Data("[input] toolbar Home pressed, session=\(screenView.session != nil)\n".utf8))
        #endif
        screenView.session?.pressKey(AndroidKey.home)
    }
    @objc private func recentsPressed() { screenView.session?.pressKey(AndroidKey.appSwitch) }

    // MARK: - Layout

    @objc func layoutContent() {
        let b = rootView.bounds
        let barH = Self.barHeight
        topBar.frame = NSRect(x: 0, y: b.height - barH, width: b.width, height: barH)
        phoneFrame.frame = rotationOverride ?? NSRect(x: 0, y: 0, width: b.width, height: max(0, b.height - barH))

        let bezel = Self.bezel
        let inner = phoneFrame.bounds.insetBy(dx: bezel, dy: bezel)
        let shortSide = min(inner.width, inner.height)
        let innerRadius = shortSide * 0.085
        phoneFrame.layer?.cornerRadius = innerRadius + bezel
        screenView.frame = inner
        screenView.cornerRadius = innerRadius
        statusHost.frame = inner
        statusHost.layer?.cornerRadius = innerRadius

        let noticeW = min(inner.width - 40, 280)
        protectedNotice.frame = NSRect(x: inner.midX - noticeW / 2, y: inner.midY - 80, width: noticeW, height: 160)
        if let lock = protectedNotice.subviews.first(where: { $0.identifier?.rawValue == "lock" }) {
            lock.frame = NSRect(x: (noticeW - 40) / 2, y: 108, width: 40, height: 40)
        }
        protectedLabel.frame = NSRect(x: 14, y: 12, width: noticeW - 28, height: 92)

        let toastW = min(inner.width - 40, 260)
        toastBackground.frame = NSRect(x: inner.midX - toastW / 2, y: inner.minY + 36, width: toastW, height: 30)
        toastLabel.frame = toastBackground.bounds.insetBy(dx: 10, dy: 7)
        window?.invalidateShadow()
    }

    private func screenSize(forLongSide long: CGFloat) -> CGSize {
        let ratio = aspect.width / aspect.height
        if ratio <= 1 {
            return CGSize(width: (long * ratio).rounded(), height: long)
        } else {
            return CGSize(width: long, height: (long / ratio).rounded())
        }
    }

    private func windowSize(forScreen s: CGSize) -> CGSize {
        CGSize(width: s.width + 2 * Self.bezel, height: s.height + 2 * Self.bezel + Self.barHeight)
    }

    private func applySize(animated: Bool) {
        guard let window else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Never grow past the visible screen area.
        var s = screenSize(forLongSide: longSide)
        let maxW = visible.width - 2 * Self.bezel
        let maxH = visible.height - 2 * Self.bezel - Self.barHeight
        let shrink = min(1, maxW / s.width, maxH / s.height)
        if shrink < 1 {
            s = CGSize(width: (s.width * shrink).rounded(), height: (s.height * shrink).rounded())
            longSide = max(s.width, s.height)
        }
        let size = windowSize(forScreen: s)
        let old = window.frame
        var frame = NSRect(x: old.midX - size.width / 2, y: old.maxY - size.height,
                           width: size.width, height: size.height)
        if old.width == 0 { frame.origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2) }
        // Keep on screen.
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)

        let minScreen = screenSize(forLongSide: 320)
        window.minSize = windowSize(forScreen: minScreen)
        window.setFrame(frame, display: true, animate: animated)
        layoutContent()
    }

    func setVideoSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let changed = abs(size.width / size.height - aspect.width / aspect.height) > 0.001
        let wasPortrait = aspect.height >= aspect.width
        let isPortrait = size.height >= size.width
        aspect = size
        guard changed else { return }
        if wasPortrait != isPortrait, window?.isVisible == true, !screenView.isHidden {
            animateRotation(toPortrait: isPortrait)
        } else {
            applySize(animated: window?.isVisible ?? false)
        }
    }

    /// Phone-frame rect used while a rotation animation runs (window is temporarily square).
    private var rotationOverride: NSRect?

    /// Turns the phone 90° in place instead of morphing the window: the window switches to the
    /// new shape instantly and the phone (already showing the new orientation) rotates into it.
    private func animateRotation(toPortrait: Bool) {
        guard let window, let layer = phoneFrame.layer else { applySize(animated: false); return }
        let oldPhone = window.convertToScreen(phoneFrame.convert(phoneFrame.bounds, to: nil))
        let center = CGPoint(x: oldPhone.midX, y: oldPhone.midY)
        let screen = screenSize(forLongSide: longSide)
        let pw = screen.width + 2 * Self.bezel
        let ph = screen.height + 2 * Self.bezel
        let side = max(pw, ph)

        // 1. Square window big enough for the phone at any angle, centred on the phone.
        topBar.alphaValue = 0
        rotationOverride = NSRect(x: (side - pw) / 2, y: (side - ph) / 2, width: pw, height: ph)
        window.setFrame(NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side),
                        display: false)
        layoutContent()

        // 2. Rotate around the phone's centre (AppKit layers default to a corner anchor).
        let frame = phoneFrame.frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        CATransaction.commit()

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        // Into landscape the phone turns counter-clockwise (as Android's 90° rotation); back clockwise.
        spin.fromValue = toPortrait ? CGFloat.pi / 2 : -CGFloat.pi / 2
        spin.toValue = 0
        spin.duration = 0.3
        spin.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.anchorPoint = .zero
            layer.position = frame.origin
            CATransaction.commit()
            // 3. Shrink the window to the phone (+ toolbar), keeping the phone where it is.
            self.rotationOverride = nil
            window.setFrame(NSRect(x: center.x - pw / 2, y: center.y - ph / 2,
                                   width: pw, height: ph + Self.barHeight), display: true)
            self.layoutContent()
            self.updateBar()
        }
        layer.add(spin, forKey: "rotate")
        CATransaction.commit()
    }

    func larger() { longSide *= 1.15; applySize(animated: true) }
    func smaller() { longSide = max(320, longSide / 1.15); applySize(animated: true) }
    func actualSize() { longSide = Self.defaultLongSide(); applySize(animated: true) }

    // MARK: - Mirroring vs. status

    func showMirroring(_ mirroring: Bool) {
        // Cross-dissolve between the "connecting" backdrop and the live phone screen.
        // The SwiftUI status view is detached entirely while mirroring: a hidden NSHostingView still
        // won hit-testing and swallowed the second click of every double-click.
        if mirroring {
            screenView.isHidden = false
            screenView.alphaValue = 0
            let status = statusHost
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.55
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                screenView.animator().alphaValue = 1
                status.animator().alphaValue = 0
            } completionHandler: {
                status.removeFromSuperview()
                status.alphaValue = 1
            }
        } else {
            if statusHost.superview == nil {
                phoneFrame.addSubview(statusHost, positioned: .below, relativeTo: toastBackground)
                layoutContent()
            }
            statusHost.isHidden = false
            statusHost.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.45
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                statusHost.animator().alphaValue = 1
                screenView.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                self?.screenView.isHidden = true
                self?.screenView.alphaValue = 1
            }
        }
        barPinned = !mirroring
        updateBar()
        if mirroring {
            window?.makeFirstResponder(screenView)
        } else {
            screenView.flush()
        }
    }

    private func updateBar() {
        setBarVisible(barPinned || hovering, animated: true)
    }

    private func setBarVisible(_ visible: Bool, animated: Bool) {
        let alpha: CGFloat = visible ? 1 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = visible ? 0.28 : 0.4
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                topBar.animator().alphaValue = alpha
            } completionHandler: { [weak self] in
                self?.window?.invalidateShadow()
            }
        } else {
            topBar.alphaValue = alpha
            window?.invalidateShadow()
        }
    }

    /// Shown while the phone's frontmost screen is marked secure (payments, banking, PIN entry).
    func showProtectedNotice(_ visible: Bool) {
        protectedNotice.isHidden = !visible
    }

    func showToast(_ text: String) {
        toastLabel.stringValue = text
        toastWorkItem?.cancel()
        // Rise 8pt while fading in; sink back while fading out.
        let rest = toastBackground.frame.origin
        if toastBackground.alphaValue < 0.01 { toastBackground.setFrameOrigin(NSPoint(x: rest.x, y: rest.y - 8)) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            toastBackground.animator().alphaValue = 1
            toastBackground.animator().setFrameOrigin(rest)
        }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
                self?.toastBackground.animator().alphaValue = 0
            }
        }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    // MARK: - NSWindowDelegate

    /// Keep the phone's aspect ratio while the user drags the window edges.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let ratio = aspect.height / aspect.width
        let innerW = max(1, frameSize.width - 2 * Self.bezel)
        let innerH = (innerW * ratio).rounded()
        return NSSize(width: frameSize.width, height: innerH + 2 * Self.bezel + Self.barHeight)
    }

    func windowDidResize(_ notification: Notification) {
        let inner = phoneFrame.bounds.insetBy(dx: Self.bezel, dy: Self.bezel)
        if inner.width > 0 { longSide = max(inner.width, inner.height) }
        layoutContent()
    }
}
