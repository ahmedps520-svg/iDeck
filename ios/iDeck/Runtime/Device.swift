import Foundation

/// What kind of device iDeck runs on, for wording and per-device defaults.
///
/// Supported: 8 GB devices (iPhone 16 Pro / Pro Max, iPad Air M3) and 12 GB
/// ones (iPhone 17 Pro / Pro Max / Air, iPhone 18 Pro, M4/M5 iPad Pro). Sizing
/// is decided from measured RAM, memory limit and core counts, not from model
/// identifiers, so newer models need no table update.
enum Device {
    /// From the model identifier ("iPhone17,2"), which unlike UIDevice can be
    /// read off the main actor.
    static let isPhone = IDPlatform.modelIdentifier.hasPrefix("iPhone")
    /// "iPhone" or "iPad", for user-facing text.
    static var name: String { isPhone ? "iPhone" : "iPad" }
    /// "iOS" or "iPadOS", for user-facing text.
    static var os: String { isPhone ? "iOS" : "iPadOS" }

    static var ramGB: Int { Int((IDPlatform.physicalMemory + (512 << 20)) >> 30) }
    /// 8 GB class (reports about 7.5 GiB): smaller guest, lighter defaults.
    static var isEightGBClass: Bool { IDPlatform.physicalMemory < (10 << 30) }

    static var totalCores: Int {
        let p = IDPlatform.performanceCores, e = IDPlatform.efficiencyCores
        return p + e > 0 ? p + e : ProcessInfo.processInfo.activeProcessorCount
    }

    /// Guest vCPUs for a performance profile. Each vCPU is a host thread
    /// running translated code; QEMU's main loop, the GPU renderer and the
    /// app need cores too, so leave at least one (two in Balanced) free.
    /// A18 Pro / A19 Pro (2P+4E): 4 / 5 / 2. M3-M5 (8-10 cores): 4 / 6 / 2.
    static func cpus(for profile: Settings.PerformanceProfile) -> Int {
        let total = max(totalCores, 2)
        switch profile {
        case .balanced: return max(2, min(4, total - 2))
        case .performance: return max(2, min(6, total - 1))
        case .batterySaver: return 2
        }
    }

    /// One line for the log.
    static var summary: String {
        "\(name), \(ramGB) GB, \(IDPlatform.performanceCores)P+\(IDPlatform.efficiencyCores)E cores"
            + (isEightGBClass ? ", 8 GB class" : "")
    }
}
