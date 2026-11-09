import AppKit
import Darwin

/// Trackpad edge controls for the Mac itself (while AirDoxx runs, the volume and brightness keys go to
/// the phone):
///   • right edge – click and slide up/down: Mac volume
///   • left edge  – click and slide up/down: Mac brightness
/// A gesture only starts when one finger is inside the edge strip and the trackpad is physically
/// clicked; the pointer is frozen while sliding, every step gives a haptic tick, and the change goes
/// through the native macOS volume / brightness indicator. Hold ⇧⌥ for quarter steps.
///
/// Finger positions come from Apple's private MultitouchSupport framework (loaded at runtime).
final class EdgeControls {
    static let shared = EdgeControls()

    enum Side: String { case left, right }

    /// Width of each edge strip, as a fraction of the trackpad width.
    var edgeWidth: Float = 0.10
    /// Finger travel (fraction of trackpad height) per volume/brightness step.
    var stepDistance: Float = 0.055

    private(set) var isRunning = false
    private(set) var deviceCount = 0

    // Touch state (written on the multitouch thread, read on the main thread).
    private let lock = NSLock()
    private var fingerCount = 0
    private var fingerX: Float = 0.5
    private var fingerY: Float = 0.5

    // Active gesture (main thread).
    private var activeSide: Side?
    private var startY: Float = 0
    private var stepsApplied = 0
    private var quarterSteps = false

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var devices: [UnsafeMutableRawPointer] = []
    private var deviceList: CFArray?          // keeps the trackpad device objects alive
    private var gestureRunning = false        // mirrors activeSide for the multitouch thread (under lock)

    static let syntheticMarker: Int64 = 0x4144_5858 // "ADXX": lets our own key tap ignore these events

    // MARK: Start / stop

    func start() {
        guard !isRunning else { return }
        guard installTap() else {
            Self.log("edge controls: needs Accessibility permission (event tap unavailable)")
            return
        }
        startMultitouch()
        isRunning = deviceCount > 0
        Self.log("edge controls: \(isRunning ? "running" : "no trackpad found") – devices=\(deviceCount)")
        if !isRunning { removeTap() }
    }

    func stop() {
        guard isRunning else { return }
        for d in devices { Multitouch.stop?(d) }
        devices.removeAll()
        removeTap()
        endGesture()
        isRunning = false
        Self.log("edge controls: stopped")
    }

    // MARK: Multitouch

    private func startMultitouch() {
        guard Multitouch.load(), let createList = Multitouch.createList,
              let register = Multitouch.registerCallback, let startDevice = Multitouch.start else {
            Self.log("edge controls: MultitouchSupport unavailable")
            return
        }
        guard let cfList = createList()?.takeRetainedValue() else { return }
        deviceList = cfList
        let list = cfList as [AnyObject]
        for item in list {
            let device = Unmanaged.passUnretained(item).toOpaque()
            register(device, edgeContactCallback)
            startDevice(device, 0)
            devices.append(device)
        }
        deviceCount = devices.count
    }

    /// Called on the multitouch thread for every touch frame.
    fileprivate func handleFrame(_ touches: UnsafeMutableRawPointer?, count: Int) {
        var active = 0
        var x: Float = 0, y: Float = 0
        if let touches, count > 0 {
            let fingers = touches.bindMemory(to: MTTouch.self, capacity: count)
            for i in 0..<count {
                let t = fingers[i]
                // States 3...5: making / touching / breaking contact.
                if (3...5).contains(t.state) {
                    active += 1
                    x = t.normalized.pos.x
                    y = t.normalized.pos.y
                }
            }
        }
        lock.lock()
        fingerCount = active
        if active == 1 { fingerX = x; fingerY = y }
        let running = gestureRunning
        lock.unlock()
        if active == 1 && running {
            DispatchQueue.main.async { [weak self] in self?.updateGesture(y: y) }
        }
    }

    private func touchSnapshot() -> (count: Int, x: Float, y: Float) {
        lock.lock(); defer { lock.unlock() }
        return (fingerCount, fingerX, fingerY)
    }

    // MARK: Gesture

    /// Returns true when a click should start (and be swallowed by) an edge gesture.
    fileprivate func beginGestureIfOnEdge(flags: CGEventFlags) -> Bool {
        let touch = touchSnapshot()
        guard touch.count == 1 else { return false }
        let side: Side
        if touch.x <= edgeWidth { side = .left }
        else if touch.x >= 1 - edgeWidth { side = .right }
        else { return false }
        activeSide = side
        lock.lock(); gestureRunning = true; lock.unlock()
        startY = touch.y
        stepsApplied = 0
        quarterSteps = flags.contains(.maskShift) && flags.contains(.maskAlternate)
        CGAssociateMouseAndMouseCursorPosition(0)   // freeze the pointer while sliding
        haptic()
        return true
    }

    private func updateGesture(y: Float) {
        guard let side = activeSide else { return }
        let target = Int(((y - startY) / stepDistance).rounded(.towardZero))
        while stepsApplied != target {
            let up = target > stepsApplied
            stepsApplied += up ? 1 : -1
            switch side {
            case .right: MacSystemKeys.press(up ? .volumeUp : .volumeDown, quarter: quarterSteps)
            case .left: MacSystemKeys.press(up ? .brightnessUp : .brightnessDown, quarter: quarterSteps)
            }
            haptic()
        }
    }

    fileprivate var gestureActive: Bool { activeSide != nil }

    fileprivate func endGesture() {
        guard activeSide != nil else { return }
        activeSide = nil
        lock.lock(); gestureRunning = false; lock.unlock()
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func haptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    // MARK: Click interception

    private func installTap() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: edgeTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    private func removeTap() {
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        tapSource = nil
    }

    fileprivate func reEnableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    // MARK: Log

    static func log(_ text: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AirDoxx")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("edge-controls.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

// MARK: - Event tap / multitouch callbacks (C function pointers)

private func edgeTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                             refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let controls = EdgeControls.shared
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        controls.reEnableTap()
    case .leftMouseDown:
        if controls.beginGestureIfOnEdge(flags: event.flags) { return nil }
    case .leftMouseDragged:
        if controls.gestureActive { return nil }
    case .leftMouseUp:
        if controls.gestureActive { controls.endGesture(); return nil }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

private func edgeContactCallback(device: UnsafeMutableRawPointer?, touches: UnsafeMutableRawPointer?,
                                 count: Int32, timestamp: Double, frame: Int32) -> Int32 {
    EdgeControls.shared.handleFrame(touches, count: Int(count))
    return 0
}

// MARK: - MultitouchSupport bindings

private struct MTPoint { var x: Float; var y: Float }
private struct MTReadout { var pos: MTPoint; var vel: MTPoint }
/// Layout of one finger in a MultitouchSupport contact frame (96 bytes).
private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerID: Int32
    var handID: Int32
    var normalized: MTReadout
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolute: MTReadout
    var zero2: (Int32, Int32)
    var density: Float
}

private typealias MTContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

private enum Multitouch {
    typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    typealias Register = @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
    typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Void

    static var createList: CreateList?
    static var registerCallback: Register?
    static var start: Start?
    static var stop: Stop?

    static func load() -> Bool {
        if createList != nil { return true }
        guard MemoryLayout<MTTouch>.stride == 96,
              let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let a = dlsym(h, "MTDeviceCreateList"),
              let b = dlsym(h, "MTRegisterContactFrameCallback"),
              let c = dlsym(h, "MTDeviceStart"),
              let d = dlsym(h, "MTDeviceStop") else { return false }
        createList = unsafeBitCast(a, to: CreateList.self)
        registerCallback = unsafeBitCast(b, to: Register.self)
        start = unsafeBitCast(c, to: Start.self)
        stop = unsafeBitCast(d, to: Stop.self)
        return true
    }
}

// MARK: - Native Mac volume / brightness keys

/// Presses the Mac's own volume / brightness keys (synthetic HID events), so macOS applies its usual
/// steps and shows its native indicator. Events carry a marker so AirDoxx's key forwarding ignores them.
enum MacSystemKeys {
    enum Key: Int { case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7 }

    static func press(_ key: Key, quarter: Bool = false) {
        for down in [true, false] {
            var flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            if quarter { flags.formUnion([.shift, .option]) }
            let data1 = (key.rawValue << 16) | ((down ? 0xA : 0xB) << 8)
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                                 timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                                 data1: data1, data2: -1),
                  let cg = event.cgEvent else { continue }
            cg.setIntegerValueField(.eventSourceUserData, value: EdgeControls.syntheticMarker)
            cg.post(tap: .cghidEventTap)
        }
    }
}
