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
}
