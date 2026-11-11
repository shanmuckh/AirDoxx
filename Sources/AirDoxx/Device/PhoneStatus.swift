import Foundation

/// Polls the phone for ambient status shown in the toolbar: battery %, charging, and Wi-Fi/mobile signal.
final class PhoneStatus {
    struct Snapshot: Equatable {
        var batteryLevel: Int = -1     // 0...100, -1 unknown
        var charging = false
        var onWiFi = false
        var signal = -1                // 0...4 bars, -1 unknown
    }

    var onChange: ((Snapshot) -> Void)?   // main thread
    /// The phone hasn't answered several checks in a row (main thread, once).
    var onUnreachable: (() -> Void)?
    private var failures = 0
    private let serial: String
    private var timer: DispatchSourceTimer?
    private var busy = false
    private var last = Snapshot()

    init(serial: String) { self.serial = serial }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 0.5, repeating: 8)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func poll() {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard let out = try? ADB.shared.run(
            ["shell", "dumpsys battery | grep -E 'level|AC |USB |Wireless powered'; echo ---; dumpsys telephony.registry | grep -m1 mSignalStrength; echo ---; dumpsys wifi | grep -m1 'mWifiInfo'"],
            serial: serial, timeout: 6) else {
            failures += 1
            if failures == 3 { DispatchQueue.main.async { self.onUnreachable?() } }
            return
        }
        failures = 0

        var snap = Snapshot()
        let sections = out.components(separatedBy: "---")
        // Battery
        for line in (sections.first ?? "").split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("level:"), let v = Int(t.dropFirst(6).trimmingCharacters(in: .whitespaces)) { snap.batteryLevel = v }
            if (t.hasPrefix("AC ") || t.hasPrefix("USB ") || t.hasPrefix("Wireless")) && t.contains("true") { snap.charging = true }
        }
        // Wi-Fi: SSID present and not "<unknown ssid>"
        let wifi = sections.count > 2 ? sections[2] : ""
        snap.onWiFi = wifi.contains("SSID:") && !wifi.contains("<unknown ssid>") && !wifi.lowercased().contains("ssid: <none>")
        // Signal bars (0...4) from the level token in mSignalStrength, when present.
        let sig = sections.count > 1 ? sections[1] : ""
        if let r = sig.range(of: "level="), let bar = Int(sig[r.upperBound...].prefix { $0.isNumber }) {
            snap.signal = min(4, bar)
        } else if snap.onWiFi {
            snap.signal = 4
        }

        guard snap != last else { return }
        last = snap
        DispatchQueue.main.async { self.onChange?(snap) }
    }
}
