import Foundation

/// Client for the ideck-agent control channel (guest/agent/agent.cpp).
/// Newline-delimited JSON: requests with ids, responses, unsolicited events.
final class AgentClient {
    struct AgentError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let socket = UnixSocket(label: "agent")
    private var buffer = Data()
    private var nextID: Int64 = 1
    private var pending: [Int64: CheckedContinuation<Any, Error>] = [:]
    private let lock = NSLock()
    var onEvent: ((String, [String: Any]) -> Void)?
    var onClose: (() -> Void)?

    func connect(path: String) async throws {
        socket.onData = { [weak self] in self?.receive($0) }
        socket.onClose = { [weak self] in self?.closed() }
        try await socket.connect(path: path, timeout: 30)
    }

    var isConnected: Bool { socket.isOpen }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty, let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            if let event = obj["event"] as? String {
                onEvent?(event, obj["data"] as? [String: Any] ?? [:])
                continue
            }
            guard let idNum = obj["id"] as? NSNumber else { continue }
            let id = idNum.int64Value
            lock.lock()
            let c = pending.removeValue(forKey: id)
            lock.unlock()
            if obj["ok"] as? Bool == true {
                c?.resume(returning: obj["result"] ?? NSNull())
            } else {
                c?.resume(throwing: AgentError(message: obj["error"] as? String ?? "agent error"))
            }
        }
        // A runaway line without newline would grow forever; cap it.
        if buffer.count > 4 << 20 { buffer.removeAll() }
    }

    private func closed() {
        lock.lock()
        let all = pending.values
        pending.removeAll()
        lock.unlock()
        all.forEach { $0.resume(throwing: AgentError(message: "Linux agent disconnected")) }
        onClose?()
    }

    @discardableResult
    func request(_ op: String, _ args: [String: Any] = [:], timeout: TimeInterval = 30) async throws -> Any {
        let id: Int64 = {
            lock.lock()
            defer { lock.unlock() }
            let i = nextID
            nextID += 1
            return i
        }()
        let line: Data
        do {
            let d = try JSONSerialization.data(withJSONObject: ["id": id, "op": op, "args": args])
            line = d + Data([0x0A])
        }
        return try await withThrowingTaskGroup(of: Any.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Any, Error>) in
                    self.lock.lock()
                    self.pending[id] = c
                    self.lock.unlock()
                    do {
                        try self.socket.write(line)
                    } catch {
                        self.lock.lock()
                        let c2 = self.pending.removeValue(forKey: id)
                        self.lock.unlock()
                        c2?.resume(throwing: error)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.lock.lock()
                let c = self.pending.removeValue(forKey: id)
                self.lock.unlock()
                c?.resume(throwing: AgentError(message: "\(op) timed out"))
                throw AgentError(message: "\(op) timed out")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    func requestDict(_ op: String, _ args: [String: Any] = [:], timeout: TimeInterval = 30) async throws -> [String: Any] {
        try await request(op, args, timeout: timeout) as? [String: Any] ?? [:]
    }

    func close() { socket.close() }
}

/// Binary controller channel (32-byte packets, see core/include/ideck/protocol.hpp).
final class InputChannel {
    private let socket = UnixSocket(label: "input")
    private let decoder = ideck_input_decoder_new()
    var onRumble: ((ideck_rumble) -> Void)?

    deinit { ideck_input_decoder_free(decoder) }

    func connect(path: String) async throws {
        socket.onData = { [weak self] data in self?.receive(data) }
        try await socket.connect(path: path, timeout: 30)
    }

    var isConnected: Bool { socket.isOpen }

    func send(_ state: ideck_pad_state) {
        var s = state
        var packet = [UInt8](repeating: 0, count: 32)
        packet.withUnsafeMutableBufferPointer { buf in
            withUnsafePointer(to: &s) { ideck_input_encode($0, buf.baseAddress!) }
        }
        try? socket.write(Data(packet))
    }

    private func receive(_ data: Data) {
        var events = [ideck_rumble](repeating: ideck_rumble(), count: 8)
        let n = data.withUnsafeBytes { raw -> Int in
            events.withUnsafeMutableBufferPointer { out in
                ideck_input_decoder_feed(decoder, raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
                                         out.baseAddress, out.count)
            }
        }
        for i in 0..<n { onRumble?(events[i]) }
    }

    func close() { socket.close() }
}
