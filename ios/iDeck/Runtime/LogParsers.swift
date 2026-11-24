import Foundation

// Parsing of iDeck's own logs and of Steam's journal. Foundation only, so CI
// compiles and tests it on macOS without the app (ios/tests/log_parsers).

enum SessionLogParsing {
    /// Signal name of the last crash.log entry written at or after `since`
    /// (Unix seconds). Entries look like
    /// "=== iDeck crash: SIGTRAP (5) at 0x... code 0 thread '?' time 1794402737".
    static func crashSignal(in crashLog: String, since: Double) -> String? {
        var found: String?
        for line in crashLog.split(separator: "\n") where line.hasPrefix("=== iDeck crash: ") {
            let words = line.split(separator: " ")
            guard let t = words.lastIndex(of: "time"), t + 1 < words.count,
                  let when = Double(words[t + 1]), when >= since.rounded(.down) else { continue }
            found = words.count > 3 ? String(words[3]) : "a signal"
        }
        return found
    }

    /// Where the app last was according to its "app: <state>" trace lines:
    /// active, inactive, background, foreground or terminating (memory
    /// warnings and thermal changes are not placements).
    static func lastAppPlacement(in trace: [String]) -> String? {
        let placements: Set<String> = ["active", "inactive", "background", "foreground", "terminating"]
        for line in trace.reversed() {
            guard let r = line.range(of: " app: ") else { continue }
            let word = String(line[r.upperBound...].prefix { $0.isLetter || $0 == "-" })
            if placements.contains(word) { return word }
        }
        return nil
    }

    /// iOS sent a memory warning or system memory pressure above normal.
    static func sawMemoryPressure(in trace: [String]) -> Bool {
        trace.contains { line in
            line.contains(" app: memory-warning")
                || line.contains("memory pressure from iOS: warning")
                || line.contains("memory pressure from iOS: critical")
        }
    }
}

/// What Steam's own updater is doing, read from its journal lines
/// ("Downloading update (A of B KB)...", "Extracting package...").
///
/// After Valve publishes a client update Steam downloads and installs it
/// before its window appears (574 MB on device, build 23); under emulation
/// that takes minutes and the screen only shows the small updater window.
struct SteamUpdateState: Equatable {
    enum Stage: Equatable { case checking, downloading, installing, verifying }
    var stage: Stage
    var doneKB: Int = 0
    var totalKB: Int = 0

    /// nil when the newest updater line says Steam is past updating (or none
    /// is present).
    static func parse(_ log: String) -> SteamUpdateState? {
        for raw in log.split(separator: "\n").reversed() {
            let line = String(raw)
            if line.contains("Downloading update ("), let r = line.range(of: "Downloading update (") {
                let nums = line[r.upperBound...].prefix { $0 != ")" }
                    .components(separatedBy: " of ")
                    .map { Int($0.filter(\.isNumber)) ?? 0 }
                return SteamUpdateState(stage: .downloading, doneKB: nums.first ?? 0, totalKB: nums.count > 1 ? nums[1] : 0)
            }
            if line.contains("Extracting package") || line.contains("Installing update") || line.contains("Cleaning up") {
                return SteamUpdateState(stage: .installing)
            }
            if line.contains("Verifying installation") || line.contains("Performing checksum verification") {
                return SteamUpdateState(stage: .verifying)
            }
            if line.contains("Checking for available updates") || line.contains("Downloading manifest") {
                return SteamUpdateState(stage: .checking)
            }
            // The updater is done (or had nothing to do) and the client runs.
            // Order in the CI journal (runtime 0.1.6): "Extracting package..."
            // (about 5 min), "Installing update...", "Cleaning up...", "Update
            // complete, launching Steam...", "Shutdown", then a restart with
            // "Verifying installation..." / "Verification skipped".
            if line.contains("Update complete") || line.contains("Nothing to do") || line.contains("Download skipped")
                || line.contains("Verification skipped") || line.contains("Verification complete")
                || line.contains("steamwebhelper") || line.contains("] Shutdown") {
                return nil
            }
        }
        return nil
    }

    var summary: String {
        switch stage {
        case .checking: return "Steam is checking for a client update…"
        case .downloading:
            guard totalKB > 0 else { return "Steam is downloading a client update…" }
            let pct = min(100, doneKB * 100 / max(1, totalKB))
            // Steam prints KB; MB as 1000 KB matches its "574,010 KB" ≈ 574 MB.
            return "Steam is downloading a client update: \(doneKB / 1000) of \(totalKB / 1000) MB (\(pct)%)"
        case .installing: return "Steam is installing its client update…"
        case .verifying: return "Steam is verifying its installation…"
        }
    }
}

/// QEMU monitor output recorded when Linux shows nothing for a while after
/// QEMU started (RuntimeController.probeBootStall).
enum BootProbeParsing {
    /// The counters of HMP "info jit" that show whether TCG translates code,
    /// e.g. "gen code size 1234/1073736704, TB count 45, TB flush count 0".
    static func jitSummary(_ text: String) -> String {
        let keys = ["gen code size", "TB count", "TB flush count", "TB invalidate count", "TLB full flushes"]
        var out: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: " ").joined(separator: " ")
            if keys.contains(where: { line.hasPrefix($0 + " ") }) { out.append(line) }
        }
        return out.isEmpty ? "no counters (\(text.prefix(80)))" : out.joined(separator: ", ")
    }

    /// Program counter and exception level of each vCPU from HMP
    /// "info registers -a" (target/arm aarch64_cpu_dump_state), e.g.
    /// "0 PC=ffff800080e1c2a4 EL1h, 1 PC=0000000040000000 EL1h".
    static func vcpuSummary(_ text: String) -> String {
        var out: [String] = []
        var rest = Substring(text)
        while let pc = rest.range(of: "PC=") {
            let hex = rest[pc.upperBound...].prefix { $0.isHexDigit }
            rest = rest[pc.upperBound...]
            var el = "EL?"
            let next = rest.range(of: "PC=")?.lowerBound ?? rest.endIndex
            if let ps = rest[..<next].range(of: "PSTATE=") {
                let words = rest[ps.upperBound..<next].split(whereSeparator: { $0 == " " || $0.isNewline })
                if let w = words.prefix(4).first(where: { $0.hasPrefix("EL") }) { el = String(w) }
            }
            out.append("\(out.count) PC=\(hex) \(el)")
        }
        return out.isEmpty ? "no registers (\(text.prefix(80)))" : out.joined(separator: ", ")
    }
}
