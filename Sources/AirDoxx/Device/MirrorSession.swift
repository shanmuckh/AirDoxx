import Foundation
import CoreMedia

struct MirrorOptions {
    var maxSize: Int = 0
    var videoBitRate: Int = 16_000_000
    var maxFps: Int = 60
    var audio: Bool = true
    var turnScreenOff: Bool = true
}

protocol MirrorSessionDelegate: AnyObject {
    func sessionDidStart(_ session: MirrorSession, deviceName: String)
    func session(_ session: MirrorSession, videoSizeDidChange size: CGSize)
    func session(_ session: MirrorSession, didEndWithError error: String?)
    func session(_ session: MirrorSession, didReceiveClipboard text: String)
}

/// One mirroring connection: pushes and launches the scrcpy server on the phone, opens the
/// video / audio / control sockets through `adb forward`, and pumps the streams.
final class MirrorSession {
    let device: ADBDevice
    let options: MirrorOptions
    weak var delegate: MirrorSessionDelegate?

    /// Called on the video thread for every decoded-ready frame.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    /// Called on the video thread when the stream format changes (rotation, resolution change).
    var onFormatChange: (() -> Void)?

    private let adb = ADB.shared
    private let lock = NSLock()
    private var stopped = false
    private var _videoSize: CGSize = .zero
    private var serverProcess: Process?
    private var serverLog = ""
    private var forwardPort: Int?
    private var videoSocket: TCPSocket?
    private var audioSocket: TCPSocket?
    private var controlSocket: TCPSocket?
    private var audioPlayer: AudioPlayer?
    private let controlQueue = DispatchQueue(label: "mirror.control")
    private let packetizer = H264Packetizer()
    private var clipboardSequence: UInt64 = 1
    private var screenIsOff = false
    private var frameCount = 0
    private var pendingVideoSize: CGSize?

    private func debugLog(_ text: String) {
        #if DEBUG
        FileHandle.standardError.write(Data("[mirror] \(text)\n".utf8))
        #endif
    }

    var videoSize: CGSize {
        lock.lock(); defer { lock.unlock() }
        return _videoSize
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    init(device: ADBDevice, options: MirrorOptions) {
        self.device = device
        self.options = options
    }

    func start() {
        let thread = Thread { [self] in self.run() }
        thread.name = "mirror.video"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // MARK: - Sending

    func send(_ message: Data) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            guard let socket = self.controlSocket else {
                self.debugLog("control: no socket, dropped type \(message.first ?? 255)")
                return
            }
            do {
                try socket.write(message)
                let detail = message.count > 1 ? " action=\(message[message.startIndex + 1])" : ""
                self.debugLog("control: sent type \(message.first ?? 255)\(detail)")
            } catch {
                self.debugLog("control: write failed: \(error)")
            }
        }
    }

    func sendText(_ text: String) {
        for msg in ControlMessage.text(text) { send(msg) }
        noteUserInput()
    }

    func pressKey(_ keycode: UInt32, meta: UInt32 = 0) {
        send(ControlMessage.keycode(.down, keycode, meta: meta))
        send(ControlMessage.keycode(.up, keycode, meta: meta))
        noteUserInput()
    }

    // MARK: - Keeping the phone screen off
    //
    // Some ROMs (e.g. Xiaomi HyperOS) switch the panel back on when input arrives, even though
    // the server turned it off. While "screen off" is wanted, re-assert it shortly after input
    // and every few seconds.

    private var screenOffWanted = false
    private var screenOffTimer: DispatchSourceTimer?
    private var pendingReassert: DispatchWorkItem?

    func noteUserInput() {
        guard screenOffWanted else { return }
        pendingReassert?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.screenOffWanted, !self.isStopped else { return }
            self.send(ControlMessage.setDisplayPower(false))
        }
        pendingReassert = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func startScreenOffKeeper() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self, self.screenOffWanted, !self.isStopped else { return }
            self.send(ControlMessage.setDisplayPower(false))
        }
        timer.resume()
        screenOffTimer = timer
    }

    func setClipboard(_ text: String, paste: Bool) {
        let seq = clipboardSequence
        clipboardSequence += 1
        send(ControlMessage.setClipboard(sequence: seq, paste: paste, text: text))
    }

    func setScreenPower(on: Bool) {
        screenIsOff = !on
        screenOffWanted = !on
        send(ControlMessage.setDisplayPower(on))
        if !on && screenOffTimer == nil { startScreenOffKeeper() }
    }

    var isScreenOff: Bool { screenIsOff }

    // MARK: - Lifecycle

    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        guard !alreadyStopped else { return }
        teardown()
    }

    private func finish(_ error: String?) {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        guard !alreadyStopped else { return }
        teardown()
        DispatchQueue.main.async {
            self.delegate?.session(self, didEndWithError: error)
        }
    }

    private func teardown() {
        screenOffWanted = false
        screenOffTimer?.cancel()
        screenOffTimer = nil
        if screenIsOff, let control = controlSocket {
            // Give the phone its screen back before we leave.
            controlQueue.sync { try? control.write(ControlMessage.setDisplayPower(true)) }
        }
        videoSocket?.close()
        audioSocket?.close()
        controlSocket?.close()
        audioPlayer?.stop()
        if let p = serverProcess, p.isRunning { p.terminate() }
        if let port = forwardPort {
            let serial = device.serial
            DispatchQueue.global().async {
                _ = try? ADB.shared.run(["forward", "--remove", "tcp:\(port)"], serial: serial, timeout: 5)
            }
        }
    }

    // MARK: - Connection

    private func run() {
        do {
            guard let server = ScrcpyServer.locate() else {
                throw ADBError(message: "The scrcpy server component is missing.")
            }
            let serial = device.serial

            try adb.run(["push", server.url.path, ScrcpyServer.remotePath], serial: serial, timeout: 60)
            if isStopped { return }

            // Drop tunnels left behind by a previous run that didn't exit cleanly.
            if let list = try? adb.run(["forward", "--list"], timeout: 5) {
                for line in list.split(separator: "\n") {
                    let parts = line.split(separator: " ")
                    guard parts.count == 3, parts[0] == serial, parts[2].hasPrefix("localabstract:scrcpy_") else { continue }
                    _ = try? adb.run(["forward", "--remove", String(parts[1])], serial: serial, timeout: 5)
                }
            }

            let scid = UInt32.random(in: 0..<0x7FFF_FFFF)
            let scidHex = String(format: "%08x", scid)
            let portText = try adb.run(["forward", "tcp:0", "localabstract:scrcpy_\(scidHex)"], serial: serial, timeout: 10)
            guard let port = Int(portText.trimmed), port > 0, port < 65536 else {
                throw ADBError(message: "Could not set up the adb tunnel (\(portText.trimmed)).")
            }
            lock.lock(); forwardPort = port; lock.unlock()

            try launchServer(server: server, scidHex: scidHex)

            let video = try connectFirstSocket(port: UInt16(port))
            videoSocket = video
            if options.audio {
                audioSocket = try TCPSocket(port: UInt16(port))
            }
            let control = try TCPSocket(port: UInt16(port))
            control.setNoDelay()
            controlSocket = control

            let nameData = try video.readFully(64)
            let deviceName = String(decoding: nameData.prefix(63).prefix { $0 != 0 }, as: UTF8.self)
            debugLog("connected to \(deviceName)")

            if options.turnScreenOff { setScreenPower(on: false) }

            DispatchQueue.main.async { self.delegate?.sessionDidStart(self, deviceName: deviceName) }

            if let audio = audioSocket { startAudioThread(audio) }
            startControlReader(control)
            try videoLoop(video)
        } catch {
            if isStopped { return }
            finish(describe(error))
        }
    }

    private func describe(_ error: Error) -> String {
        var message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let log = serverLogTail()
        if !log.isEmpty { message += "\n\n" + log }
        return message
    }

    private func serverLogTail() -> String {
        lock.lock(); defer { lock.unlock() }
        let lines = serverLog.split(separator: "\n").suffix(6)
        return lines.joined(separator: "\n")
    }

    private func launchServer(server: ScrcpyServer, scidHex: String) throws {
        guard let adbPath = adb.path else { throw ADBError(message: "adb was not found.") }
        var params = [
            "scid=\(scidHex)",
            "log_level=\(ProcessInfo.processInfo.environment["AM_LOG_LEVEL"] ?? "info")",
            "tunnel_forward=true",
            "video_bit_rate=\(options.videoBitRate)",
            "max_fps=\(options.maxFps)",
            "stay_awake=true",
            "clipboard_autosync=true",
        ]
        if options.maxSize > 0 { params.append("max_size=\(options.maxSize)") }
        if options.audio {
            params.append("audio_codec=raw")
        } else {
            params.append("audio=false")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", device.serial, "shell",
                             "CLASSPATH=\(ScrcpyServer.remotePath)", "app_process", "/",
                             "com.genymobile.scrcpy.Server", server.version] + params
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            self.lock.lock()
            self.serverLog += text
            if self.serverLog.count > 20_000 { self.serverLog = String(self.serverLog.suffix(10_000)) }
            self.lock.unlock()
            #if DEBUG
            FileHandle.standardError.write(data)
            #endif
        }
        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            guard let self, !self.isStopped else { return }
            // Let pending log output arrive before reporting.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                let log = self.serverLogTail()
                self.finish(log.isEmpty ? "The connection to the phone was lost." : "The phone ended the session.\n\n\(log)")
            }
        }
        try process.run()
        serverProcess = process
    }

    /// The server starts listening a moment after launch. `adb forward` accepts the TCP
    /// connection immediately, so a connection only counts once the dummy byte arrives.
    private func connectFirstSocket(port: UInt16) throws -> TCPSocket {
        var lastError: Error = ADBError(message: "Timed out connecting to the phone.")
        for _ in 0..<100 {
            if isStopped { throw ADBError(message: "Cancelled") }
            if let p = serverProcess, !p.isRunning { break }
            do {
                let socket = try TCPSocket(port: port)
                do {
                    _ = try socket.readFully(1)
                    return socket
                } catch {
                    socket.close()
                    lastError = error
                }
            } catch {
                lastError = error
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw lastError
    }

    // MARK: - Streams

    private func videoLoop(_ socket: TCPSocket) throws {
        let codec = try socket.readU32()
        switch codec {
        case 0: throw ADBError(message: "The phone did not provide a video stream.")
        case 1: throw ADBError(message: "The phone could not start screen capture.")
        case 0x6832_3634: break // "h264"
        default: throw ADBError(message: String(format: "Unexpected video codec 0x%08x.", codec))
        }

        while !isStopped {
            let header = try socket.readFully(12)
            if header[header.startIndex] & 0x80 != 0 {
                // Session packet: new capture session (start or rotation).
                let width = header.beU32(at: 4)
                let height = header.beU32(at: 8)
                let size = CGSize(width: CGFloat(width), height: CGFloat(height))
                lock.lock(); _videoSize = size; lock.unlock()
                debugLog("session packet \(width)x\(height)")
                packetizer.reset()
                // Report the new size together with the first frame of the new session, so the
                // window can switch shape (and animate a rotation) exactly when that frame shows.
                pendingVideoSize = size
                continue
            }
            let ptsAndFlags = header.beU64(at: 0)
            let length = Int(header.beU32(at: 8))
            guard length > 0 else { throw ADBError(message: "Invalid video packet.") }
            let payload = try socket.readFully(length)

            let isConfig = ptsAndFlags & (1 << 62) != 0
            let isKey = ptsAndFlags & (1 << 61) != 0
            let pts = Int64(ptsAndFlags & ((1 << 61) - 1))

            if isConfig {
                if packetizer.handleConfig(payload) { onFormatChange?() }
                continue
            }
            if let sample = packetizer.sampleBuffer(for: payload, pts: pts, keyFrame: isKey) {
                if let size = pendingVideoSize {
                    pendingVideoSize = nil
                    let done = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async {
                        self.delegate?.session(self, videoSizeDidChange: size)
                        done.signal()
                    }
                    _ = done.wait(timeout: .now() + 0.5)
                }
                onSampleBuffer?(sample)
                frameCount += 1
                if frameCount == 1 || frameCount % 120 == 0 { debugLog("frames rendered: \(frameCount)") }
            }
        }
    }

    private func startAudioThread(_ socket: TCPSocket) {
        let thread = Thread { [weak self] in
            do {
                let codec = try socket.readU32()
                guard codec == 0x0072_6177 else { return } // "raw"; 0 = audio unsupported (Android < 11)
                self?.debugLog("audio stream started (raw PCM)")
                let player = AudioPlayer()
                self?.audioPlayer = player
                while let self, !self.isStopped {
                    let header = try socket.readFully(12)
                    let flags = header.beU64(at: 0)
                    let length = Int(header.beU32(at: 8))
                    guard length > 0 else { return }
                    let payload = try socket.readFully(length)
                    if flags & (1 << 62) != 0 { continue } // config packet
                    player.enqueue(payload)
                }
            } catch {
                // Audio is best-effort; video drives the session lifetime.
            }
        }
        thread.name = "mirror.audio"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Device -> client messages (clipboard sync, acks).
    private func startControlReader(_ socket: TCPSocket) {
        let thread = Thread { [weak self] in
            do {
                while true {
                    let type = try socket.readFully(1)[0]
                    switch type {
                    case 0: // clipboard
                        let length = Int(try socket.readU32())
                        let text = String(decoding: try socket.readFully(length), as: UTF8.self)
                        guard let self else { return }
                        DispatchQueue.main.async { self.delegate?.session(self, didReceiveClipboard: text) }
                    case 1: // ack clipboard
                        _ = try socket.readFully(8)
                    case 2: // uhid output
                        let head = try socket.readFully(4)
                        _ = try socket.readFully(Int(head.beU16(at: 2)))
                    default:
                        return
                    }
                }
            } catch {}
        }
        thread.name = "mirror.control.reader"
        thread.start()
    }
}
