import Foundation

/// QEMU's per-disk I/O counters (QMP query-blockstats), summarised for the
/// log. Each guest flush makes QEMU call fdatasync()/fsync() on the image
/// file (util/osdep.c; not F_FULLFSYNC), and Steam's web cache and config
/// writes flush often, so the counters show whether that costs anything.
enum BlockStats {
    struct Disk: Equatable {
        var name: String
        var flushes: Int
        var flushSeconds: Double
        var writes: Int
        var writeMB: Double
        var writeSeconds: Double
        var reads: Int
        var readMB: Double
        var readSeconds: Double
    }

    static func parse(_ reply: Any) -> [Disk] {
        guard let list = reply as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let stats = entry["stats"] as? [String: Any] else { return nil }
            func int(_ key: String) -> Int { (stats[key] as? NSNumber)?.intValue ?? 0 }
            func seconds(_ key: String) -> Double { Double(int(key)) / 1e9 }
            func mb(_ key: String) -> Double { Double(int(key)) / 1_048_576 }
            let name = (entry["device"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (entry["qdev"] as? String) ?? "?"
            return Disk(name: name, flushes: int("flush_operations"), flushSeconds: seconds("flush_total_time_ns"),
                        writes: int("wr_operations"), writeMB: mb("wr_bytes"), writeSeconds: seconds("wr_total_time_ns"),
                        reads: int("rd_operations"), readMB: mb("rd_bytes"), readSeconds: seconds("rd_total_time_ns"))
        }
    }

    static func summary(_ disks: [Disk]) -> String {
        guard !disks.isEmpty else { return "no disks reported" }
        return disks.map { d in
            String(format: "%@: flush %d ops %.1f s, write %d ops %.0f MB %.1f s, read %d ops %.0f MB %.1f s",
                   d.name, d.flushes, d.flushSeconds, d.writes, d.writeMB, d.writeSeconds,
                   d.reads, d.readMB, d.readSeconds)
        }.joined(separator: "; ")
    }
}
