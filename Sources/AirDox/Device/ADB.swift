import Foundation

struct ADBDevice: Hashable, Identifiable {
    let serial: String
    let state: String // "device", "unauthorized", "offline", ...
    let model: String

    var id: String { serial }
    var isReady: Bool { state == "device" }
    var isUnauthorized: Bool { state == "unauthorized" }
    var isWireless: Bool { serial.contains(":") || serial.contains("._adb-tls-connect") }

    var displayName: String {
        let name = model.isEmpty ? serial : model.replacingOccurrences(of: "_", with: " ")
        return name
    }
}

struct ADBError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Thin wrapper over the `adb` command line tool.
final class ADB {
    static let shared = ADB()

    let path: String?

    private init() {
        path = ADB.locate()
    }

    private static func locate() -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        var candidates: [String] = []
        if let p = env["ADB"] { candidates.append(p) }
        candidates += [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = env[key] { candidates.append("\(sdk)/platform-tools/adb") }
        }
        candidates.append("\(home)/Library/Android/sdk/platform-tools/adb")
        // Copy bundled inside the app as a last resort, so a system adb server is preferred
        // (two different adb versions would keep killing each other's server).
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("platform-tools/adb").path {
            candidates.append(bundled)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs adb synchronously and returns raw stdout (stderr is merged when `mergeStderr`).
    func runData(_ args: [String], serial: String? = nil, timeout: TimeInterval = 30,
                 mergeStderr: Bool = true) throws -> Data {
        guard let path else { throw ADBError(message: "adb was not found.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = (serial.map { ["-s", $0] } ?? []) + args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = mergeStderr ? out : err
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let timer = DispatchWorkItem { [weak process] in
            if let p = process, p.isRunning { p.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

        var errData = Data()
        if !mergeStderr {
            DispatchQueue.global().async {
                errData = err.fileHandleForReading.readDataToEndOfFile()
            }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()

        if process.terminationStatus != 0 {
            let text = String(decoding: mergeStderr ? data : errData, as: UTF8.self).trimmed
            throw ADBError(message: text.isEmpty ? "adb \(args.first ?? "") failed" : text)
        }
        return data
    }

    @discardableResult
    func run(_ args: [String], serial: String? = nil, timeout: TimeInterval = 30) throws -> String {
        String(decoding: try runData(args, serial: serial, timeout: timeout), as: UTF8.self)
    }

    func devices() throws -> [ADBDevice] {
        let output = try run(["devices", "-l"], timeout: 10)
        var result: [ADBDevice] = []
        for line in output.split(separator: "\n") {
            let s = String(line).trimmed
            if s.isEmpty || s.hasPrefix("List of devices") || s.hasPrefix("*") { continue }
            let parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            let model = parts.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)) } ?? ""
            result.append(ADBDevice(serial: parts[0], state: parts[1], model: model))
        }
        return result
    }

    /// Returns the phone's Wi-Fi IPv4 address, if any.
    func wifiAddress(serial: String) -> String? {
        guard let output = try? run(["shell", "ip", "route"], serial: serial, timeout: 10) else { return nil }
        for line in output.split(separator: "\n") where line.contains("wlan") {
            let parts = line.split(separator: " ")
            if let i = parts.firstIndex(of: "src"), i + 1 < parts.count { return String(parts[i + 1]) }
        }
        return nil
    }
}
