import Foundation
import CoreMedia

/// Converts the Annex-B H.264 packets produced by Android's MediaCodec into
/// AVCC CMSampleBuffers that AVSampleBufferDisplayLayer can decode in hardware.
final class H264Packetizer {
    private(set) var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var waitingForKeyFrame = true

    /// Returns true when the format (resolution / parameter sets) changed.
    @discardableResult
    func handleConfig(_ packet: Data) -> Bool {
        var changed = false
        for nal in Self.nalUnits(packet) {
            changed = absorbParameterSet(nal) || changed
        }
        if changed { rebuildFormat() }
        return changed
    }

    func sampleBuffer(for packet: Data, pts: Int64, keyFrame: Bool) -> CMSampleBuffer? {
        var avcc = Data()
        var paramsChanged = false
        var containsIDR = false
        for nal in Self.nalUnits(packet) {
            guard let header = nal.first else { continue }
            let type = header & 0x1F
            switch type {
            case 7, 8:
                paramsChanged = absorbParameterSet(nal) || paramsChanged
            case 9: // access unit delimiter
                continue
            default:
                if type == 5 { containsIDR = true }
                var len = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
                avcc.append(nal)
            }
        }
        if paramsChanged { rebuildFormat() }

        let isKey = keyFrame || containsIDR
        if waitingForKeyFrame {
            guard isKey else { return nil }
            waitingForKeyFrame = false
        }
        guard let format = formatDescription, !avcc.isEmpty else { return nil }
        return Self.makeSampleBuffer(avcc, format: format, pts: pts, keyFrame: isKey)
    }

    func reset() {
        waitingForKeyFrame = true
    }

    // MARK: - Private

    private func absorbParameterSet(_ nal: Data) -> Bool {
        guard let header = nal.first else { return false }
        switch header & 0x1F {
        case 7:
            if nal != sps { sps = nal; return true }
        case 8:
            if nal != pps { pps = nal; return true }
        default:
            break
        }
        return false
    }

    private func rebuildFormat() {
        guard let sps, let pps else { return }
        var format: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsRaw.bindMemory(to: UInt8.self).baseAddress!,
                    ppsRaw.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format)
            }
        }
        if status == noErr, let format {
            formatDescription = format
            waitingForKeyFrame = true
        }
    }

    private static func makeSampleBuffer(_ avcc: Data, format: CMVideoFormatDescription,
                                         pts: Int64, keyFrame: Bool) -> CMSampleBuffer? {
        let length = avcc.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == noErr,
            let block else { return nil }

        let copyStatus = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: length)
        }
        guard copyStatus == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var sampleSize = length
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr,
            let sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !keyFrame {
                CFDictionarySetValue(dict,
                                     Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }

    /// Splits an Annex-B byte stream into NAL units (without start codes).
    static func nalUnits(_ data: Data) -> [Data] {
        var units: [Data] = []
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            let n = p.count
            var i = 0
            var start = -1
            while i + 2 < n {
                if p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1 {
                    if start >= 0 {
                        var end = i
                        while end > start && p[end - 1] == 0 { end -= 1 }
                        if end > start { units.append(Data(UnsafeBufferPointer(rebasing: p[start..<end]))) }
                    }
                    i += 3
                    start = i
                } else {
                    i += 1
                }
            }
            if start >= 0 {
                if start < n { units.append(Data(UnsafeBufferPointer(rebasing: p[start..<n]))) }
            } else if n > 0 {
                units.append(Data(UnsafeBufferPointer(rebasing: p[0..<n])))
            }
        }
        return units
    }
}
