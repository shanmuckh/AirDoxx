import Foundation
import AVFoundation

/// Plays the phone's audio, streamed by scrcpy as raw PCM (48 kHz, stereo, s16le).
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private let lock = NSLock()
    private var queuedFrames = 0
    private var playing = false
    private var engineStarted = false

    /// Start playback once this much audio is buffered (absorbs network jitter).
    private let startThreshold = 48_000 * 60 / 1000   // 60 ms
    /// Drop incoming audio when this much is already queued, so latency can't grow unbounded.
    private let maxQueued = 48_000 * 250 / 1000       // 250 ms

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    private var packets = 0
    private func debugLog(_ text: String) {
        #if DEBUG
        FileHandle.standardError.write(Data("[audio] \(text)\n".utf8))
        #endif
    }

    func enqueue(_ pcm: Data) {
        packets += 1
        if packets == 1 || packets % 200 == 0 {
            lock.lock(); let q = queuedFrames; lock.unlock()
            var peak: Int16 = 0
            pcm.withUnsafeBytes { raw in
                for i in stride(from: 0, to: raw.count - 1, by: 2) {
                    let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: Int16.self))
                    peak = max(peak, v == .min ? .max : abs(v))
                }
            }
            debugLog("peak=\(peak)")
            debugLog("packet #\(packets) bytes=\(pcm.count) queued=\(q) playing=\(playing) engine=\(engine.isRunning) node=\(node.isPlaying) out=\(engine.outputNode.outputFormat(forBus: 0))")
        }
        let frames = pcm.count / 4
        guard frames > 0 else { return }

        lock.lock()
        let tooMuch = queuedFrames > maxQueued
        lock.unlock()
        if tooMuch { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let left = channels[0]
        let right = channels[1]
        pcm.withUnsafeBytes { raw in
            for i in 0..<frames {
                let l = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: Int16.self))
                let r = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4 + 2, as: Int16.self))
                left[i] = Float(l) / 32768
                right[i] = Float(r) / 32768
            }
        }

        if !engineStarted {
            do {
                try engine.start()
                engineStarted = true
            } catch {
                NSLog("Audio engine failed to start: \(error)")
                return
            }
        }

        lock.lock()
        queuedFrames += frames
        let shouldStart = !playing && queuedFrames >= startThreshold
        lock.unlock()

        node.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.queuedFrames = max(0, self.queuedFrames - frames)
            self.lock.unlock()
        }

        if shouldStart {
            lock.lock()
            playing = true
            lock.unlock()
            node.play()
        }
    }

    func stop() {
        node.stop()
        if engineStarted { engine.stop() }
        engineStarted = false
    }
}
