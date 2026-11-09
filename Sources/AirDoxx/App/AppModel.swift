import AppKit
import SwiftUI
import CoreMedia

enum MirrorState: Equatable {
    case missingADB
    case missingServer
    case searching
    case unauthorized(String)
    case choose([ADBDevice])
    case connecting(String)
    case mirroring(String)
    case failed(String, String)
}

/// Which window AirDoxx shows (mirrors iPhone Mirroring's behaviour).
enum Presentation: Equatable {
    case setup                 // first-run welcome / permissions / connect flow
    case phone                 // phone-shaped window (connecting spinner or live mirror)
    case unavailable(String)   // "Unable to Connect to Android Phone" window (detail text, may be empty)
    case disconnected(String)  // the user disconnected from this phone (name)
}

enum AirDoxxLinks {
    static let website = URL(string: "https://shanmuckh.github.io/AirDox/")!
    static let setupGuide = URL(string: "https://shanmuckh.github.io/AirDox/#setup")!
}

enum StreamQuality: String, CaseIterable {
    case high, balanced, saver

    var title: String {
        switch self {
        case .high: return "High (Full Resolution)"
        case .balanced: return "Balanced"
        case .saver: return "Data Saver"
        }
    }

    var maxSize: Int {
        switch self {
        case .high: return 0
        case .balanced: return 1920
        case .saver: return 1280
        }
    }

    var bitRate: Int {
        switch self {
        case .high: return 16_000_000
        case .balanced: return 8_000_000
        case .saver: return 4_000_000
        }
    }
}

/// App state machine: finds phones, starts/stops mirroring sessions, and handles
/// clipboard, screenshots, file drops and wireless connections.
final class AppModel: NSObject, ObservableObject {
    @Published private(set) var state: MirrorState = .searching
    @Published private(set) var devices: [ADBDevice] = []
    @Published private(set) var presentation: Presentation = .phone
    let notifications = NotificationBridge()
    private var searchStartedAt = Date()
    private var mdnsTick = 0

    var windowController: MirrorWindowController!
    private(set) var session: MirrorSession?

    private var pollTimer: Timer?
    private var polling = false
    private var autoConnect = true
    private var lastPasteboardChange = NSPasteboard.general.changeCount
    private var pendingWirelessSerial: String?
    /// USB serials we've already tried to move to Wi-Fi during this run.
    private var wirelessAttempted = Set<String>()
    private var reconnectAttempts = 0
    private let nowPlaying = NowPlayingBridge()
    private var secureMonitor: SecureScreenMonitor?
    private let work = DispatchQueue(label: "app.adb", qos: .userInitiated)
    private let defaults = UserDefaults.standard

    override init() {
        super.init()
        Self.migrateOldSettings()
        defaults.register(defaults: [
            "turnScreenOff": true,
            "audioEnabled": true,
            "quality": StreamQuality.high.rawValue,
            "autoWireless": true,
        ])
    }

    /// Earlier builds used the bundle id "local.androidmirroring.app"; carry their settings over.
    private static func migrateOldSettings() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedLegacySettings") else { return }
        d.set(true, forKey: "migratedLegacySettings")
        guard let old = UserDefaults(suiteName: "local.androidmirroring.app") else { return }
        for key in ["turnScreenOff", "audioEnabled", "quality", "autoWireless", "wirelessMap", "lastWirelessAddress"] {
            if let v = old.object(forKey: key), d.object(forKey: key) == nil { d.set(v, forKey: key) }
        }
        // A phone was already connected before: no need for the first-run setup.
        if old.object(forKey: "wirelessMap") != nil || old.object(forKey: "lastWirelessAddress") != nil {
            d.set(true, forKey: "setupComplete")
        }
    }

    var setupComplete: Bool {
        get { defaults.bool(forKey: "setupComplete") }
        set { defaults.set(newValue, forKey: "setupComplete") }
    }

    // MARK: - Settings

    /// true = "Mac only" (phone's own screen stays off); false = both screens show the phone.
    var turnScreenOff: Bool {
        get { defaults.bool(forKey: "turnScreenOff") }
        set {
            defaults.set(newValue, forKey: "turnScreenOff")
            applyScreenPower()
            windowController?.updateScreenModeButton(macOnly: newValue)
        }
    }

    var audioEnabled: Bool {
        get { defaults.bool(forKey: "audioEnabled") }
        set { defaults.set(newValue, forKey: "audioEnabled"); reconnectIfMirroring() }
    }

    var quality: StreamQuality {
        get { StreamQuality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .high }
        set { defaults.set(newValue.rawValue, forKey: "quality"); reconnectIfMirroring() }
    }

    /// Mirror over Wi-Fi automatically: a phone first seen over USB is switched to wireless adb,
    /// so the cable can be unplugged (like iPhone Mirroring).
    var autoWireless: Bool {
        get { defaults.bool(forKey: "autoWireless") }
        set { defaults.set(newValue, forKey: "autoWireless") }
    }

    /// Wi-Fi address ("ip:port") -> the phone's USB serial, to recognise one phone on two transports.
    private var wirelessMap: [String: String] {
        get { defaults.dictionary(forKey: "wirelessMap") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "wirelessMap") }
    }

    /// A phone has been connected before (so a failure most likely means Wireless debugging is off).
    var knowsAPhone: Bool { !wirelessMap.isEmpty || lastWirelessAddress != nil }

    var lastWirelessAddress: String? {
        get { defaults.string(forKey: "lastWirelessAddress") }
        set { defaults.set(newValue, forKey: "lastWirelessAddress") }
    }

    var isMirroring: Bool {
        if case .mirroring = state { return true }
        return false
    }

    // MARK: - Lifecycle

    func start() {
        presentation = setupComplete ? .phone : .setup
        searchStartedAt = Date()
        notifications.onOpen = { [weak self] pkg in self?.openAppOnPhone(pkg) }
        guard checkDependencies() else { presentation = .unavailable(""); return }
        // Reconnect to phones we've mirrored over Wi-Fi before (no cable needed).
        let addresses = Set(wirelessMap.keys).union(lastWirelessAddress.map { [$0] } ?? [])
        for address in addresses {
            work.async { _ = try? ADB.shared.run(["connect", address], timeout: 4) }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func shutdown() {
        restoreRotationIfNeeded(wait: true)
        session?.stop()
        session = nil
    }

    @discardableResult
    private func checkDependencies() -> Bool {
        if ADB.shared.path == nil { state = .missingADB; return false }
        if ScrcpyServer.locate() == nil { state = .missingServer; return false }
        return true
    }

    // MARK: - Windows (iPhone Mirroring–style flow)

    /// Lets the app delegate bring the phone window forward even when `presentation` is already .phone
    /// (e.g. the hub was opened from a menu).
    var onShowPhone: (() -> Void)?

    func tryAgain() {
        presentation = .phone
        onShowPhone?()
        retry()
    }

    func notNow() {
        NSApp.terminate(nil)
    }

    func learnMore() {
        NSWorkspace.shared.open(AirDoxxLinks.website)
    }

    func beginSetup() {
        presentation = .setup
        if state != .searching, session == nil { retry() }
    }

    /// Called by the setup flow once a phone is connected (or the user skips ahead).
    func finishSetup() {
        setupComplete = true
        presentation = .phone
        onShowPhone?()
        if session == nil { retry() }
    }

    func retry() {
        guard checkDependencies() else { presentation = .unavailable(""); return }
        autoConnect = true
        searchStartedAt = Date()
        state = .searching
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
        }
        poll()
    }

    private var isLookingForDevices: Bool {
        switch state {
        case .searching, .unauthorized, .choose: return true
        default: return false
        }
    }

    private var forgottenPhonesSnapshot: Set<String> = []
    private var pairingPromptShown = false

    private func phoneNeedsPairing() {
        guard !pairingPromptShown, session == nil, presentation != .setup else { return }
        pairingPromptShown = true
        presentation = .setup   // opens the Connect page with the pairing QR code
    }

    private func poll() {
        guard isLookingForDevices, !polling else { return }
        forgottenPhonesSnapshot = presentation == .setup ? [] : forgottenPhones
        polling = true
        mdnsTick += 1
        let discover = mdnsTick % 3 == 1
        work.async { [weak self] in
            // Phones paired via Wireless debugging advertise themselves on the network:
            // connect to them automatically (no pairing again, no cable).
            if discover {
                let connected = Set(((try? ADB.shared.devices()) ?? []).map(\.serial))
                let skip = self?.forgottenPhonesSnapshot ?? []
                for svc in ADB.shared.mdnsServices() where svc.type.hasPrefix("_adb-tls-connect") {
                    if connected.contains(svc.address) || connected.contains(where: { $0.hasPrefix(svc.name) }) { continue }
                    if let hw = svc.hardwareSerial, skip.contains(hw) { continue }
                    let out = (try? ADB.shared.run(["connect", svc.address], timeout: 5)) ?? ""
                    if !out.contains("connected to") {
                        // The phone is advertising Wireless debugging but rejects this Mac's key:
                        // it was only temporarily trusted. It needs to be paired (once, for good).
                        DispatchQueue.main.async { self?.phoneNeedsPairing() }
                    }
                }
            }
            let found = (try? ADB.shared.devices()) ?? []
            DispatchQueue.main.async {
                self?.polling = false
                self?.handle(found)
            }
        }
    }

    private func handle(_ found: [ADBDevice]) {
        devices = found
        guard isLookingForDevices else { return }
        var ready = dedupe(found.filter(\.isReady))
        let forgotten = forgottenPhones
        if !forgotten.isEmpty {
            if presentation == .setup {
                // Setting a phone up again un-forgets it.
                let back = Set(ready.map { hardwareSerial(of: $0) }).intersection(forgotten)
                if !back.isEmpty { forgottenPhones = forgotten.subtracting(back) }
            } else {
                ready.removeAll { forgotten.contains(hardwareSerial(of: $0)) }
            }
        }
        learnSerials(of: ready)

        if ready.isEmpty, !found.contains(where: \.isUnauthorized), presentation == .phone,
           Date().timeIntervalSince(searchStartedAt) > 7 {
            // Like iPhone Mirroring: after a short search, explain what's needed.
            presentation = .unavailable("")
        } else if !ready.isEmpty, case .unavailable = presentation, autoConnect {
            presentation = .phone
        }

        if let wanted = pendingWirelessSerial, let device = ready.first(where: { $0.serial == wanted }) {
            pendingWirelessSerial = nil
            connect(device)
            return
        }
        if ready.count == 1, autoConnect {
            startMirroring(ready[0])
        } else if !ready.isEmpty {
            if state != .choose(ready) { state = .choose(ready) }
        } else if let locked = found.first(where: \.isUnauthorized) {
            state = .unauthorized(locked.displayName)
        } else if state != .searching {
            state = .searching
        }
    }

    /// One phone can appear several times (USB, Wi-Fi 5555, Wireless debugging). Keep one entry
    /// per phone, preferring Wireless debugging, then Wi-Fi, then USB.
    private func dedupe(_ ready: [ADBDevice]) -> [ADBDevice] {
        func rank(_ d: ADBDevice) -> Int {
            d.serial.contains("._adb-tls-connect") ? 0 : (d.isWireless ? 1 : 2)
        }
        var best: [String: ADBDevice] = [:]
        var order: [String] = []
        for d in ready {
            let id = hardwareSerial(of: d)
            if let current = best[id] {
                if rank(d) < rank(current) { best[id] = d }
            } else {
                best[id] = d
                order.append(id)
            }
        }
        return order.compactMap { best[$0] }
    }

    private func hardwareSerial(of d: ADBDevice) -> String {
        if d.serial.hasPrefix("adb-") {
            let name = d.serial.components(separatedBy: "._adb").first ?? d.serial
            if let hw = ADB.MDNSService(name: name, type: "", address: "").hardwareSerial { return hw }
        }
        if let hw = wirelessMap[d.serial] { return hw }
        return d.serial
    }

    private var serialLookups = Set<String>()

    /// For Wi-Fi devices we don't know yet, ask for the hardware serial (for de-duplication).
    private func learnSerials(of ready: [ADBDevice]) {
        for d in ready where d.isWireless && !d.serial.hasPrefix("adb-")
            && wirelessMap[d.serial] == nil && !serialLookups.contains(d.serial) {
            serialLookups.insert(d.serial)
            work.async { [weak self] in
                guard let hw = (try? ADB.shared.run(["shell", "getprop", "ro.serialno"], serial: d.serial, timeout: 5))?.trimmed,
                      !hw.isEmpty else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    var map = self.wirelessMap
                    map[d.serial] = hw
                    self.wirelessMap = map
                }
            }
        }
    }

    func openAppOnPhone(_ pkg: String) {
        guard let serial = session?.device.serial else { return }
        work.async {
            _ = try? ADB.shared.run(["shell", "monkey", "-p", pkg, "-c", "android.intent.category.LAUNCHER", "1"],
                                    serial: serial, timeout: 8)
        }
        presentation = .phone
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Sessions

    /// Auto-connect path: moves a USB phone to Wi-Fi first (once per run) when enabled.
    private func startMirroring(_ device: ADBDevice) {
        guard autoWireless, !device.isWireless, !wirelessAttempted.contains(device.serial) else {
            connect(device)
            return
        }
        wirelessAttempted.insert(device.serial)
        state = .connecting("\(device.displayName) over Wi-Fi")
        enableWireless(for: device) { [weak self] address, message in
            guard let self else { return }
            if let address {
                self.pendingWirelessSerial = address
                self.state = .searching
                self.poll()
                self.pendingToast = "Wireless – you can unplug the cable"
            } else {
                self.connect(device)
                self.pendingToast = message
            }
        }
    }

    private var pendingToast: String?

    func connect(_ device: ADBDevice) {
        guard checkDependencies() else { return }
        session?.stop()

        // Wi-Fi: cap the bit rate to keep latency low on busy networks.
        let bitRate = device.isWireless ? min(quality.bitRate, 10_000_000) : quality.bitRate
        let options = MirrorOptions(maxSize: quality.maxSize, videoBitRate: bitRate, maxFps: 60,
                                    audio: audioEnabled, turnScreenOff: turnScreenOff)
        let newSession = MirrorSession(device: device, options: options)
        newSession.delegate = self

        let screen = windowController.screenView
        let renderer = screen.displayLayer.sampleBufferRenderer
        var debugFrames = 0
        newSession.onSampleBuffer = { sample in
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
                #if DEBUG
                FileHandle.standardError.write(Data("[render] flushing, error: \(String(describing: renderer.error))\n".utf8))
                #endif
                renderer.flush()
            }
            renderer.enqueue(sample)
            #if DEBUG
            debugFrames += 1
            if debugFrames == 180 {
                FileHandle.standardError.write(Data("[render] status=\(renderer.status.rawValue) (1=rendering, 2=failed)\n".utf8))
            }
            #endif
        }
        screen.session = newSession
        screen.delegate = self
        session = newSession
        autoConnect = true
        state = .connecting(device.displayName)
        newSession.start()
    }

    /// Ends mirroring. The phone stays paired: "Reconnect" (or the next launch) connects again.
    func disconnect() {
        guard let s = session else { return }
        restoreRotationIfNeeded(wait: true)
        let name = windowController.window?.title ?? s.device.displayName
        lastDevice = s.device
        s.stop()
        endSession(s)
        autoConnect = false
        state = .searching
        presentation = .disconnected(name)
    }

    func reconnect() {
        presentation = .phone
        onShowPhone?()
        if let device = lastDevice, devices.contains(where: { $0.serial == device.serial && $0.isReady }) {
            connect(device)
        } else {
            retry()
        }
    }

    /// Disconnects and forgets the phone: drops its saved Wi-Fi addresses, turns off its wireless
    /// debugging / Wi-Fi adb, and stops auto-connecting to it until it's set up again.
    func forgetPhone() {
        guard let device = session?.device ?? lastDevice else { return }
        let alert = NSAlert()
        alert.messageText = "Disconnect permanently from \(device.displayName)?"
        alert.informativeText = "AirDoxx will forget this phone and turn off its wireless connection. To use it again, set it up again with a cable or by scanning the pairing QR code."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Forget Phone")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let hw = hardwareSerial(of: device)
        restoreRotationIfNeeded(wait: true)
        if let s = session { s.stop(); endSession(s) }
        var forgotten = forgottenPhones
        forgotten.insert(hw)
        forgottenPhones = forgotten

        var map = wirelessMap
        let addresses = Set(map.filter { $0.value == hw }.map(\.key)).union(device.isWireless ? [device.serial] : [])
        for key in addresses { map.removeValue(forKey: key) }
        wirelessMap = map
        if let last = lastWirelessAddress, addresses.contains(last) { lastWirelessAddress = nil }
        let liveSerials = devices.filter { hardwareSerial(of: $0) == hw && $0.isReady }.map(\.serial)

        work.async {
            let adb = ADB.shared
            if let any = liveSerials.first {
                _ = try? adb.run(["shell", "settings", "put", "global", "adb_wifi_enabled", "0"], serial: any, timeout: 5)
                if let wifi = liveSerials.first(where: { $0.contains(":") }) {
                    _ = try? adb.run(["usb"], serial: wifi, timeout: 5)   // leave Wi-Fi adb (port 5555) mode
                }
            }
            for address in addresses.union(liveSerials.filter { $0.contains(":") || $0.contains("._adb") }) {
                _ = try? adb.run(["disconnect", address], timeout: 5)
            }
        }
        lastDevice = nil
        autoConnect = false
        setupComplete = false
        state = .searching
        presentation = .setup
    }

    private var lastDevice: ADBDevice?

    /// Hardware serials the user asked to forget. Cleared when they set the phone up again.
    private var forgottenPhones: Set<String> {
        get { Set(defaults.stringArray(forKey: "forgottenPhones") ?? []) }
        set { defaults.set(Array(newValue), forKey: "forgottenPhones") }
    }

    private func endSession(_ s: MirrorSession) {
        guard session === s else { return }
        session = nil
        nowPlaying.deactivate()
        notifications.stop()
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        secureMonitor?.stop()
        secureMonitor = nil
        phoneLocked = false
        phoneShowsSecureScreen = false
        windowController.showProtectedNotice(false)
        windowController.screenView.session = nil
        windowController.showMirroring(false)
        windowController.window?.title = "AirDoxx"
    }

    private func reconnectIfMirroring() {
        guard let device = session?.device else { return }
        connect(device)
    }

    // MARK: - Phone actions

    func pressKey(_ keycode: UInt32, meta: UInt32 = 0) { session?.pressKey(keycode, meta: meta) }
    func send(_ message: Data) { session?.send(message) }

    func toggleScreenMode() {
        turnScreenOff.toggle()
        windowController.showToast(turnScreenOff ? "Mac only – phone screen off" : "Showing on both screens")
    }

    // MARK: - Rotation
    //
    // Rotating the display isn't enough: apps such as YouTube lock their screens to portrait and
    // Android honours that over a frozen rotation. So "landscape" also tells the display to ignore
    // apps' orientation requests (Android 12L+). Everything is restored on portrait, disconnect,
    // quit, or (after a dropped connection) the next time the phone connects.

    private struct SavedRotation: Codable { var serial: String; var accelerometer: String; var userRotation: String }

    private var savedRotation: SavedRotation? {
        get { (defaults.data(forKey: "savedRotation")).flatMap { try? JSONDecoder().decode(SavedRotation.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "savedRotation") }
    }

    var isForcedLandscape: Bool { savedRotation != nil }

    func rotatePhone() {
        guard let serial = session?.device.serial else { return }
        if let saved = savedRotation {
            savedRotation = nil
            work.async { Self.restoreRotation(saved, serial: serial) }
            windowController.showToast("Portrait")
        } else {
            work.async { [weak self] in
                let adb = ADB.shared
                let accel = (try? adb.run(["shell", "settings", "get", "system", "accelerometer_rotation"], serial: serial, timeout: 5))?.trimmed ?? "1"
                let user = (try? adb.run(["shell", "settings", "get", "system", "user_rotation"], serial: serial, timeout: 5))?.trimmed ?? "0"
                let saved = SavedRotation(serial: serial, accelerometer: accel, userRotation: user)
                DispatchQueue.main.async { self?.savedRotation = saved }
                _ = try? adb.run(["shell", "wm set-ignore-orientation-request true; settings put system accelerometer_rotation 0; settings put system user_rotation 1"],
                                 serial: serial, timeout: 8)
            }
            windowController.showToast("Landscape")
        }
    }

    private static func restoreRotation(_ saved: SavedRotation, serial: String) {
        let accel = ["0", "1"].contains(saved.accelerometer) ? saved.accelerometer : "1"
        let user = ["0", "1", "2", "3"].contains(saved.userRotation) ? saved.userRotation : "0"
        _ = try? ADB.shared.run(["shell", "wm set-ignore-orientation-request false; settings put system user_rotation \(user); settings put system accelerometer_rotation \(accel)"],
                                serial: serial, timeout: 8)
    }

    /// Undo a forced landscape (synchronously when quitting).
    func restoreRotationIfNeeded(wait: Bool = false) {
        guard let saved = savedRotation else { return }
        let serial = session?.device.serial ?? saved.serial
        savedRotation = nil
        if wait { Self.restoreRotation(saved, serial: serial) }
        else { work.async { Self.restoreRotation(saved, serial: serial) } }
    }

    // The phone's own screen is on when the user wants both screens, or while the phone is
    // locked (so its fingerprint sensor / lock screen can be used) or showing a protected screen.
    private var phoneLocked = false
    private var phoneShowsSecureScreen = false

    private func applyScreenPower() {
        guard let s = session, isMirroring else { return }
        let on = !turnScreenOff || phoneLocked || phoneShowsSecureScreen
        if on == s.isScreenOff { s.setScreenPower(on: on) }
    }

    func pasteFromMac() {
        guard let s = session, let text = NSPasteboard.general.string(forType: .string) else { return }
        s.setClipboard(text, paste: true)
        lastPasteboardChange = NSPasteboard.general.changeCount
    }

    /// Push the Mac clipboard to the phone (without pasting) when the user comes back to the app.
    /// Universal clipboard: anything copied on the Mac is sent to the phone (phone -> Mac is pushed
    /// by the phone itself whenever its clipboard changes).
    var universalClipboard: Bool {
        get { defaults.object(forKey: "universalClipboard") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "universalClipboard") }
    }

    private var clipboardTimer: Timer?

    private func startClipboardSync() {
        clipboardTimer?.invalidate()
        lastPasteboardChange = NSPasteboard.general.changeCount
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self, self.universalClipboard else { return }
            self.syncClipboardToPhone()
        }
    }

    func syncClipboardToPhone() {
        let pb = NSPasteboard.general
        guard let s = session, pb.changeCount != lastPasteboardChange,
              let text = pb.string(forType: .string) else { return }
        lastPasteboardChange = pb.changeCount
        s.setClipboard(text, paste: false)
    }

    func takeScreenshot() {
        guard let serial = session?.device.serial else { return }
        work.async { [weak self] in
            do {
                let png = try ADB.shared.runData(["exec-out", "screencap", "-p"], serial: serial,
                                                 timeout: 20, mergeStderr: false)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
                let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
                let url = desktop.appendingPathComponent("Android Screenshot \(formatter.string(from: Date())).png")
                try png.write(to: url)
                DispatchQueue.main.async { self?.windowController.showToast("Screenshot saved to Desktop") }
            } catch {
                DispatchQueue.main.async { self?.windowController.showToast("Screenshot failed") }
            }
        }
    }

    // MARK: - Protected (secure) screens

    private func startSecureMonitor(for session: MirrorSession) {
        secureMonitor?.stop()
        let monitor = SecureScreenMonitor(serial: session.device.serial)
        monitor.onChange = { [weak self, weak session] state in
            guard let self, let session, session === self.session else { return }
            let wasLocked = self.phoneLocked
            self.phoneLocked = state.locked
            self.phoneShowsSecureScreen = state.secure && !state.locked
            self.windowController.showProtectedNotice(self.phoneShowsSecureScreen)
            if state.locked && !wasLocked {
                self.windowController.showToast("Phone is locked – unlock it on the phone or type the PIN here")
            }
            self.applyScreenPower()
        }
        monitor.start()
        secureMonitor = monitor
    }

    // MARK: - Mac special keys -> phone

    func handleMacKey(_ key: MacKeyInterceptor.Key, down: Bool, isRepeat: Bool) {
        guard let s = session else { return }
        func hold(_ code: UInt32) {
            s.send(ControlMessage.keycode(down ? .down : .up, code, repeat: isRepeat ? 1 : 0))
            if !down { s.noteUserInput() }
        }
        switch key {
        case .volumeUp: hold(AndroidKey.volumeUp)
        case .volumeDown: hold(AndroidKey.volumeDown)
        case .mute: hold(AndroidKey.volumeMute)
        case .brightnessUp: hold(221)          // KEYCODE_BRIGHTNESS_UP
        case .brightnessDown: hold(220)        // KEYCODE_BRIGHTNESS_DOWN
        case .playPause: hold(85)              // KEYCODE_MEDIA_PLAY_PAUSE
        case .next: hold(87)                   // KEYCODE_MEDIA_NEXT
        case .previous: hold(88)               // KEYCODE_MEDIA_PREVIOUS
        case .missionControl:
            if down && !isRepeat { s.pressKey(AndroidKey.appSwitch) }
        case .dictation:
            if down && !isRepeat { s.pressKey(231) } // KEYCODE_VOICE_ASSIST
        case .doNotDisturb:
            if down && !isRepeat { toggleDoNotDisturb() }
        case .search:
            guard down && !isRepeat else { return }
            windowController.showToast("Searching…")
            PhoneSearch.run(serial: s.device.serial) { [weak self] message in
                self?.windowController.showToast(message)
            }
        }
    }

    func toggleDoNotDisturb() {
        guard let serial = session?.device.serial else { return }
        work.async { [weak self] in
            let adb = ADB.shared
            let zen = (try? adb.run(["shell", "settings", "get", "global", "zen_mode"], serial: serial, timeout: 5))?.trimmed ?? "0"
            let turnOn = zen == "0"
            let ok = (try? adb.run(["shell", "cmd", "notification", "set_dnd", turnOn ? "priority" : "off"],
                                   serial: serial, timeout: 5)) != nil
            DispatchQueue.main.async {
                self?.windowController.showToast(ok ? (turnOn ? "Do Not Disturb on" : "Do Not Disturb off")
                                                    : "Couldn't change Do Not Disturb")
            }
        }
    }

    // MARK: - Wireless

    /// Puts a USB-connected phone into wireless adb (port 5555) and connects to it over Wi-Fi.
    /// Completion (main thread): the "ip:port" serial on success, else nil and a message.
    private func enableWireless(for device: ADBDevice, completion: @escaping (String?, String) -> Void) {
        work.async { [weak self] in
            let adb = ADB.shared
            func finish(_ address: String?, _ message: String) {
                DispatchQueue.main.async { completion(address, message) }
            }
            guard let ip = adb.wifiAddress(serial: device.serial) else {
                finish(nil, "Using USB – the phone isn't on Wi-Fi")
                return
            }
            let address = "\(ip):5555"
            // Skip the adbd restart if wireless adb is already listening.
            let port = (try? adb.run(["shell", "getprop", "service.adb.tcp.port"], serial: device.serial, timeout: 5))?.trimmed
            if port != "5555" {
                _ = try? adb.run(["tcpip", "5555"], serial: device.serial, timeout: 10)
                Thread.sleep(forTimeInterval: 2)
            }
            for _ in 0..<6 {
                if let out = try? adb.run(["connect", address], timeout: 6),
                   out.contains("connected to"),
                   (try? adb.devices())?.contains(where: { $0.serial == address && $0.isReady }) == true {
                    DispatchQueue.main.async {
                        var map = self?.wirelessMap ?? [:]
                        map[address] = device.serial
                        self?.wirelessMap = map
                        self?.lastWirelessAddress = address
                    }
                    finish(address, "Connected over Wi-Fi at \(address). You can unplug the cable.")
                    return
                }
                Thread.sleep(forTimeInterval: 1)
            }
            finish(nil, "Using USB – couldn't reach the phone over Wi-Fi")
        }
    }

    /// "Switch to Wi-Fi" button in the wireless window.
    func switchToWireless(completion: @escaping (String) -> Void) {
        let usbDevice = session.map(\.device).flatMap { $0.isWireless ? nil : $0 }
            ?? devices.first { $0.isReady && !$0.isWireless }
        guard let device = usbDevice else {
            completion(session?.device.isWireless == true
                       ? "Already mirroring over Wi-Fi."
                       : "Connect your phone with a USB cable first.")
            return
        }
        if let s = session { s.stop(); endSession(s) }
        wirelessAttempted.insert(device.serial)
        state = .connecting("\(device.displayName) over Wi-Fi")
        enableWireless(for: device) { [weak self] address, message in
            guard let self else { return }
            if let address {
                self.pendingWirelessSerial = address
                self.state = .searching
                self.poll()
            } else {
                self.connect(device)
            }
            completion(message)
        }
    }

    /// After a Wi-Fi hiccup, quietly reconnect instead of showing an error.
    private func reconnectWireless(_ device: ADBDevice, error: String) {
        reconnectAttempts += 1
        state = .connecting("Reconnecting to \(device.displayName)")
        work.async { [weak self] in
            var ok = false
            for _ in 0..<8 {
                _ = try? ADB.shared.run(["connect", device.serial], timeout: 5)
                if (try? ADB.shared.devices())?.contains(where: { $0.serial == device.serial && $0.isReady }) == true {
                    ok = true
                    break
                }
                Thread.sleep(forTimeInterval: 2)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if ok {
                    self.connect(device)
                } else {
                    self.state = .failed("Your Android phone is not available",
                                         "Lost the Wi-Fi connection. Make sure the phone is unlocked once and on the same Wi-Fi as this Mac, or plug it in with USB.\n\n\(error)")
                    if self.presentation != .setup { self.presentation = .unavailable("") }
                }
            }
        }
    }

    func pair(address: String, code: String, completion: @escaping (String) -> Void) {
        work.async {
            let result: String
            do {
                result = try ADB.shared.run(["pair", address.trimmed, code.trimmed], timeout: 20).trimmed
            } catch {
                result = error.localizedDescription
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func connectWireless(address: String, completion: @escaping (String) -> Void) {
        let addr = address.trimmed
        work.async { [weak self] in
            let out = (try? ADB.shared.run(["connect", addr], timeout: 10).trimmed) ?? "Failed to connect."
            DispatchQueue.main.async {
                if out.contains("connected to") {
                    self?.lastWirelessAddress = addr
                    self?.pendingWirelessSerial = addr
                    if self?.session == nil { self?.retry() }
                }
                completion(out)
            }
        }
    }

    func showWirelessSheet() {
        WirelessWindowController.shared.show(model: self)
    }

    func showUSBDebuggingHelp() {
        NSWorkspace.shared.open(AirDoxxLinks.setupGuide)
    }
}

// MARK: - MirrorSessionDelegate

extension AppModel: MirrorSessionDelegate {
    func sessionDidStart(_ session: MirrorSession, deviceName: String) {
        guard session === self.session else { return }
        let name = deviceName.isEmpty ? session.device.displayName : deviceName
        lastDevice = session.device
        state = .mirroring(name)
        reconnectAttempts = 0
        if presentation != .phone {
            if presentation == .setup { setupComplete = true }
            presentation = .phone
        }
        notifications.start(serial: session.device.serial)
        restoreRotationIfNeeded()   // a previous session may have ended while in forced landscape
        NotificationBridge.isDenied { [weak self] denied in
            guard denied else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                self?.windowController.showToast("Phone notifications are off – Phone › Permissions…")
            }
        }
        startClipboardSync()
        startSecureMonitor(for: session)
        nowPlaying.onKey = { [weak self] code in self?.session?.pressKey(code) }
        nowPlaying.activate(title: name)
        if let toast = pendingToast {
            pendingToast = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
                self?.windowController.showToast(toast)
            }
        }
        windowController.window?.title = name
        windowController.showMirroring(true)
        // The user may have switched modes since this session was configured.
        applyScreenPower()
        if turnScreenOff {
            windowController.showToast("Mac only – phone screen off")
        }
    }

    func session(_ session: MirrorSession, videoSizeDidChange size: CGSize) {
        guard session === self.session else { return }
        windowController.setVideoSize(size)
    }

    func session(_ session: MirrorSession, didEndWithError error: String?) {
        guard session === self.session else { return }
        endSession(session)
        let detail = error ?? ""
        if session.device.isWireless, reconnectAttempts < 3 {
            reconnectWireless(session.device, error: detail)
            return
        }
        autoConnect = false
        let headline = detail.contains("Unknown server option") || detail.contains("version")
            ? "Mirroring component version mismatch"
            : "Your Android phone is not available"
        state = .failed(headline, detail)
        if presentation != .setup { presentation = .unavailable(detail) }
    }

    func session(_ session: MirrorSession, didReceiveClipboard text: String) {
        let pb = NSPasteboard.general
        guard pb.string(forType: .string) != text else { return }
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastPasteboardChange = pb.changeCount
        if universalClipboard { windowController.showToast("Copied from phone") }
    }
}

// MARK: - File drops

extension AppModel: PhoneScreenViewDelegate {
    func phoneScreenPaste(_ view: PhoneScreenView) { pasteFromMac() }

    func phoneScreen(_ view: PhoneScreenView, didReceiveDroppedFiles urls: [URL]) {
        guard let s = session else { return }
        let serial = s.device.serial
        for url in urls {
            let name = url.lastPathComponent
            if url.pathExtension.lowercased() == "apk" {
                windowController.showToast("Installing \(name)…")
                work.async { [weak self] in
                    let ok = (try? ADB.shared.run(["install", "-r", url.path], serial: serial, timeout: 300))?
                        .contains("Success") ?? false
                    DispatchQueue.main.async {
                        self?.windowController.showToast(ok ? "Installed \(name)" : "Couldn't install \(name)")
                    }
                }
            } else {
                windowController.showToast("Copying \(name)…")
                let remote = "/sdcard/Download/\(name)"
                work.async { [weak self] in
                    let ok = (try? ADB.shared.run(["push", url.path, remote], serial: serial, timeout: 600)) != nil
                    if ok { s.send(ControlMessage.scanFile(remote)) }
                    DispatchQueue.main.async {
                        self?.windowController.showToast(ok ? "Saved \(name) to Downloads" : "Couldn't copy \(name)")
                    }
                }
            }
        }
    }
}
