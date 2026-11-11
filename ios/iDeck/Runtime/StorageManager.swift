import Foundation

/// Game library disk management: sparse creation, growth, snapshots
/// (APFS clones), and the optional library image on an external drive.
enum StorageManager {
    private static let usageKey = "ideck.guestLibraryUsage"

    static func ensureDataDisk() throws {
        let path = Paths.dataDisk.path
        guard !FileManager.default.fileExists(atPath: path) else { return }
        let r = try Core.callDict("storage.initial_size", ["host_free": Paths.volumeFreeBytes]) as? [String: Any]
        let size = (r?["size"] as? NSNumber)?.uint64Value ?? (24 << 30)
        // Blank sparse file: the guest formats it on first boot
        // (x-systemd.makefs) and grows the filesystem with the file.
        _ = try Core.callDict("storage.create_sparse", ["path": path, "size": size])
    }

    static func recordGuestUsage(used: UInt64, size: UInt64) {
        guard size > 0 else { return }
        UserDefaults.standard.set(["used": used, "size": size], forKey: usageKey)
    }

    static func usage() -> (size: Int64, allocated: Int64, free: Int64) {
        guard let r = try? Core.callDict("storage.usage", ["path": Paths.dataDisk.path]) as? [String: Any] else {
            return (0, 0, Paths.volumeFreeBytes)
        }
        return ((r["size"] as? NSNumber)?.int64Value ?? 0, (r["allocated"] as? NSNumber)?.int64Value ?? 0,
                (r["free"] as? NSNumber)?.int64Value ?? 0)
    }

    static func decide() -> StorageDecision? {
        guard let u = UserDefaults.standard.dictionary(forKey: usageKey),
              let used = (u["used"] as? NSNumber)?.uint64Value,
              let fsSize = (u["size"] as? NSNumber)?.uint64Value else { return nil }
        let disk = usage()
        struct Req: Encodable {
            var hostFree: UInt64, diskSize: UInt64, diskAllocated: UInt64, fsSize: UInt64, fsUsed: UInt64
        }
        let req = Req(hostFree: UInt64(max(0, Paths.volumeFreeBytes)), diskSize: UInt64(max(0, disk.size)),
                      diskAllocated: UInt64(max(0, disk.allocated)), fsSize: fsSize, fsUsed: used)
        return try? Core.call("storage.decide", req, as: StorageDecision.self)
    }

    /// Before boot the file can simply be enlarged: the guest grows the
    /// filesystem at mount time (x-systemd.growfs).
    static func growBeforeBootIfNeeded() throws {
        guard let d = decide(), d.grow else { return }
        try growDataDisk(to: d.newSize)
    }

    static func growDataDisk(to size: UInt64) throws {
        _ = try Core.callDict("storage.grow", ["path": Paths.dataDisk.path, "size": size])
    }

    // MARK: Snapshots

    struct Snapshot: Identifiable {
        var id: String { url.lastPathComponent }
        var url: URL
        var date: Date
        var allocated: Int64
    }

    static func snapshots() -> [Snapshot] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: Paths.snapshots, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return items.filter { $0.pathExtension == "img" }.map { u in
            let date = (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let alloc = ((try? Core.callDict("storage.usage", ["path": u.path])) as? [String: Any])?["allocated"]
            return Snapshot(url: u, date: date, allocated: (alloc as? NSNumber)?.int64Value ?? 0)
        }.sorted { $0.date > $1.date }
    }

    /// Instant copy-on-write snapshot of the library (APFS clonefile).
    /// Only safe while Linux is stopped (the image must be quiescent).
    @discardableResult
    static func createSnapshot() throws -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dst = Paths.snapshots.appendingPathComponent("library-\(f.string(from: Date())).img")
        _ = try Core.callDict("storage.clone", ["src": Paths.dataDisk.path, "dst": dst.path])
        return dst
    }

    static func restoreSnapshot(_ s: Snapshot) throws {
        let fm = FileManager.default
        let backup = Paths.library.appendingPathComponent("data.img.before-restore")
        try? fm.removeItem(at: backup)
        try fm.moveItem(at: Paths.dataDisk, to: backup)
        do {
            _ = try Core.callDict("storage.clone", ["src": s.url.path, "dst": Paths.dataDisk.path])
            try? fm.removeItem(at: backup)
        } catch {
            try? fm.moveItem(at: backup, to: Paths.dataDisk)
            throw error
        }
    }

    static func deleteSnapshot(_ s: Snapshot) throws {
        try FileManager.default.removeItem(at: s.url)
    }

    // MARK: External library (USB-C SSD via the Files app)

    static func setExternalFolder(_ url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw Core.CallError(message: "\(Device.os) denied access to that folder")
        }
        defer { url.stopAccessingSecurityScopedResource() }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        var s = Settings.load()
        s.externalLibraryBookmark = bookmark
        s.save()
        let image = url.appendingPathComponent("ideck-library-external.img")
        if !FileManager.default.fileExists(atPath: image.path) {
            let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity) ?? 0
            let size = UInt64(max(16 << 30, min(Int64(free) - (4 << 30), 512 << 30)))
            _ = try Core.callDict("storage.create_sparse", ["path": image.path, "size": size])
        }
    }

    /// Resolves the external image and keeps the security scope open for
    /// the lifetime of the VM (QEMU reads it directly).
    static func externalLibraryImage() -> URL? {
        guard let bm = Settings.load().externalLibraryBookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bm, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        let image = url.appendingPathComponent("ideck-library-external.img")
        return FileManager.default.fileExists(atPath: image.path) ? image : nil
    }

    static func clearExternalFolder() {
        var s = Settings.load()
        s.externalLibraryBookmark = nil
        s.save()
    }

    /// Removes partial downloads and logs.
    static func cleanCaches() -> Int64 {
        let fm = FileManager.default
        var freed: Int64 = 0
        for dir in [Paths.downloads] {
            for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
                freed += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                try? fm.removeItem(at: u)
            }
        }
        return freed
    }
}
