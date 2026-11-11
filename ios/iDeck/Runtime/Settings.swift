import Foundation

/// User settings, persisted as JSON in the state directory.
struct Settings: Codable, Equatable {
    enum PerformanceProfile: String, Codable, CaseIterable, Identifiable {
        case balanced, performance, batterySaver
        var id: String { rawValue }
        var title: String {
            switch self {
            case .balanced: return "Balanced"
            case .performance: return "Performance"
            case .batterySaver: return "Battery Saver"
            }
        }
        var cpus: Int {
            switch self {
            case .balanced: return 4
            case .performance: return 6
            case .batterySaver: return 2
            }
        }
    }

    enum Resolution: String, Codable, CaseIterable, Identifiable {
        case p540 = "960x540", p720 = "1280x720", p900 = "1600x900", p1080 = "1920x1080"
        var id: String { rawValue }
        var size: (width: Int, height: Int) {
            let parts = rawValue.split(separator: "x").compactMap { Int($0) }
            return (parts[0], parts[1])
        }
    }

    var profile: PerformanceProfile = .balanced
    var resolution: Resolution = .p720
    var guestMemoryMb: UInt64 = 0          // 0 = automatic
    var cpuModel = "neoverse-n1"
    var vulkan = true
    /// Diagnostic: boot without GPU acceleration (plain virtio-gpu, SPICE 2D,
    /// software rendering in Linux). Slow, but isolates GPU-path crashes.
    var safeGraphics = false
    var fileBackedRAM = false              // experimental: guest RAM in a file
    var steamBigPicture = false
    var steamBeta = false
    var steamSoftwareUI = false            // CEF without GPU (compatibility)
    var refreshHz = 60
    var audio = true
    var notifications = true
    var hapticsEnabled = true
    var showPerformanceOverlay = false
    var externalLibraryBookmark: Data?

    /// Saved values merged over defaults, so a settings file written by an
    /// older build (missing newer keys) keeps the user's choices.
    static func load() -> Settings {
        guard let data = try? Data(contentsOf: Paths.settingsFile),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(Settings()),
              var merged = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any] else {
            return Settings()
        }
        merged.merge(saved) { _, new in new }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let s = try? JSONDecoder().decode(Settings.self, from: mergedData) else { return Settings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Paths.settingsFile, options: .atomic)
        }
    }
}
