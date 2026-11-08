import Foundation

/// Serializers for scrcpy 5.x client -> device control messages.
/// All integers are big-endian. Layouts follow app/src/control_msg.c at tag v5.0.1.
enum ControlMessage {
    enum KeyAction: UInt8 { case down = 0, up = 1 }
    enum MotionAction: UInt8 { case down = 0, up = 1, move = 2 }

    static let pointerMouse: UInt64 = UInt64.max            // -1
    static let pointerGenericFinger: UInt64 = UInt64.max - 1 // -2
    static let pointerVirtualFinger: UInt64 = UInt64.max - 2 // -3

    static let injectTextMaxLength = 300

    private enum MsgType: UInt8 {
        case injectKeycode = 0
        case injectText = 1
        case injectTouch = 2
        case injectScroll = 3
        case backOrScreenOn = 4
        case expandNotificationPanel = 5
        case expandSettingsPanel = 6
        case collapsePanels = 7
        case getClipboard = 8
        case setClipboard = 9
        case setDisplayPower = 10
        case rotateDevice = 11
        case openHardKeyboardSettings = 15
        case startApp = 16
        case resetVideo = 17
        case scanFile = 22
    }

    static func keycode(_ action: KeyAction, _ keycode: UInt32, repeat rep: UInt32 = 0, meta: UInt32 = 0) -> Data {
        var w = ByteWriter()
        w.u8(MsgType.injectKeycode.rawValue)
        w.u8(action.rawValue)
        w.u32(keycode)
        w.u32(rep)
        w.u32(meta)
        return w.data
    }

    /// Splits text into chunks of at most 300 UTF-8 bytes on character boundaries.
    static func text(_ string: String) -> [Data] {
        var messages: [Data] = []
        var chunk = ""
        var chunkBytes = 0
        func flush() {
            guard !chunk.isEmpty else { return }
            let bytes = Data(chunk.utf8)
            var w = ByteWriter()
            w.u8(MsgType.injectText.rawValue)
            w.u32(UInt32(bytes.count))
            w.bytes(bytes)
            messages.append(w.data)
            chunk = ""
            chunkBytes = 0
        }
        for ch in string {
            let n = String(ch).utf8.count
            if chunkBytes + n > injectTextMaxLength { flush() }
            chunk.append(ch)
            chunkBytes += n
        }
        flush()
        return messages
    }

    static func touch(_ action: MotionAction, pointerId: UInt64, x: Int32, y: Int32,
                      width: UInt16, height: UInt16, pressure: Float,
                      actionButton: UInt32 = 0, buttons: UInt32 = 0) -> Data {
        var w = ByteWriter()
        w.u8(MsgType.injectTouch.rawValue)
        w.u8(action.rawValue)
        w.u64(pointerId)
        w.i32(x)
        w.i32(y)
        w.u16(width)
        w.u16(height)
        w.u16(floatToU16FixedPoint(pressure))
        w.u32(actionButton)
        w.u32(buttons)
        return w.data
    }

    /// hscroll / vscroll are in "wheel notches", range [-16, 16].
    static func scroll(x: Int32, y: Int32, width: UInt16, height: UInt16,
                       hscroll: Float, vscroll: Float, buttons: UInt32 = 0) -> Data {
        var w = ByteWriter()
        w.u8(MsgType.injectScroll.rawValue)
        w.i32(x)
        w.i32(y)
        w.u16(width)
        w.u16(height)
        w.i16(floatToI16FixedPoint(max(-1, min(1, hscroll / 16))))
        w.i16(floatToI16FixedPoint(max(-1, min(1, vscroll / 16))))
        w.u32(buttons)
        return w.data
    }

    static func backOrScreenOn(_ action: KeyAction) -> Data {
        Data([MsgType.backOrScreenOn.rawValue, action.rawValue])
    }

    static var expandNotificationPanel: Data { Data([MsgType.expandNotificationPanel.rawValue]) }
    static var expandSettingsPanel: Data { Data([MsgType.expandSettingsPanel.rawValue]) }
    static var collapsePanels: Data { Data([MsgType.collapsePanels.rawValue]) }
    static var rotateDevice: Data { Data([MsgType.rotateDevice.rawValue]) }
    static var resetVideo: Data { Data([MsgType.resetVideo.rawValue]) }
    static var openHardKeyboardSettings: Data { Data([MsgType.openHardKeyboardSettings.rawValue]) }

    /// copyKey: 0 = none, 1 = copy, 2 = cut
    static func getClipboard(copyKey: UInt8) -> Data {
        Data([MsgType.getClipboard.rawValue, copyKey])
    }

    static func setClipboard(sequence: UInt64, paste: Bool, text: String) -> Data {
        var bytes = Data(text.utf8)
        let maxLen = (1 << 18) - 14
        if bytes.count > maxLen { bytes = bytes.prefix(maxLen) }
        var w = ByteWriter()
        w.u8(MsgType.setClipboard.rawValue)
        w.u64(sequence)
        w.u8(paste ? 1 : 0)
        w.u32(UInt32(bytes.count))
        w.bytes(bytes)
        return w.data
    }

    static func setDisplayPower(_ on: Bool) -> Data {
        Data([MsgType.setDisplayPower.rawValue, on ? 1 : 0])
    }

    static func startApp(_ name: String) -> Data {
        let bytes = Data(name.utf8.prefix(255))
        var w = ByteWriter()
        w.u8(MsgType.startApp.rawValue)
        w.u8(UInt8(bytes.count))
        w.bytes(bytes)
        return w.data
    }

    static func scanFile(_ path: String) -> Data {
        let bytes = Data(path.utf8.prefix(256))
        var w = ByteWriter()
        w.u8(MsgType.scanFile.rawValue)
        w.u32(UInt32(bytes.count))
        w.bytes(bytes)
        return w.data
    }

    private static func floatToU16FixedPoint(_ f: Float) -> UInt16 {
        let clamped = max(0, min(1, f))
        let u = UInt32(clamped * 65536)
        return u >= 0xFFFF ? 0xFFFF : UInt16(u)
    }

    private static func floatToI16FixedPoint(_ f: Float) -> Int16 {
        var i = Int32(f * 32768)
        if i >= 0x7FFF { i = 0x7FFF }
        if i < -0x8000 { i = -0x8000 }
        return Int16(i)
    }
}

/// Android key codes and meta states (android/keycodes.h, android/input.h).
enum AndroidKey {
    static let home: UInt32 = 3
    static let back: UInt32 = 4
    static let dpadUp: UInt32 = 19
    static let dpadDown: UInt32 = 20
    static let dpadLeft: UInt32 = 21
    static let dpadRight: UInt32 = 22
    static let volumeUp: UInt32 = 24
    static let volumeDown: UInt32 = 25
    static let power: UInt32 = 26
    static let tab: UInt32 = 61
    static let space: UInt32 = 62
    static let enter: UInt32 = 66
    static let del: UInt32 = 67
    static let menu: UInt32 = 82
    static let pageUp: UInt32 = 92
    static let pageDown: UInt32 = 93
    static let escape: UInt32 = 111
    static let forwardDel: UInt32 = 112
    static let moveHome: UInt32 = 122
    static let moveEnd: UInt32 = 123
    static let volumeMute: UInt32 = 164
    static let appSwitch: UInt32 = 187

    static let metaShift: UInt32 = 0x01 | 0x40      // SHIFT_ON | SHIFT_LEFT_ON
    static let metaAlt: UInt32 = 0x02 | 0x10        // ALT_ON | ALT_LEFT_ON
    static let metaCtrl: UInt32 = 0x1000 | 0x2000   // CTRL_ON | CTRL_LEFT_ON
    static let metaMeta: UInt32 = 0x10000 | 0x20000 // META_ON | META_LEFT_ON

    /// a-z -> KEYCODE_A (29)..., 0-9 -> KEYCODE_0 (7)...
    static func keycode(forCharacter c: Character) -> UInt32? {
        guard let scalar = c.lowercased().unicodeScalars.first, c.lowercased().unicodeScalars.count == 1 else { return nil }
        let v = scalar.value
        if v >= 0x61 && v <= 0x7A { return 29 + (v - 0x61) }
        if v >= 0x30 && v <= 0x39 { return 7 + (v - 0x30) }
        return nil
    }
}
