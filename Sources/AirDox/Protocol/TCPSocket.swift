import Foundation
import Darwin

struct SocketError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Minimal blocking TCP client socket (localhost only, used through `adb forward`).
final class TCPSocket {
    private var fd: Int32
    private let writeLock = NSLock()
    private let closeLock = NSLock()

    init(port: UInt16) throws {
        fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(message: "socket() failed: \(errno)") }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            let err = errno
            Darwin.close(fd)
            fd = -1
            throw SocketError(message: "connect() failed: \(err)")
        }
    }

    deinit { close() }

    func setNoDelay() {
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    func readFully(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var buffer = Data(count: count)
        var received = 0
        try buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while received < count {
                let n = Darwin.recv(fd, base + received, count - received, 0)
                if n > 0 {
                    received += n
                } else if n == 0 {
                    throw SocketError(message: "Connection closed")
                } else if errno != EINTR {
                    throw SocketError(message: "recv() failed: \(errno)")
                }
            }
        }
        return buffer
    }

    func readU32() throws -> UInt32 { try readFully(4).beU32(at: 0) }

    func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        var sent = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while sent < data.count {
                let n = Darwin.send(fd, base + sent, data.count - sent, 0)
                if n > 0 {
                    sent += n
                } else if n == 0 || errno != EINTR {
                    throw SocketError(message: "send() failed: \(errno)")
                }
            }
        }
    }

    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard fd >= 0 else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        fd = -1
    }
}
