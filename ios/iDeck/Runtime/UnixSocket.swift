import Darwin
import Foundation

/// Minimal non-blocking AF_UNIX stream client used for QMP and the guest
/// agent channels exposed by QEMU (chardev socket, server=on).
final class UnixSocket {
    enum SocketError: LocalizedError {
        case pathTooLong, connectFailed(Int32), closed
        var errorDescription: String? {
            switch self {
            case .pathTooLong: return "socket path too long"
            case .connectFailed(let e): return "connect failed: \(String(cString: strerror(e)))"
            case .closed: return "socket closed"
            }
        }
    }

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue: DispatchQueue
    private let writeLock = NSLock()
    var onData: ((Data) -> Void)?
    var onClose: (() -> Void)?

    init(label: String) {
        queue = DispatchQueue(label: "ideck.socket.\(label)", qos: .userInteractive)
    }

    deinit { close() }

    var isOpen: Bool { fd >= 0 }

    func connect(path: String) throws {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw SocketError.connectFailed(errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(s)
            throw SocketError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, len) }
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(s)
            throw SocketError.connectFailed(e)
        }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        fd = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { Darwin.close(s) }
        source = src
        src.resume()
    }

    /// Retries until QEMU has created the socket or the deadline passes.
    func connect(path: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                try connect(path: path)
                return
            } catch {
                if Date() > deadline { throw error }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 65536)
        while fd >= 0 {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                onData?(Data(buf[0..<n]))
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                close()
                onClose?()
                return
            } else {
                return
            }
        }
    }

    func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard fd >= 0 else { throw SocketError.closed }
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { raw -> Int in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if n > 0 {
                offset += n
            } else if errno == EAGAIN || errno == EINTR {
                usleep(500)
            } else {
                throw SocketError.closed
            }
        }
    }

    func close() {
        guard fd >= 0 else { return }
        fd = -1
        source?.cancel()
        source = nil
    }
}
