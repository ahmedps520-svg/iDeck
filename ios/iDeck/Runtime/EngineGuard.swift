import Foundation

/// iDeck's engine options (QEMU "x-host-vfp" and "x-asid-keep-global", the
/// patches in engine/qemu) are checked in CI on an ARM64 host. On a device
/// they are tried, and switched off again when Linux does not come up with
/// them: after one such start until Linux has come up with them once on
/// this build and runtime, after two in a row from then on.
///
/// A start counts from the moment QEMU runs with the options: when it
/// answers, or when it is still silent after the wait in connectChannels.
/// A start the debugger stops while it prepares JIT memory does not count.
/// QEMU reads the options only after that step, so they cannot have played
/// a part (device, build 41: two starts stopped there, and the options
/// were switched off for it).
enum EngineGuard {
    /// Starts in a row that may fail before the options are switched off.
    /// Once they have worked, one more is allowed: closing iDeck while
    /// Linux boots also leaves an unfinished start.
    static func maxUnfinishedStarts(proven: Bool) -> Int { proven ? 2 : 1 }

    struct Decision: Equatable {
        /// The engine options that are switched on may be used.
        var useEngine: Bool
        /// The earlier starts with engine options never came up.
        var switchSettingsOff: Bool
    }

    /// `anySettingOn`: at least one engine option is switched on.
    /// `unfinishedStarts`: starts with engine options since the last one
    /// that reached the guest agent.
    /// `proven`: Linux has come up with these options on this build and runtime.
    static func decide(anySettingOn: Bool, supported: Bool, unfinishedStarts: Int, proven: Bool) -> Decision {
        guard anySettingOn, supported else { return Decision(useEngine: false, switchSettingsOff: false) }
        if unfinishedStarts >= maxUnfinishedStarts(proven: proven) {
            return Decision(useEngine: false, switchSettingsOff: true)
        }
        return Decision(useEngine: true, switchSettingsOff: false)
    }

    static func unfinishedStarts(_ marker: URL) -> Int {
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return 0 }
        return max(0, Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }

    /// QEMU is running with engine options.
    static func noteStart(_ marker: URL) {
        try? String(unfinishedStarts(marker) + 1).write(to: marker, atomically: true, encoding: .utf8)
    }

    /// The guest agent reported ready, or the setting was switched off.
    static func clear(_ marker: URL) {
        try? FileManager.default.removeItem(at: marker)
    }

    // MARK: Proven on this device

    /// What "proven" is recorded for: the app build, the runtime and which
    /// options were on.
    static func stamp(build: String, runtime: String, hostVfp: Bool, keepGlobal: Bool) -> String {
        "\(build)|\(runtime)|\(hostVfp ? 1 : 0)\(keepGlobal ? 1 : 0)"
    }

    static func isProven(_ file: URL, stamp: String) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == stamp
    }

    /// Linux reached the guest agent with these options.
    static func noteProven(_ file: URL, stamp: String) {
        try? stamp.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: Floating-point check

    /// One line for the log and Settings from the agent's `fpcheck.run`
    /// reply: Linux ran every floating-point instruction pattern and
    /// compared the results with those recorded on real hardware when the
    /// runtime was built. `ok` is false when any result differs.
    static func checkSummary(_ r: [String: Any], nativeFP: Bool) -> (text: String, ok: Bool) {
        let mode = nativeFP ? "native" : "emulated"
        guard (r["reference"] as? Bool) == true else {
            return ("\(mode): this runtime has no hardware reference to compare with", false)
        }
        let patterns = (r["patterns"] as? NSNumber)?.intValue ?? 0
        let cpu = (r["reference_cpu"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "hardware"
        if (r["match"] as? Bool) == true {
            let flags = (r["flags_match"] as? Bool) == true ? "" : "; exception flags differ"
            return ("\(mode): all \(patterns) instruction patterns match \(cpu)\(flags)", true)
        }
        let differ = (r["values_differ"] as? NSNumber)?.intValue ?? 0
        let names = (r["values_differ_names"] as? [String] ?? []).prefix(6).joined(separator: ", ")
        var parts: [String] = []
        if differ > 0 { parts.append("\(differ) of \(patterns) instruction patterns differ from \(cpu)"
                                     + (names.isEmpty ? "" : " (\(names))")) }
        if (r["mix_values_equal"] as? Bool) != true { parts.append("mixed sequences differ") }
        if let n = (r["sigill"] as? NSNumber)?.intValue, n > 0 { parts.append("\(n) patterns were illegal instructions") }
        if let n = (r["missing"] as? NSNumber)?.intValue, n > 0 { parts.append("\(n) patterns did not run") }
        return ("\(mode): " + (parts.isEmpty ? "the check did not match" : parts.joined(separator: "; ")), false)
    }

    /// The check compared with hardware results and found a difference: with
    /// native floating point on, that option gives wrong results here. (A
    /// runtime without reference results says nothing either way.)
    static func checkFoundDifference(_ r: [String: Any]) -> Bool {
        (r["reference"] as? Bool) == true && (r["match"] as? Bool) != true
    }
}

/// Counts a start with engine options once, from whichever of two places
/// sees first that QEMU runs with them: the main actor when QEMU answers,
/// or a background queue when it is still silent after 12 s.
final class EngineStartNote: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private let marker: URL

    init(marker: URL) {
        self.marker = marker
    }

    /// `on`: this start runs with engine options and has not been counted.
    func arm(_ on: Bool) {
        lock.lock()
        armed = on
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let count = armed
        armed = false
        lock.unlock()
        if count { EngineGuard.noteStart(marker) }
    }
}
