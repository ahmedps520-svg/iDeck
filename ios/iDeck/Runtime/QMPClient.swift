import Foundation

/// QEMU Machine Protocol client (balloon, block_resize, system_powerdown,
/// query-status). Mirrors core/src/qmp.cpp, which is unit-tested on CI.
final class QMPClient {
    struct QMPError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let socket = UnixSocket(label: "qmp")
    private var buffer = Data()
    private var nextID = 1
    private var ready = false
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private let lock = NSLock()
    var onEvent: ((String, [String: Any]) -> Void)?
    var onClose: (() -> Void)?

    /// Connects and waits for QEMU's greeting. QEMU only greets once its main
    /// loop runs, so a QEMU stuck during initialisation surfaces here as a
    /// timeout instead of an endless wait.
    func connect(path: String, readyTimeout: TimeInterval = 90) async throws {
        socket.onData = { [weak self] in self?.receive($0) }
        socket.onClose = { [weak self] in self?.closed() }
        try await socket.connect(path: path, timeout: 30)
        DispatchQueue.global().asyncAfter(deadline: .now() + readyTimeout) { [weak self] in
            self?.failReadyWaiters("QEMU did not finish starting within \(Int(readyTimeout)) seconds (no QMP greeting).")
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            if ready {
                lock.unlock()
                c.resume()
            } else {
                readyWaiters.append(c)
                lock.unlock()
            }
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ obj: [String: Any]) {
        if obj["QMP"] != nil {
            // Greeting: negotiate capabilities with reserved id 0.
            let cmd: [String: Any] = ["execute": "qmp_capabilities", "id": 0]
            if let d = try? JSONSerialization.data(withJSONObject: cmd) {
                try? socket.write(d + Data("\r\n".utf8))
            }
            return
        }
        if let event = obj["event"] as? String {
            onEvent?(event, obj["data"] as? [String: Any] ?? [:])
            return
        }
        guard let id = obj["id"] as? Int else { return }
        lock.lock()
        if id == 0 && !ready {
            ready = true
            let waiters = readyWaiters
            readyWaiters.removeAll()
            lock.unlock()
            waiters.forEach { $0.resume() }
            return
        }
        let c = pending.removeValue(forKey: id)
        lock.unlock()
        if let err = obj["error"] as? [String: Any] {
            c?.resume(throwing: QMPError(message: err["desc"] as? String ?? "QMP error"))
        } else {
            c?.resume(returning: obj["return"] ?? NSNull())
        }
    }

    /// Aborts a pending connect (e.g. QEMU exited during startup).
    func abort(_ message: String) {
        failReadyWaiters(message)
        socket.close()
    }

    private func failReadyWaiters(_ message: String) {
        lock.lock()
        let waiters = readyWaiters
        readyWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(throwing: QMPError(message: message)) }
    }

    private func closed() {
        lock.lock()
        let all = pending.values
        pending.removeAll()
        let waiters = readyWaiters
        readyWaiters.removeAll()
        ready = false
        lock.unlock()
        all.forEach { $0.resume(throwing: QMPError(message: "QMP connection closed")) }
        waiters.forEach { $0.resume(throwing: QMPError(message: "QMP connection closed")) }
        onClose?()
    }

    @discardableResult
    func execute(_ command: String, _ arguments: [String: Any]? = nil) async throws -> Any {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Any, Error>) in
            lock.lock()
            let id = nextID
            nextID += 1
            pending[id] = c
            lock.unlock()
            var cmd: [String: Any] = ["execute": command, "id": id]
            if let a = arguments { cmd["arguments"] = a }
            do {
                let d = try JSONSerialization.data(withJSONObject: cmd)
                try socket.write(d + Data("\r\n".utf8))
            } catch {
                lock.lock()
                let c2 = pending.removeValue(forKey: id)
                lock.unlock()
                c2?.resume(throwing: error)
            }
        }
    }

    // MARK: Convenience

    func setBalloon(megabytes: UInt64) async throws {
        try await execute("balloon", ["value": megabytes * 1024 * 1024])
    }

    func resizeBlock(node device: String, bytes: UInt64) async throws {
        try await execute("block_resize", ["device": device, "size": bytes])
    }

    func powerdown() async throws { try await execute("system_powerdown") }
    func quit() async throws { try await execute("quit") }

    func status() async throws -> String {
        let r = try await execute("query-status") as? [String: Any]
        return r?["status"] as? String ?? "unknown"
    }

    func close() { socket.close() }
}
