import Foundation

/// Swift face of the shared C++ core (core/src). Calls are JSON in / JSON out
/// so the same logic is unit-tested on desktop CI and used unchanged here.
enum Core {
    struct CallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var version: String { String(cString: ideck_core_version()) }

    /// Calls `method` with an Encodable argument and decodes the result.
    static func call<A: Encodable, R: Decodable>(_ method: String, _ args: A, as: R.Type = R.self) throws -> R {
        let data = try JSONEncoder.snake.encode(args)
        let result = try callRaw(method, String(decoding: data, as: UTF8.self))
        return try JSONDecoder.snake.decode(R.self, from: result)
    }

    /// Calls `method` with a dictionary argument; returns the raw result JSON.
    @discardableResult
    static func callRaw(_ method: String, _ argsJSON: String) throws -> Data {
        guard let out = ideck_call(method, argsJSON) else { throw CallError(message: "core returned nothing") }
        defer { ideck_free(out) }
        let reply = Data(bytes: out, count: strlen(out))
        guard let obj = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw CallError(message: "core returned invalid JSON")
        }
        if obj["ok"] as? Bool != true {
            throw CallError(message: obj["error"] as? String ?? "unknown core error")
        }
        let result = obj["result"] ?? NSNull()
        return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
    }

    static func callDict(_ method: String, _ args: [String: Any]) throws -> Any {
        let data = try JSONSerialization.data(withJSONObject: args)
        let result = try callRaw(method, String(decoding: data, as: UTF8.self))
        return try JSONSerialization.jsonObject(with: result, options: [.fragmentsAllowed])
    }
}

extension JSONEncoder {
    static let snake: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
}

extension JSONDecoder {
    static let snake: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

// MARK: - Typed views of core results

struct MemoryPlan: Codable, Equatable {
    var guestMb: UInt64
    var tbCacheMb: UInt64
    var gpuBudgetMb: UInt64
    var hostmemMb: UInt64
    var overheadMb: UInt64
    var limitMb: UInt64
    var fits: Bool
    var allowedTiers: [UInt64]
    var notes: [String]
}

struct MemoryInputs: Codable {
    var physicalMb: UInt64
    var appLimitMb: UInt64
    var currentFootprintMb: UInt64
    var increasedMemoryLimit: Bool
    var userGuestMb: UInt64
    var cpus: Int
    var vulkan: Bool
}

struct PressureActions: Codable {
    var dropGuestCaches: Bool
    var balloonTargetMb: UInt64
    var releaseUiCaches: Bool
    var flushDisks: Bool
    var notifyUser: Bool
    var throttleDownloads: Bool
}

struct StorageDecision: Codable {
    var grow: Bool
    var newSize: UInt64
    var hostLow: Bool
    var guestFull: Bool
    var reason: String
}

struct VMConfig: Codable {
    var profile = "ios"
    var kernel: String
    var initrd: String
    var systemDisk: String
    var dataDisk: String
    var extraDisks: [String] = []
    var cmdline: String = ""
    var guestMb: UInt64
    var cpus: Int
    var tbCacheMb: UInt64
    var cpuModel: String
    var multithreadTcg = true
    var splitWx = true
    var ramFile: String = ""
    var gl = true
    var vulkan = true
    var hostmemMb: UInt64
    var width: Int
    var height: Int
    var refreshHz: Int
    var spiceSocket: String
    var qmpSocket: String
    var controlSocket: String
    var inputSocket: String
    var consoleLog: String
    var audio = "hda"
    var balloon = true
    var usbInput = true
}

struct QemuArgs: Codable {
    var argv: [String]
    var warnings: [String]
}
