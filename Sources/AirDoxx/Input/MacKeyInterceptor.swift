import AppKit
import ApplicationServices

/// Captures the Mac's special keys (volume, brightness, media, Spotlight/search, Mission Control,
/// dictation, F1–F12) before macOS acts on them, so they can be forwarded to the phone while the
/// mirroring window is in front. macOS handles these keys itself before any app sees them, so this
/// needs a session event tap, which needs the Accessibility permission.
final class MacKeyInterceptor {
    enum Key: String {
        case volumeUp, volumeDown, mute
        case brightnessUp, brightnessDown
        case playPause, next, previous
        case missionControl, search, dictation, doNotDisturb
    }

    /// Return true to swallow the key (it then never reaches macOS).
    var handler: ((Key, _ down: Bool, _ isRepeat: Bool) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?

    var isActive: Bool { tap != nil }

    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow Accessibility" prompt (once per app identity).
    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Starts the tap now if permitted, otherwise keeps checking until the user grants permission.
    func start() {
        guard tap == nil else { return }
        if installTap() { return }
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            if self?.installTap() == true { timer.invalidate() }
        }
    }

    private func installTap() -> Bool {
        guard tap == nil else { return true }
        guard Self.hasPermission else { return false }
        let mask: CGEventMask = (1 << 14) // NX_SYSDEFINED: media / brightness keys
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: interceptorCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    fileprivate func reEnable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Diagnostics: AM_KEYLOG=/path/file.log records every special key the tap sees.
    private let keyLog: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["AM_KEYLOG"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    private func log(_ text: String) {
        keyLog?.write(Data((text + "\n").utf8))
    }

    /// Returns true if the event should be swallowed.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        // Mac volume/brightness steps posted by the trackpad edge controls go to the Mac, not the phone.
        if event.getIntegerValueField(.eventSourceUserData) == EdgeControls.syntheticMarker { return false }
        if keyLog != nil {
            if type.rawValue == 14, let ns = NSEvent(cgEvent: event) {
                log("sysdefined subtype=\(ns.subtype.rawValue) code=\((ns.data1 & 0xFFFF0000) >> 16) state=\(String(format: "%x", (ns.data1 & 0xFF00) >> 8))")
            } else {
                log("\(type == .keyDown ? "keyDown" : "keyUp") keycode=\(event.getIntegerValueField(.keyboardEventKeycode)) flags=\(String(format: "%llx", event.flags.rawValue))")
            }
        }
        if type.rawValue == 14 {
            guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
            let data = ns.data1
            let code = (data & 0xFFFF_0000) >> 16
            let flags = data & 0xFFFF
            let down = ((flags & 0xFF00) >> 8) == 0x0A
            let isRepeat = (flags & 0x1) == 1
            let key: Key?
            switch code {
            case 0: key = .volumeUp            // NX_KEYTYPE_SOUND_UP
            case 1: key = .volumeDown          // NX_KEYTYPE_SOUND_DOWN
            case 2: key = .brightnessUp        // NX_KEYTYPE_BRIGHTNESS_UP
            case 3: key = .brightnessDown      // NX_KEYTYPE_BRIGHTNESS_DOWN
            case 7: key = .mute                // NX_KEYTYPE_MUTE
            case 16: key = .playPause          // NX_KEYTYPE_PLAY
            case 17, 19: key = .next           // NX_KEYTYPE_NEXT / FAST
            case 18, 20: key = .previous       // NX_KEYTYPE_PREVIOUS / REWIND
            default: key = nil
            }
            guard let key else { return false }
            return handler?(key, down, isRepeat) ?? false
        }

        guard type == .keyDown || type == .keyUp else { return false }
        // Only bare keys: leave ⌘/⌃/⌥ shortcuts to macOS and the app's menus.
        let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate])
        guard mods.isEmpty else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let key: Key?
        switch keyCode {
        case 160: key = .missionControl        // Mission Control key (F3)
        case 177, 131: key = .search           // Spotlight key (F4) / Launchpad key on older Macs
        case 176: key = .dictation             // Dictation key (F5)
        case 178: key = .doNotDisturb          // Do Not Disturb key (F6)
        // Standard F-keys (when "Use F1, F2, etc. keys as standard function keys" is on)
        case 122: key = .brightnessDown        // F1
        case 120: key = .brightnessUp          // F2
        case 99: key = .missionControl         // F3
        case 118: key = .search                // F4
        case 96: key = .dictation              // F5
        case 97: key = .doNotDisturb           // F6
        case 98: key = .previous               // F7
        case 100: key = .playPause             // F8
        case 101: key = .next                  // F9
        case 109: key = .mute                  // F10
        case 103: key = .volumeDown            // F11
        case 111: key = .volumeUp              // F12
        default: key = nil
        }
        guard let key else { return false }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        return handler?(key, type == .keyDown, isRepeat) ?? false
    }
}

private func interceptorCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let interceptor = Unmanaged<MacKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        interceptor.reEnable()
        return Unmanaged.passUnretained(event)
    }
    return interceptor.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}
