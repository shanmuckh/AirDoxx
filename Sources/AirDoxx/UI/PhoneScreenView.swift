import AppKit
import AVFoundation

protocol PhoneScreenViewDelegate: AnyObject {
    func phoneScreen(_ view: PhoneScreenView, didReceiveDroppedFiles urls: [URL])
    func phoneScreenPaste(_ view: PhoneScreenView)
}

/// Displays the phone's screen and turns mouse, trackpad and keyboard input into
/// Android touch, scroll and key events.
final class PhoneScreenView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    weak var session: MirrorSession?
    weak var delegate: PhoneScreenViewDelegate?

    private var pressedKeys: [UInt16: (keycode: UInt32, meta: UInt32)] = [:]
    private var touchActive = false
    private var pinchCenter: CGPoint?
    private var pinchBaseDistance: CGFloat = 0
    private var scrollRemainderX: CGFloat = 0
    private var scrollRemainderY: CGFloat = 0

    private static let pinchPointerA: UInt64 = 0x1000
    private static let pinchPointerB: UInt64 = 0x1001

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    var cornerRadius: CGFloat {
        get { layer?.cornerRadius ?? 0 }
        set {
            layer?.cornerRadius = newValue
            layer?.cornerCurve = .continuous
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func enqueue(_ sample: CMSampleBuffer) {
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
        }
        renderer.enqueue(sample)
    }

    func flush() {
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    // MARK: - Coordinate mapping

    private func devicePoint(for event: NSEvent) -> (x: Int32, y: Int32, w: UInt16, h: UInt16)? {
        devicePoint(for: convert(event.locationInWindow, from: nil))
    }

    private func devicePoint(for p: CGPoint) -> (x: Int32, y: Int32, w: UInt16, h: UInt16)? {
        guard let size = session?.videoSize, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let nx = min(max(p.x / bounds.width, 0), 1)
        let ny = min(max(1 - p.y / bounds.height, 0), 1)
        let x = Int32(min(nx * size.width, size.width - 1))
        let y = Int32(min(ny * size.height, size.height - 1))
        return (x, y, UInt16(size.width), UInt16(size.height))
    }

    private func sendTouch(_ action: ControlMessage.MotionAction, _ event: NSEvent) {
        guard var pt = devicePoint(for: event) else { return }
        if action == .down {
            // Within ~8pt of the left/right/bottom edge: start exactly on the edge so Android's
            // back / home gestures recognise the drag.
            let p = convert(event.locationInWindow, from: nil)
            let margin: CGFloat = 8
            if p.x < margin { pt.x = 0 }
            if p.x > bounds.width - margin { pt.x = Int32(pt.w) - 1 }
            if p.y < margin { pt.y = Int32(pt.h) - 1 }
        }
        session?.send(ControlMessage.touch(action, pointerId: ControlMessage.pointerGenericFinger,
                                           x: pt.x, y: pt.y, width: pt.w, height: pt.h,
                                           pressure: action == .up ? 0 : 1))
    }

    // MARK: - Mouse -> touch

    private func debugLog(_ text: String) {
        #if DEBUG
        let t = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        FileHandle.standardError.write(Data("[input \(t)] \(text)\n".utf8))
        #endif
    }

    /// Tracks the whole click/drag in a local event loop. Relying on separate mouseUp(with:)
    /// callbacks proved unreliable in this borderless window: a missed mouse-up leaves a finger
    /// "stuck" on the phone, turning every tap into a long-press.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        endSwipe() // a click always wins over an in-flight trackpad swipe
        guard let window else { return }
        touchActive = true
        sendTouch(.down, event)
        debugLog("touch down clicks=\(event.clickCount)")
        var last = event
        while touchActive {
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                              until: .distantFuture, inMode: .eventTracking,
                                              dequeue: true) else { break }
            last = next
            if next.type == .leftMouseUp { break }
            debugLog("drag")
            sendTouch(.move, next)
        }
        touchActive = false
        sendTouch(.up, last)
        debugLog("touch up")
        session?.noteUserInput()
    }

    /// Right click = Back (or wake the screen), like scrcpy.
    override func rightMouseDown(with event: NSEvent) {
        session?.send(ControlMessage.backOrScreenOn(.down))
    }

    override func rightMouseUp(with event: NSEvent) {
        session?.send(ControlMessage.backOrScreenOn(.up))
    }

    /// Middle click = Home.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { session?.pressKey(AndroidKey.home) }
    }

    // MARK: - Trackpad two-finger swipe -> one-finger drag on the phone
    //
    // Android launchers and many apps ignore mouse-wheel events, so (like iPhone Mirroring)
    // a two-finger trackpad swipe is replayed as a real finger drag. Android then applies its
    // own fling physics when the finger lifts. Classic mouse wheels still send scroll events.

    private var swipePoint: CGPoint?   // current virtual finger, in device pixels (nil = not down)
    private var swipeStart: CGPoint?   // where the fingers were when the gesture began
    private var swipeAccum: CGPoint = .zero
    private var swipeSize: CGSize = .zero
    private var swipeGain: CGFloat = 1

    private func sendSwipe(_ action: ControlMessage.MotionAction) {
        guard let p = swipePoint, swipeSize.width > 0 else { return }
        session?.send(ControlMessage.touch(action, pointerId: ControlMessage.pointerGenericFinger,
                                           x: Int32(p.x), y: Int32(p.y),
                                           width: UInt16(swipeSize.width), height: UInt16(swipeSize.height),
                                           pressure: action == .up ? 0 : 1))
    }

    private func endSwipe() {
        swipeStart = nil
        guard swipePoint != nil else { return }
        sendSwipe(.up)
        swipePoint = nil
        session?.noteUserInput()
    }

    /// Android gesture navigation only reacts to drags that start exactly at the screen edge.
    /// Decide where the virtual finger lands once the swipe direction is known.
    private func edgeAdjustedStart(_ start: CGPoint, direction d: CGPoint) -> (CGPoint, gain: CGFloat) {
        let w = swipeSize.width, h = swipeSize.height
        let horizontal = abs(d.x) > abs(d.y)
        if horizontal && start.x < w * 0.18 && d.x > 0 {
            debugLog("gesture: back (left edge)")
            return (CGPoint(x: 0, y: start.y), 1.6)
        }
        if horizontal && start.x > w * 0.82 && d.x < 0 {
            debugLog("gesture: back (right edge)")
            return (CGPoint(x: w - 1, y: start.y), 1.6)
        }
        if !horizontal && start.y > h * 0.85 && d.y < 0 {
            debugLog("gesture: home / recents (bottom edge)")
            return (CGPoint(x: start.x, y: h - 1), 1.6)
        }
        if !horizontal && start.y < h * 0.10 && d.y > 0 {
            debugLog("gesture: notifications (top edge)")
            return (CGPoint(x: start.x, y: 0), 1.3)
        }
        return (start, 1)
    }

    private func handleTrackpadSwipe(_ event: NSEvent) {
        if !event.momentumPhase.isEmpty { return } // Android computes its own fling on finger-up

        if event.phase.contains(.began) {
            guard !touchActive, let pt = devicePoint(for: event), let size = session?.videoSize else { return }
            endSwipe()
            swipeSize = size
            swipeStart = CGPoint(x: CGFloat(pt.x), y: CGFloat(pt.y))
            swipeAccum = .zero
            return
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            endSwipe()
            return
        }
        guard event.phase.contains(.changed), bounds.width > 0, swipeSize.width > 0 else { return }

        // With "natural scrolling" deltas follow the fingers; otherwise they're inverted.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let delta = CGPoint(x: sign * event.scrollingDeltaX * swipeSize.width / bounds.width,
                            y: sign * event.scrollingDeltaY * swipeSize.height / bounds.height)

        if swipePoint == nil {
            guard let start = swipeStart else { return }
            swipeAccum.x += delta.x
            swipeAccum.y += delta.y
            guard hypot(swipeAccum.x, swipeAccum.y) > 6 else { return }
            let (origin, gain) = edgeAdjustedStart(start, direction: swipeAccum)
            swipeGain = gain
            swipePoint = origin
            sendSwipe(.down)
            move(by: CGPoint(x: swipeAccum.x * gain, y: swipeAccum.y * gain))
            return
        }
        move(by: CGPoint(x: delta.x * swipeGain, y: delta.y * swipeGain))
    }

    private func move(by d: CGPoint) {
        guard var p = swipePoint else { return }
        p.x = min(max(p.x + d.x, 0), swipeSize.width - 1)
        p.y = min(max(p.y + d.y, 0), swipeSize.height - 1)
        swipePoint = p
        sendSwipe(.move)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas && (!event.phase.isEmpty || !event.momentumPhase.isEmpty) {
            handleTrackpadSwipe(event)
            return
        }
        guard let pt = devicePoint(for: event) else { return }
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            // Trackpad / Magic Mouse report pixels; Android expects wheel "notches".
            dx /= 24
            dy /= 24
        }
        scrollRemainderX += dx
        scrollRemainderY += dy
        guard abs(scrollRemainderX) >= 0.05 || abs(scrollRemainderY) >= 0.05 else { return }
        let h = Float(-scrollRemainderX)
        let v = Float(scrollRemainderY)
        scrollRemainderX = 0
        scrollRemainderY = 0
        session?.send(ControlMessage.scroll(x: pt.x, y: pt.y, width: pt.w, height: pt.h,
                                            hscroll: h, vscroll: v))
    }

    // MARK: - Trackpad pinch -> two-finger pinch

    override func magnify(with event: NSEvent) {
        guard let session, let size = Optional(session.videoSize), size.width > 0 else { return }
        switch event.phase {
        case .began:
            let p = convert(event.locationInWindow, from: nil)
            pinchCenter = p
            pinchBaseDistance = min(bounds.width, bounds.height) * 0.15
            sendPinch(.down, scale: 1)
        case .changed:
            accumulatedMagnification += event.magnification
            sendPinch(.move, scale: 1 + accumulatedMagnification)
        case .ended, .cancelled:
            sendPinch(.up, scale: 1 + accumulatedMagnification)
            pinchCenter = nil
            accumulatedMagnification = 0
        default:
            break
        }
    }

    private var accumulatedMagnification: CGFloat = 0

    private func sendPinch(_ action: ControlMessage.MotionAction, scale: CGFloat) {
        guard let c = pinchCenter else { return }
        let d = max(pinchBaseDistance * max(scale, 0.1), 4)
        let a = CGPoint(x: c.x - d, y: c.y)
        let b = CGPoint(x: c.x + d, y: c.y)
        guard let pa = devicePoint(for: a), let pb = devicePoint(for: b) else { return }
        let pressure: Float = action == .up ? 0 : 1
        // Order matters: second pointer goes down after the first and up before it.
        let first = ControlMessage.touch(action, pointerId: Self.pinchPointerA, x: pa.x, y: pa.y,
                                         width: pa.w, height: pa.h, pressure: pressure)
        let second = ControlMessage.touch(action, pointerId: Self.pinchPointerB, x: pb.x, y: pb.y,
                                          width: pb.w, height: pb.h, pressure: pressure)
        if action == .up {
            session?.send(second); session?.send(first)
        } else {
            session?.send(first); session?.send(second)
        }
    }

    // MARK: - Keyboard

    private static let specialKeys: [UInt16: UInt32] = [
        36: AndroidKey.enter,      // return
        76: AndroidKey.enter,      // keypad enter
        51: AndroidKey.del,        // delete (backspace)
        117: AndroidKey.forwardDel,
        48: AndroidKey.tab,
        53: AndroidKey.back,       // escape -> Back
        123: AndroidKey.dpadLeft,
        124: AndroidKey.dpadRight,
        125: AndroidKey.dpadDown,
        126: AndroidKey.dpadUp,
        115: AndroidKey.moveHome,
        119: AndroidKey.moveEnd,
        116: AndroidKey.pageUp,
        121: AndroidKey.pageDown,
    ]

    private func meta(for flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.shift) { m |= AndroidKey.metaShift }
        if flags.contains(.option) { m |= AndroidKey.metaAlt }
        if flags.contains(.control) { m |= AndroidKey.metaCtrl }
        return m
    }

    override func keyDown(with event: NSEvent) {
        guard let session else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return } // handled by the menu bar

        if let keycode = Self.specialKeys[event.keyCode] {
            let m = meta(for: flags)
            pressedKeys[event.keyCode] = (keycode, m)
            session.send(ControlMessage.keycode(.down, keycode, repeat: event.isARepeat ? 1 : 0, meta: m))
            return
        }

        if flags.contains(.control),
           let ch = event.charactersIgnoringModifiers?.first,
           let keycode = AndroidKey.keycode(forCharacter: ch) {
            let m = meta(for: flags)
            pressedKeys[event.keyCode] = (keycode, m)
            session.send(ControlMessage.keycode(.down, keycode, repeat: event.isARepeat ? 1 : 0, meta: m))
            return
        }

        guard let chars = event.characters, !chars.isEmpty else { return }
        let printable = chars.unicodeScalars.allSatisfy { s in
            !(s.value < 0x20 || s.value == 0x7F || (0xF700...0xF8FF).contains(s.value))
        }
        if printable { session.sendText(chars) }
    }

    override func keyUp(with event: NSEvent) {
        guard let pressed = pressedKeys.removeValue(forKey: event.keyCode) else { return }
        session?.send(ControlMessage.keycode(.up, pressed.keycode, meta: pressed.meta))
    }

    override func resignFirstResponder() -> Bool {
        for (_, pressed) in pressedKeys {
            session?.send(ControlMessage.keycode(.up, pressed.keycode, meta: pressed.meta))
        }
        pressedKeys.removeAll()
        return super.resignFirstResponder()
    }

    // MARK: - Edit menu (Mac shortcuts -> phone clipboard)

    @objc func cut(_ sender: Any?) { session?.send(ControlMessage.getClipboard(copyKey: 2)) }
    @objc func copy(_ sender: Any?) { session?.send(ControlMessage.getClipboard(copyKey: 1)) }
    @objc func paste(_ sender: Any?) { delegate?.phoneScreenPaste(self) }
    @objc override func selectAll(_ sender: Any?) {
        session?.pressKey(29, meta: AndroidKey.metaCtrl) // Ctrl+A
    }

    // MARK: - Drag & drop (files -> Downloads, APKs -> install)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        session == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        delegate?.phoneScreen(self, didReceiveDroppedFiles: urls)
        return true
    }
}
