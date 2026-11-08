import Foundation

/// Big-endian byte writer used to serialize scrcpy control messages.
struct ByteWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }

    mutating func u16(_ v: UInt16) {
        data.append(UInt8(truncatingIfNeeded: v >> 8))
        data.append(UInt8(truncatingIfNeeded: v))
    }

    mutating func u32(_ v: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: v >> UInt32(shift)))
        }
    }

    mutating func u64(_ v: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: v >> UInt64(shift)))
        }
    }

    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func bytes(_ d: Data) { data.append(d) }
}

extension Data {
    func beU16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }

    func beU32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        var v: UInt32 = 0
        for k in 0..<4 { v = v << 8 | UInt32(self[i + k]) }
        return v
    }

    func beU64(at offset: Int) -> UInt64 {
        let i = startIndex + offset
        var v: UInt64 = 0
        for k in 0..<8 { v = v << 8 | UInt64(self[i + k]) }
        return v
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
