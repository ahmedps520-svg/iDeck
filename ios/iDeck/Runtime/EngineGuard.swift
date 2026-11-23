import Foundation

/// Native floating point (QEMU "x-host-vfp", iDeck's engine patch) is on by
/// default, checked in CI on an ARM64 host but not on every iPad. If Linux
/// was started with it twice in a row and never reached the guest agent, the
/// next start runs without it and the setting is switched off.
enum EngineGuard {
    /// Consecutive unfinished starts after which the setting is switched off.
    /// One is not enough: closing iDeck while Linux boots also leaves one.
    static let maxUnfinishedStarts = 2

    struct Decision: Equatable {
        var useNativeFP: Bool
        /// The earlier starts with native floating point never came up.
        var switchSettingOff: Bool
    }

    /// `unfinishedStarts`: starts with native floating point since the last
    /// one that reached the guest agent.
    static func decide(settingOn: Bool, supported: Bool, unfinishedStarts: Int) -> Decision {
        guard settingOn, supported else { return Decision(useNativeFP: false, switchSettingOff: false) }
        if unfinishedStarts >= maxUnfinishedStarts {
            return Decision(useNativeFP: false, switchSettingOff: true)
        }
        return Decision(useNativeFP: true, switchSettingOff: false)
    }

    static func unfinishedStarts(_ marker: URL) -> Int {
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return 0 }
        return max(0, Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }

    /// Linux is about to start with native floating point.
    static func noteStart(_ marker: URL) {
        try? String(unfinishedStarts(marker) + 1).write(to: marker, atomically: true, encoding: .utf8)
    }

    /// The guest agent reported ready, or the setting was switched off.
    static func clear(_ marker: URL) {
        try? FileManager.default.removeItem(at: marker)
    }

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
}
