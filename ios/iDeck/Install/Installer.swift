import Foundation
import UIKit

/// The one-tap first-run installer. Every step is recorded in the core
/// install journal, so an interrupted install resumes where it stopped and a
/// failed step can be retried without redoing earlier ones.
@MainActor
final class Installer: ObservableObject {
    struct StepView: Identifiable, Equatable {
        var id: String
        var title: String
        var state: String
        var detail: String
        var progress: Double
    }

    @Published private(set) var steps: [StepView] = []
    @Published private(set) var running = false
    @Published private(set) var currentDetail = ""
    @Published private(set) var downloadSpeed: Double = 0
    @Published private(set) var needsJIT = false
    @Published private(set) var downloading = false
    @Published private(set) var pausedMessage: String?
    private var pauseRequested = false
    @Published private(set) var failure: String?
    /// Steps that finished with warnings (optional checks that failed).
    @Published private(set) var notes: [String] = []
    @Published private(set) var manifestSummary: String?

    private let runtime: RuntimeController
    private let downloader = Downloader()
    private var manifest: [String: Any] = [:]

    init(runtime: RuntimeController) {
        self.runtime = runtime
        reloadJournal(recover: true)
    }

    var isComplete: Bool { steps.last?.state == "done" }

    /// Runtime source: Advanced Settings override, else the URL CI baked into
    /// Info.plist (the GitHub release of the repository that built the app).
    static var manifestURL: URL? {
        let custom = UserDefaults.standard.string(forKey: "ideck.manifestURL").flatMap { $0.isEmpty ? nil : $0 }
        let plist = (Bundle.main.object(forInfoDictionaryKey: "IDeckRuntimeManifestURL") as? String)
            .flatMap { $0.isEmpty || $0.contains("$(") ? nil : $0 }
        guard let s = custom ?? plist, let url = URL(string: s), url.scheme == "https" else { return nil }
        return url
    }

    private func journal(_ method: String, _ extra: [String: Any] = [:]) throws -> [String: Any] {
        var args = extra
        args["path"] = Paths.journal.path
        args["app_build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return try Core.callDict(method, args) as? [String: Any] ?? [:]
    }

    func reloadJournal(recover: Bool = false) {
        guard let j = try? journal("journal.load", recover ? ["recover": true] : [:]) else { return }
        let raw = j["steps"] as? [[String: Any]] ?? []
        var mapped = raw.map { s in
            StepView(id: s["id"] as? String ?? "", title: s["title"] as? String ?? "",
                     state: s["state"] as? String ?? "pending", detail: s["error"] as? String ?? "",
                     progress: (s["state"] as? String) == "done" ? 1 : 0)
        }
        // Keep live progress for the step in flight.
        for i in mapped.indices {
            if let old = steps.first(where: { $0.id == mapped[i].id }), mapped[i].state == "running" {
                mapped[i].progress = old.progress
                if mapped[i].detail.isEmpty { mapped[i].detail = old.detail }
            }
        }
        steps = mapped
    }

    private func update(_ id: String, detail: String? = nil, progress: Double? = nil) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        if let detail { steps[i].detail = detail; currentDetail = detail }
        if let progress { steps[i].progress = progress }
    }

    // MARK: Run

    func run() async {
        guard !running else { return }
        running = true
        failure = nil
        pausedMessage = nil
        defer { running = false }
        // Until setup has finished, always use the newest published runtime:
        // fixes for the guest (e.g. Steam dependencies) ship there. Linux must
        // not be running, as the system disk is replaced.
        if !isComplete, Paths.activeRuntimeVersion != nil, !runtime.isRunning,
           let newer = await newerRuntimeAvailable() {
            DiagLog.write("setup: runtime \(newer) is newer than \(Paths.activeRuntimeVersion ?? "?"); reinstalling runtime")
            _ = try? journal("journal.reset_from", ["id": "fetch-manifest"])
            reloadJournal()
        }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        while let step = steps.first(where: { $0.state != "done" && $0.state != "skipped" }) {
            do {
                _ = try journal("journal.begin", ["id": step.id])
                reloadJournal()
                let skipped = try await perform(step.id)
                _ = try journal(skipped ? "journal.skip" : "journal.complete", ["id": step.id])
                reloadJournal()
            } catch is CancellationError {
                return
            } catch let e as WaitForUser {
                // Not a failure: the step needs the user (enable JIT, resume
                // a paused download, relaunch).
                _ = try? journal("journal.fail", ["id": step.id, "error": e.message])
                reloadJournal()
                pausedMessage = e.message
                return
            } catch {
                _ = try? journal("journal.fail", ["id": step.id, "error": error.localizedDescription])
                reloadJournal()
                failure = "\(step.title): \(error.localizedDescription)"
                return
            }
        }
    }

    /// The published runtime version if it is newer than the installed one.
    func newerRuntimeAvailable() async -> String? {
        guard let source = Installer.manifestURL, let installed = Paths.activeRuntimeVersion else { return nil }
        var req = URLRequest(url: source)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let published = m["runtime_version"] as? String,
              Installer.compareVersions(published, installed) > 0 else { return nil }
        return published
    }

    /// Numeric dotted-version comparison ("0.1.10" > "0.1.9").
    static func compareVersions(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] {
            s.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    /// Downloads and installs the newest runtime, then re-runs the in-guest
    /// setup. Linux must not be running (the system disk is replaced).
    func updateRuntime() async {
        guard !runtime.isRunning else {
            failure = "Shut down Linux before updating the runtime."
            return
        }
        _ = try? journal("journal.reset_from", ["id": "fetch-manifest"])
        reloadJournal()
        await run()
    }

    /// Re-runs from a given step (rollback of that step and everything after).
    func retry(from id: String) async {
        _ = try? journal("journal.reset_from", ["id": id])
        reloadJournal()
        await run()
    }

    /// Only meaningful while the runtime download step runs (the button is
    /// only shown then). Resume data is kept for Continue Setup.
    func pauseDownloads() {
        guard downloading else { return }
        pauseRequested = true
        downloader.pause()
    }

    struct WaitForUser: Error { let message: String }

    /// Returns true when the step was skipped.
    private func perform(_ id: String) async throws -> Bool {
        switch id {
        case "check-device": try checkDevice()
        case "check-storage": try checkStorage(required: 12 << 30)
        case "check-distribution": checkDistribution()
        case "fetch-manifest": try await fetchManifest()
        case "download-runtime": try await downloadRuntime()
        case "verify-runtime": try await verifyRuntime()
        case "install-runtime": try await installRuntime()
        case "create-storage":
            try StorageManager.ensureDataDisk()
            update(id, detail: "Game library created (grows automatically as you install games)")
        case "boot-guest": try await bootGuest()
        case "install-steam", "install-compat", "init-graphics", "init-audio", "init-input", "self-test":
            return try await waitForGuestStep(id)
        case "ready":
            update(id, detail: "Ready")
        default:
            break
        }
        return false
    }

    private func checkDevice() throws {
        let ram = IDPlatform.physicalMemory >> 30
        let model = IDPlatform.modelIdentifier
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 17, minorVersion: 0, patchVersion: 0)) else {
            throw Core.CallError(message: "\(Device.os) 17 or later is required")
        }
        guard ram >= 6 else {
            throw Core.CallError(message: "\(model) has \(ram) GB of memory; iDeck needs at least 8 GB")
        }
        // Device RAM alone is not enough: iOS limits each app to a share of it
        // (5120 MiB measured on an M5 iPad Pro; 8 GB iPhones and the M3 iPad
        // Air are not measured yet). Check the real limit with the same plan
        // a boot uses before downloading the runtime and creating the disks.
        let plan = try Core.call("memory.plan", MemoryInputs.measured(Settings.load()), as: MemoryPlan.self)
        DiagLog.write("setup: \(Device.summary), app memory limit \(plan.limitMb) MiB -> Linux \(plan.guestMb) MiB, "
                      + "fits \(plan.fits), tiers \(plan.allowedTiers.map(String.init).joined(separator: "/"))")
        guard plan.fits else {
            throw Core.CallError(message: "\(Device.os) lets iDeck use \(plan.limitMb) MiB of memory on this \(Device.name). "
                                 + "Linux needs more than that even at its smallest size (\(plan.guestMb) MiB plus iDeck itself), "
                                 + "so iDeck cannot run on this device.")
        }
        var detail = "\(model), \(ram) GB memory, \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
            + " · app limit \(plan.limitMb) MiB, Linux \(plan.guestMb / 1024) GB"
        if plan.guestMb < 3072 {
            detail += " (only 2 GB fits: Steam will be slow and may be closed by \(Device.os))"
        }
        update("check-device", detail: detail)
    }

    private func checkStorage(required: Int64) throws {
        let free = Paths.volumeFreeBytes
        guard free >= required else {
            throw Core.CallError(message: "Only \(Format.bytes(free)) free; \(Format.bytes(required)) needed. Free up space and retry.")
        }
        update("check-storage", detail: "\(Format.bytes(free)) available")
    }

    private func checkDistribution() {
        var parts: [String] = []
        parts.append("Signing: \(IDPlatform.signingKind)")
        if let profile = SigningProfile.current {
            parts.append("Signature valid until "
                         + DateFormatter.localizedString(from: profile.expires, dateStyle: .medium, timeStyle: .short))
        }
        if RuntimeController.edition == "se" {
            parts.append("Edition: interpreter (no JIT, not suitable for games)")
        } else {
            parts.append(IDPlatform.isDebuggerAttached ? "JIT: enabled" : "JIT: not enabled yet (needed to start Linux)")
        }
        let shm = RuntimeController.sharedMemory
        parts.append(shm.group != nil ? "GPU shared memory: app group"
                     : shm.fileFallback ? "GPU shared memory: file fallback (no app group)"
                     : "GPU shared memory: unavailable (Vulkan off)")
        parts.append(IDPlatform.hasIncreasedMemoryLimit ? "Increased memory limit: yes" : "Increased memory limit: no")
        update("check-distribution", detail: parts.joined(separator: " · "))
    }

    private func fetchManifest() async throws {
        guard let source = Installer.manifestURL else {
            throw Core.CallError(message: "No runtime source is configured. Set the manifest URL in Settings › Advanced.")
        }
        let (data, response) = try await URLSession.shared.data(from: source)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Core.CallError(message: "manifest download failed (HTTP \(http.statusCode))")
        }
        let text = String(decoding: data, as: UTF8.self)
        guard let m = try Core.callDict("manifest.validate", ["text": text]) as? [String: Any] else {
            throw Core.CallError(message: "manifest rejected")
        }
        let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        if let minBuild = m["min_app_build"] as? Int, minBuild > build {
            throw Core.CallError(message: "This runtime needs a newer iDeck (build \(minBuild)); update the app.")
        }
        manifest = m
        try data.write(to: Paths.state.appendingPathComponent("manifest.pending.json"), options: .atomic)
        let dl = (m["total_download_size"] as? NSNumber)?.int64Value ?? 0
        let inst = (m["total_installed_size"] as? NSNumber)?.int64Value ?? 0
        manifestSummary = "Runtime \(m["runtime_version"] ?? "?") · download \(Format.bytes(dl)) · installed \(Format.bytes(inst))"
        update("fetch-manifest", detail: manifestSummary)
        // Re-check storage against the real requirement plus library headroom.
        try checkStorage(required: dl + inst + (8 << 30))
    }

    private func loadPendingManifest() throws -> [String: Any] {
        if !manifest.isEmpty { return manifest }
        let data = try Data(contentsOf: Paths.state.appendingPathComponent("manifest.pending.json"))
        guard let m = try Core.callDict("manifest.validate", ["text": String(decoding: data, as: UTF8.self)]) as? [String: Any] else {
            throw Core.CallError(message: "stored manifest is invalid")
        }
        manifest = m
        return m
    }

    private func artifacts() throws -> [[String: Any]] {
        try loadPendingManifest()["artifacts"] as? [[String: Any]] ?? []
    }

    private func downloadURL(_ a: [String: Any]) -> URL {
        let file = (a["url"] as? String).flatMap { URL(string: $0)?.lastPathComponent } ?? (a["file"] as? String ?? "artifact")
        return Paths.downloads.appendingPathComponent(file)
    }

    private func downloadRuntime() async throws {
        let arts = try artifacts()
        let total = arts.reduce(Int64(0)) { $0 + ((($1["size"]) as? NSNumber)?.int64Value ?? 0) }
        var before: Int64 = 0
        downloading = true
        pauseRequested = false
        defer { downloading = false }
        for a in arts {
            guard let urlString = a["url"] as? String, let url = URL(string: urlString) else { continue }
            let size = (a["size"] as? NSNumber)?.int64Value ?? 0
            do {
                try await downloadOne(url, to: downloadURL(a), size: size, before: before, total: total)
            } catch {
                if pauseRequested {
                    downloadSpeed = 0
                    throw WaitForUser(message: "Download paused. Tap Continue Setup to resume where it stopped.")
                }
                throw error
            }
            before += size
        }
        downloadSpeed = 0
    }

    private func downloadOne(_ url: URL, to dest: URL, size: Int64, before: Int64, total: Int64) async throws {
            _ = try await downloader.download(url, to: dest, expectedSize: size) { [weak self] p in
                Task { @MainActor in
                    guard let self else { return }
                    self.downloadSpeed = p.bytesPerSecond
                    let done = before + p.received
                    let eta = p.bytesPerSecond > 0 ? Double(total - done) / p.bytesPerSecond : 0
                    self.update("download-runtime",
                                detail: "\(Format.bytes(done)) of \(Format.bytes(total)) · \(Format.bytes(Int64(p.bytesPerSecond)))/s · \(Format.duration(eta)) left",
                                progress: total > 0 ? Double(done) / Double(total) : 0)
                }
            }
    }

    private func verifyRuntime() async throws {
        for a in try artifacts() {
            let file = downloadURL(a)
            let expected = a["sha256"] as? String ?? ""
            let name = file.lastPathComponent
            let got = try await Task.detached(priority: .userInitiated) {
                try ArtifactInstaller.sha256(of: file) { p in
                    Task { @MainActor in self.update("verify-runtime", detail: "Verifying \(name)", progress: p) }
                }
            }.value
            guard got == expected else {
                try? FileManager.default.removeItem(at: file)
                // Force a fresh download of the corrupt file.
                _ = try? journal("journal.reset_from", ["id": "download-runtime"])
                throw Core.CallError(message: "\(name) failed verification (got \(got.prefix(12))…); it will be downloaded again")
            }
        }
        update("verify-runtime", detail: "All checksums match")
    }

    private func installRuntime() async throws {
        let m = try loadPendingManifest()
        guard let version = m["runtime_version"] as? String else { throw Core.CallError(message: "manifest has no version") }
        let fm = FileManager.default
        let staging = Paths.runtimeRoot.appendingPathComponent("\(version).staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for a in try artifacts() {
            let src = downloadURL(a)
            let dest = staging.appendingPathComponent(a["file"] as? String ?? "artifact")
            let size = (a["installed_size"] as? NSNumber)?.uint64Value ?? 0
            let expected = a["installed_sha256"] as? String ?? (a["sha256"] as? String ?? "")
            let name = dest.lastPathComponent
            let compression = a["compression"] as? String ?? ""
            let got: String = try await Task.detached(priority: .userInitiated) {
                if compression == "xz" {
                    return try ArtifactInstaller.expandXZ(src, to: dest, expectedSize: size) { p in
                        Task { @MainActor in self.update("install-runtime", detail: "Installing \(name)", progress: p) }
                    }
                }
                try fm.copyItem(at: src, to: dest)
                return try ArtifactInstaller.sha256(of: dest)
            }.value
            guard got == expected else {
                throw Core.CallError(message: "\(name) does not match the manifest after installing")
            }
        }
        // Atomic switch; the previous runtime is kept for rollback.
        let final = Paths.runtimeRoot.appendingPathComponent(version, isDirectory: true)
        let previous = Paths.activeRuntimeVersion
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: staging, to: final)
        try? fm.removeItem(at: Paths.installedManifest)
        try fm.copyItem(at: Paths.state.appendingPathComponent("manifest.pending.json"), to: Paths.installedManifest)
        try Paths.setActiveRuntime(version)
        UserDefaults.standard.set(previous, forKey: "ideck.previousRuntime")
        // Keep only current and previous runtimes; drop downloads.
        for dir in (try? fm.contentsOfDirectory(atPath: Paths.runtimeRoot.path)) ?? [] {
            if dir != version && dir != previous && dir != "current" { try? fm.removeItem(at: Paths.runtimeRoot.appendingPathComponent(dir)) }
        }
        for a in try artifacts() { try? fm.removeItem(at: downloadURL(a)) }
        runtime.refreshInstalledState()
        update("install-runtime", detail: "Runtime \(version) installed")
    }

    /// Rolls back to the previously installed runtime (if any).
    func rollbackRuntime() throws {
        guard let prev = UserDefaults.standard.string(forKey: "ideck.previousRuntime"),
              FileManager.default.fileExists(atPath: Paths.runtimeDir(prev).appendingPathComponent("system.img").path) else {
            throw Core.CallError(message: "No previous runtime to roll back to")
        }
        try Paths.setActiveRuntime(prev)
        runtime.refreshInstalledState()
    }

    private func bootGuest(stepID: String = "boot-guest") async throws {
        if !runtime.isRunning {
            guard runtime.jitAvailable else {
                needsJIT = true
                throw WaitForUser(message: "Enable JIT, then continue setup")
            }
            needsJIT = false
            update(stepID, detail: stepID == "boot-guest" ? "Starting Linux for the first time (this can take a few minutes)"
                                                           : "Starting Linux to continue setup")
            // Not awaited: the loop below shows each startup phase, elapsed
            // time and the guest console while QEMU starts.
            Task { await runtime.startGaming() }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        // Wait for the guest agent's ready event.
        // In CI the same image reaches the agent in ~35 s under TCG; give the
        // first boot on device generous headroom, then fail with the evidence.
        let started = Date()
        let deadline = started.addingTimeInterval(10 * 60)
        while Date() < deadline {
            switch runtime.phase {
            case .running:
                update(stepID, detail: "Linux is running (\(Int(Date().timeIntervalSince(started))) s)", progress: 1)
                return
            case .failed(let m):
                throw Core.CallError(message: m)
            case .needsJIT:
                needsJIT = true
                throw WaitForUser(message: "Enable JIT, then continue setup")
            case .needsRelaunch:
                throw WaitForUser(message: runtime.relaunchReason
                                  ?? "Close iDeck from the app switcher and open it again to continue")
            case .notInstalled:
                throw Core.CallError(message: "The runtime files are missing. Use Repair Setup to reinstall them.")
            case .booting(let s), .starting(let s):
                let elapsed = Int(Date().timeIntervalSince(started))
                let console = runtime.consoleTail.last.map { " · \($0.prefix(90))" } ?? " · no console output yet"
                update(stepID, detail: "\(s) · \(elapsed / 60):\(String(format: "%02d", elapsed % 60))\(console)")
            default:
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let lastConsole = runtime.consoleTail.suffix(6).joined(separator: "\n")
        throw Core.CallError(message: "Linux did not finish booting within 10 minutes. Last console output:\n"
                             + (lastConsole.isEmpty ? "(none: the guest kernel printed nothing)" : lastConsole))
    }

    /// Mirrors a step of the in-guest provisioning service.
    private func waitForGuestStep(_ id: String) async throws -> Bool {
        // After an app restart Linux is not running: start it here (asking
        // for JIT first if needed) instead of stopping with no way forward.
        if !runtime.isRunning || runtime.phase != .running {
            try await bootGuest(stepID: id)
        }
        let deadline = Date().addingTimeInterval(4 * 3600)
        var retried = false
        while Date() < deadline {
            guard runtime.isRunning else {
                throw WaitForUser(message: "Linux stopped. Close iDeck from the app switcher, open it again and tap Continue Setup.")
            }
            let steps = runtime.provision["steps"] as? [[String: Any]] ?? []
            if let s = steps.first(where: { $0["id"] as? String == id }) {
                let state = s["state"] as? String ?? "pending"
                update(id, detail: s["detail"] as? String, progress: s["progress"] as? Double)
                switch state {
                case "done": return false
                case "warning":
                    // Optional checks failed (e.g. Vulkan): setup goes on.
                    let note = "\(s["title"] as? String ?? id): \(s["detail"] as? String ?? "warning")"
                    if !notes.contains(note) { notes.append(note) }
                    DiagLog.write("setup: \(id) passed with warnings: \(s["detail"] as? String ?? "")")
                    return false
                case "skipped": return true
                case "failed":
                    let detail = s["detail"] as? String ?? "failed in Linux"
                    DiagLog.write("setup: \(id) failed in Linux: \(detail)")
                    // Only downloads are worth one automatic retry; the checks
                    // are deterministic, and every rerun restarts the whole
                    // provisioning (GPU probes included).
                    if !retried, id == "install-steam" || id == "install-compat" {
                        retried = true
                        _ = try? await runtime.agent?.request("provision.retry")
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                        continue
                    }
                    throw Core.CallError(message: detail)
                default: break
                }
            } else if runtime.provision["cached"] as? Bool == true, runtime.provision["state"] as? String == "done" {
                return false
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw Core.CallError(message: "timed out waiting for Linux setup")
    }
}
