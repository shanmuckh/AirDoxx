import AppKit
import CoreImage

/// Android 11+ "Pair device with QR code" (the same flow Android Studio uses):
/// AirDoxx shows a QR code holding a service name and password; the phone scans it and
/// advertises a pairing service with that name over mDNS; AirDoxx then runs `adb pair`.
/// After pairing once, the phone is trusted and reconnects automatically over Wi-Fi.
final class WirelessPairing {
    let serviceName: String
    let password: String
    private var timer: Timer?
    private var pairing = false
    private(set) var finished = false

    /// Status updates on the main thread.
    var onStatus: ((String) -> Void)?
    /// Called once on success with the connected device serial (ip:port).
    var onPaired: ((String) -> Void)?

    init() {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        serviceName = "AirDoxx-" + String((0..<6).map { _ in chars.randomElement()! })
        password = String((0..<8).map { _ in chars.randomElement()! })
    }

    var qrPayload: String { "WIFI:T:ADB;S:\(serviceName);P:\(password);;" }

    func qrImage(size: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(qrPayload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !pairing, !finished else { return }
        pairing = true
        let name = serviceName, password = password
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let adb = ADB.shared
            defer { DispatchQueue.main.async { self?.pairing = false } }
            guard let service = adb.mdnsServices().first(where: { $0.type.hasPrefix("_adb-tls-pairing") && $0.name == name })
            else { return }
            self?.status("Pairing with your phone…")
            let out = (try? adb.run(["pair", service.address, password], timeout: 20)) ?? ""
            guard out.contains("Successfully paired") else {
                self?.status("Pairing failed – scan the code again")
                return
            }
            self?.status("Paired. Connecting…")
            // The phone now advertises its connect service; find it and connect.
            let ip = service.address.split(separator: ":").first.map(String.init) ?? ""
            for _ in 0..<15 {
                if let connect = adb.mdnsServices().first(where: { $0.type.hasPrefix("_adb-tls-connect") && $0.address.hasPrefix(ip + ":") }) {
                    let result = (try? adb.run(["connect", connect.address], timeout: 8)) ?? ""
                    if result.contains("connected to") {
                        DispatchQueue.main.async {
                            guard let self, !self.finished else { return }
                            self.finished = true
                            self.stop()
                            self.onPaired?(connect.address)
                        }
                        return
                    }
                }
                Thread.sleep(forTimeInterval: 1)
            }
            self?.status("Paired, but couldn't connect – check Wi-Fi")
        }
    }

    private func status(_ text: String) {
        DispatchQueue.main.async { self.onStatus?(text) }
    }
}
