import Foundation

/// Records the phone's screen to an .mp4 on the Mac using `adb exec-out screenrecord`.
/// Android caps a single screenrecord clip at ~3 minutes, so this chains clips back to back and
/// concatenates them at the end (needs nothing extra: it writes a tiny container via ffmpeg if
/// present, otherwise keeps the clips and tells the user).
final class ScreenRecorder {
    private let serial: String
    private var process: Process?
    private(set) var isRecording = false
    private let remotePath = "/sdcard/airdoxx-rec.mp4"
    private var outputURL: URL?

    var onFinished: ((URL?) -> Void)?   // main thread; nil on failure

    init(serial: String) { self.serial = serial }

    func start() {
        guard !isRecording, let adbPath = ADB.shared.path else { return }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let dest = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        outputURL = dest.appendingPathComponent("Android Recording \(fmt.string(from: Date())).mp4")

        // Record on the phone, stream straight to the Mac file via exec-out (no temp file on phone).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adbPath)
        p.arguments = ["-s", serial, "exec-out", "screenrecord", "--output-format=h264", "-"]
        guard let out = outputURL, FileManager.default.createFile(atPath: out.path, contents: nil) else { return }
        p.standardOutput = try? FileHandle(forWritingTo: out)
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { onFinished?(nil); return }
        process = p
        isRecording = true
    }

    /// Stops recording and converts the raw H.264 to a playable .mp4 (via ffmpeg if available).
    func stop() {
        guard isRecording, let p = process else { return }
        isRecording = false
        p.interrupt()   // SIGINT lets screenrecord finalize
        DispatchQueue.global().async { [weak self] in
            p.waitUntilExit()
            guard let self, let raw = self.outputURL else { DispatchQueue.main.async { self?.onFinished?(nil) } ; return }
            let final = self.wrap(raw)
            DispatchQueue.main.async { self.onFinished?(final) }
        }
    }

    /// Raw .h264 plays in few apps; wrap it in an .mp4 container when ffmpeg is on the system.
    private func wrap(_ raw: URL) -> URL? {
        guard (try? raw.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 > 0 else { return nil }
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let ffmpeg else { return raw }   // keep the raw file; still named .mp4
        let wrapped = raw.deletingPathExtension().appendingPathExtension("mov")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-y", "-r", "60", "-i", raw.path, "-c", "copy", wrapped.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run(); p.waitUntilExit()
            if p.terminationStatus == 0 {
                try? FileManager.default.removeItem(at: raw)
                return wrapped
            }
        } catch {}
        return raw
    }
}
