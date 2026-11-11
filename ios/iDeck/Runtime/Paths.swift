import Foundation

/// On-device layout. Everything lives in the app container except an
/// optional external library image chosen by the user.
///
///   Application Support/iDeck/
///     runtime/<version>/{Image, initrd.img, system.img}
///     runtime/current            (text file: active version)
///     library/data.img           (sparse game library disk, never replaced)
///     library/snapshots/*.img    (APFS clones of data.img)
///     state/install-journal.json, settings.json, manifest.json
///   Caches/iDeck/downloads/      (partial downloads)
///   tmp/ideck/                   (sockets, logs for the current run)
enum Paths {
    static let fm = FileManager.default

    static var support: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("iDeck", isDirectory: true), excludeFromBackup: true)
    }

    static var runtimeRoot: URL { ensure(support.appendingPathComponent("runtime", isDirectory: true)) }
    static func runtimeDir(_ version: String) -> URL {
        ensure(runtimeRoot.appendingPathComponent(version, isDirectory: true))
    }
    static var currentRuntimeFile: URL { runtimeRoot.appendingPathComponent("current") }
    static var library: URL { ensure(support.appendingPathComponent("library", isDirectory: true)) }
    static var dataDisk: URL { library.appendingPathComponent("data.img") }
    static var snapshots: URL { ensure(library.appendingPathComponent("snapshots", isDirectory: true)) }
    static var state: URL { ensure(support.appendingPathComponent("state", isDirectory: true)) }
    static var journal: URL { state.appendingPathComponent("install-journal.json") }
    static var installedManifest: URL { state.appendingPathComponent("manifest.json") }
    static var settingsFile: URL { state.appendingPathComponent("settings.json") }
    /// Scratch backing for guest RAM (Settings.ramInFile): in Caches, so it
    /// is never backed up; recreated empty at every boot.
    static var guestRAMFile: URL {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("iDeck", isDirectory: true)).appendingPathComponent("guest-ram.bin")
    }

    static var downloads: URL {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("iDeck/downloads", isDirectory: true))
    }

    /// Short directory for unix sockets: sun_path is limited to 104 bytes.
    static var run: URL {
        ensure(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ideck", isDirectory: true))
    }
    static var spiceSocket: URL { run.appendingPathComponent("s.sock") }
    static var qmpSocket: URL { run.appendingPathComponent("q.sock") }
    static var controlSocket: URL { run.appendingPathComponent("c.sock") }
    static var inputSocket: URL { run.appendingPathComponent("i.sock") }
    /// Documents/Logs: visible in the Files app (On My iPad › iDeck), so logs
    /// can be shared even when the app is stuck.
    static var logs: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ensure(docs.appendingPathComponent("Logs", isDirectory: true))
    }
    static var qemuLog: URL { logs.appendingPathComponent("qemu.log") }
    static var consoleLog: URL { logs.appendingPathComponent("console.log") }
    static var appLog: URL { logs.appendingPathComponent("ideck.log") }
    /// Trace of the previous app session (the one that closed, if it did).
    static var previousAppLog: URL { logs.appendingPathComponent("ideck.previous.log") }
    static var crashLog: URL { logs.appendingPathComponent("crash.log") }
    /// Every log worth sending when something went wrong.
    static var allLogs: [URL] {
        [appLog, previousAppLog, crashLog, qemuLog, consoleLog].filter { fm.fileExists(atPath: $0.path) }
    }

    static var activeRuntimeVersion: String? {
        guard let s = try? String(contentsOf: currentRuntimeFile, encoding: .utf8) else { return nil }
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    static func setActiveRuntime(_ version: String) throws {
        try Data((version + "\n").utf8).write(to: currentRuntimeFile, options: .atomic)
    }

    @discardableResult
    static func ensure(_ url: URL, excludeFromBackup: Bool = false) -> URL {
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        if excludeFromBackup {
            // Disk images can be tens of GB; they must never go to iCloud.
            var u = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? u.setResourceValues(values)
        }
        return url
    }

    static var volumeFreeBytes: Int64 {
        let values = try? support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static var volumeTotalBytes: Int64 {
        let values = try? support.resourceValues(forKeys: [.volumeTotalCapacityKey])
        return Int64(values?.volumeTotalCapacity ?? 0)
    }
}
