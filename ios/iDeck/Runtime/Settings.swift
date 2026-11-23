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
        /// Depends on the device's cores (Device.cpus): an iPhone has 2
        /// performance cores where an M-series iPad has 3-4.
        var cpus: Int { Device.cpus(for: self) }
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
    /// QEMU's "max" (with PAuth, SVE and SME off, core/qemu_args) since
    /// build 33: FEAT_MOPS lets glibc copy memory with QEMU's host memmove.
    /// CI 2026-11-23: glibc memcpy +23-40%, FP +12-23%, Steam unchanged.
    var cpuModel = "max"
    /// Settings written before version 2 had neoverse-n1 as the default CPU
    /// model; load() moves those to the new default once.
    var settingsVersion = 2
    var vulkan = true
    /// Diagnostic: boot without GPU acceleration (plain virtio-gpu, SPICE 2D,
    /// software rendering in Linux). Slow, but isolates GPU-path crashes.
    var safeGraphics = false
    /// Guest RAM in a file mapping (Library/Caches) instead of anonymous
    /// memory. A new key (was fileBackedRAM, off) so saved settings from
    /// older builds pick up the new default.
    var ramInFile = true
    var steamBigPicture = false
    var steamBeta = false
    /// CEF without GPU. On by default: the only mode in which the Steam
    /// window has been seen painting on a device (build 21); GPU mode left
    /// it black.
    var steamSoftwareUI = true
    /// Experimental: Steam's UI drawn by the GPU through Mesa's Zink (OpenGL
    /// on Vulkan, i.e. Venus and MoltenVK), as Valve's ARM64 client seems to
    /// expect (its steamwebhelper.sh sets the Zink option
    /// LIBGL_KOPPER_DISABLE). Software drawing costs the emulated CPU the most.
    /// Needs Vulkan in Linux (build 31+). Overrides the software setting.
    var steamGpuUI = false
    /// Turns on Steam's own Low Performance and Low Bandwidth library modes
    /// (no animations, blur or trailers; smaller images) before Steam starts.
    /// Needs runtime 0.1.11. Off leaves those Steam settings as they are.
    var steamLightLibrary = true
    /// Skips Steam's Friends and Chat UI (-nofriendsui -nochatui): fewer
    /// web views for the emulated CPU to run. Needs runtime 0.1.6.
    var steamLightweight = true
    /// Opens Steam's Small Mode (a plain list of installed games) instead
    /// of the full library and store page: far fewer images and web views.
    /// On by default on iPhone, where the full UI is also hard to read.
    var steamSmallMode = Device.isPhone
    /// Keeps Steam's UI from drawing while it is not on screen: Linux
    /// minimises Steam's windows while the iPad shows iDeck's own screens or
    /// a game, and runs steamwebhelper at the lowest priority while a game
    /// runs (steam-ui-daemon, runtime 0.1.9+).
    var steamInBackground = true
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
              var s = try? JSONDecoder().decode(Settings.self, from: mergedData) else { return Settings() }
        if (saved["settingsVersion"] as? Int ?? 1) < 2 {
            // neoverse-n1 was the default, not a choice, before version 2.
            if s.cpuModel == "neoverse-n1" { s.cpuModel = "max" }
            s.settingsVersion = 2
        }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Paths.settingsFile, options: .atomic)
        }
    }
}
