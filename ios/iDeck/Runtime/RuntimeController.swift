import AVFoundation
import Combine
import Foundation
import UIKit

/// Owns the Linux VM: plans memory, builds the QEMU command line with the
/// shared core, starts QEMU in-process, connects SPICE / QMP / agent / input,
/// and turns guest events into published state for the UI.
@MainActor
final class RuntimeController: ObservableObject {
    enum Phase: Equatable {
        case notInstalled
        case stopped
        case needsJIT
        case needsRelaunch
        case starting(String)
        case booting(String)
        case running
        case stopping
        case failed(String)
    }

    struct GuestMetrics {
        var cpuPercent: Double = 0
        var perCore: [Double] = []
        var memTotalKB: UInt64 = 0
        var memUsedKB: UInt64 = 0
        var libraryUsed: UInt64 = 0
        var librarySize: UInt64 = 0
        var steamRunning = false
        var uptime: Double = 0
        var updated = Date.distantPast
    }

    @Published private(set) var phase: Phase = .stopped {
        didSet { if phase != oldValue { DiagLog.write("phase: \(phase.traceLabel)") } }
    }
    /// Live tails for the diagnostics panel (refreshed every 2 s).
    @Published private(set) var consoleTail: [String] = []
    @Published private(set) var qemuLogTail: [String] = []
    @Published private(set) var bootStartedAt: Date?
    private var tailTimer: Timer?
    @Published private(set) var plan: MemoryPlan?
    @Published private(set) var guestInfo: [String: Any] = [:]
    @Published private(set) var metrics = GuestMetrics()
    @Published private(set) var provision: [String: Any] = [:]
    @Published private(set) var displayConnected = false
    @Published private(set) var warnings: [String] = []
    /// Result of the floating-point check in Linux (EngineGuard.checkSummary), once it has run.
    @Published private(set) var engineCheck: String?
    private var nativeFPInUse = false
    private var bootRuntimeVersion = ""
    @Published var lastError: String?

    let controllers = ControllerBridge()
    let memory = MemoryMonitor()
    private(set) var spice: IDSpiceClient?
    private var launcher: IDQemuLauncher?
    private var qmp: QMPClient?
    private(set) var agent: AgentClient?
    private var input: InputChannel?
    private var settings: Settings { Settings.load() }
    private var bootStarted = Date()
    private var loggedProvisionDetails = Set<String>()
    private let spiceEvents = SpiceEventLog()
    private var lastDisplaySummary = ""
    private var displaySummaryLoggedAt = Date.distantPast
    private var lastSharedMemoryStats = ""
    private var observers: [NSObjectProtocol] = []

    /// "jit" for the sideload edition, "se" for the interpreter (TestFlight) edition.
    nonisolated static let edition: String = (Bundle.main.object(forInfoDictionaryKey: "IDeckEdition") as? String) ?? "jit"

    /// Venus (Vulkan) blob memory is POSIX shared memory named under an app
    /// group (UTM's virglrenderer, anon_file.c); iOS refuses the name unless
    /// the code signature carries that group, and free Apple ID signing drops
    /// app groups. Then the embedded frameworks' shm_open() is served from
    /// unlinked files in tmp/ (IDSharedMemoryFallback), checked here with the
    /// same call sequence and with a Metal round trip. Decided once per
    /// launch, before QEMU is loaded.
    struct SharedMemoryCheck {
        var group: String?
        /// Why POSIX shared memory itself is unavailable (nil when it works).
        var shmProblem: String?
        /// Files stand in for shared memory.
        var fileFallback = false
        /// Why Venus cannot get blob memory at all; nil when it can.
        var problem: String?
        var summary: String {
            if let group { return "ok under \(group)" }
            if fileFallback { return "file-backed fallback (POSIX shared memory refused: \(shmProblem ?? "unknown"))" }
            return "unavailable (\(problem ?? "unknown"))"
        }
    }
    static let sharedMemory: SharedMemoryCheck = {
        let candidates = IDPlatform.applicationGroupCandidates
        var problems: [String] = []
        for group in candidates {
            if let problem = IDPlatform.sharedMemoryProblem(forGroup: group) {
                problems.append(problem)
            } else {
                return SharedMemoryCheck(group: group)
            }
        }
        let shmProblem = problems.isEmpty ? "no app group in the signing profile" : problems.joined(separator: "; ")
        // Only this app's frameworks (QEMU, virglrenderer, SPICE) are pointed
        // at the stand-in; the app binary keeps the real call for the probe.
        let frameworks = (Bundle.main.privateFrameworksPath ?? Bundle.main.bundlePath + "/Frameworks") + "/"
        guard id_shm_fallback_install(Paths.gpuSharedMemory.path, frameworks, IDShmFallbackWhenDenied) == 0 else {
            let why = String(cString: strerror(errno))
            return SharedMemoryCheck(shmProblem: shmProblem, problem: "\(shmProblem); file fallback not installed: \(why)")
        }
        var err = [CChar](repeating: 0, count: 256)
        if id_shm_fallback_selftest(1 << 20, &err, err.count) != 0 {
            return SharedMemoryCheck(shmProblem: shmProblem,
                                     problem: "\(shmProblem); file fallback failed: \(String(cString: err))")
        }
        if let metal = IDPlatform.fileBackedGPUMemoryProblem() {
            return SharedMemoryCheck(shmProblem: shmProblem, problem: "\(shmProblem); file fallback: \(metal)")
        }
        return SharedMemoryCheck(shmProblem: shmProblem, fileFallback: true)
    }()

    /// One line for the log: what the shm stand-in has done so far.
    static var sharedMemoryStats: String {
        var st = IDShmFallbackStats()
        id_shm_fallback_get_stats(&st)
        return "\(st.images_patched) images / \(st.slots_patched) imports redirected"
            + (st.patch_failures > 0 ? " (\(st.patch_failures) failed)" : "")
            + ", \(st.file_opens) of \(st.opens) allocations file-backed"
            + (st.file_failures > 0 ? ", \(st.file_failures) failed" : "")
    }

    init() {
        IDCrashLog.install(withPath: Paths.crashLog.path)
        DiagLog.rotate()
        DiagLog.write("iDeck launch: \(IDPlatform.modelIdentifier), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion), "
                      + "edition \(RuntimeController.edition), signing \(IDPlatform.signingKind), "
                      + "CS_DEBUGGED \(IDPlatform.isDebuggerAttached), traced \(IDPlatform.isTraced), "
                      + "app group \(IDPlatform.applicationGroupIdentifier ?? "none") (\(IDPlatform.applicationGroupSource)), "
                      + "available \(IDPlatform.availableMemory >> 20) MiB, footprint \(IDPlatform.physFootprint >> 20) MiB, "
                      + "RAM \(IDPlatform.physicalMemory >> 20) MiB, cores \(IDPlatform.performanceCores)P+\(IDPlatform.efficiencyCores)E, "
                      + "increased-memory-limit \(IDPlatform.hasIncreasedMemoryLimit), "
                      + "extended-virtual-addressing \(IDPlatform.hasExtendedVirtualAddressing); \(Device.summary)")
        DiagLog.write("signature: app groups \((IDPlatform.signedEntitlements?["com.apple.security.application-groups"] as? [String]) ?? []), "
                      + "candidates \(IDPlatform.applicationGroupCandidates), GPU shared memory \(RuntimeController.sharedMemory.summary)")
        DiagLog.write(SigningProfile.current?.logLine() ?? "signing profile: none embedded")
        if let previous = SessionMarker.takePrevious() {
            DiagLog.write(previous.logLine)
            previousSessionNotice = previous.userMessage
            // "vkr-ring" threads run Linux's Vulkan commands in MoltenVK. With
            // Steam's interface drawn by the GPU (experimental) iDeck crashed
            // there on device: SIGSEGV in vkCmdBindPipeline, build 41.
            if previous.signal != nil, previous.crashThread?.hasPrefix("vkr-") == true {
                var changed = Settings.load()
                if changed.steamGpuUI {
                    changed.steamGpuUI = false
                    changed.save()
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: Settings.changedOnDisk, object: nil)
                    }
                    DiagLog.write("steam: GPU-drawn UI switched off after a crash on \(previous.crashThread ?? "?")")
                    previousSessionNotice = "iDeck crashed in the graphics driver while Steam's interface was drawn by the GPU, "
                        + "so GPU-drawn Steam UI was switched off. It is experimental; you can switch it back on in Settings."
                }
            }
        }
        refreshInstalledState()
        memory.apply = { [weak self] actions in await self?.applyPressure(actions) }
        memory.start()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.logAppState("foreground")
                await self?.didReturnToForeground()
            }
        })
        // Where the app was when a session ends without a crash report: the
        // next launch reads the last "app:" line (SessionMarker).
        let states: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "active"),
            (UIApplication.willResignActiveNotification, "inactive"),
            (UIApplication.willTerminateNotification, "terminating"),
            (UIApplication.didReceiveMemoryWarningNotification, "memory-warning"),
            (ProcessInfo.thermalStateDidChangeNotification, "thermal"),
        ]
        for (name, label) in states {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.logAppState(label) }
            })
        }
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didEnterBackground() }
        })
    }

    /// Shown once on the home screen when the previous session ended while
    /// Linux was running.
    @Published var previousSessionNotice: String?

    private func logAppState(_ state: String) {
        DiagLog.write("app: \(state) (Linux \(phase.traceLabel), footprint \(IDPlatform.physFootprint >> 20) MiB, "
                      + "available \(IDPlatform.availableMemory >> 20) MiB, thermal \(RuntimeController.thermalLabel), "
                      + "traced \(IDPlatform.isTraced))")
    }

    static var thermalLabel: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// iOS suspends iDeck a few seconds after it leaves the screen (and may
    /// then close it to free memory). Linux gets those seconds to write its
    /// page cache to the library disk, so a closed session loses less (a
    /// Steam update in progress, downloads).
    private func didEnterBackground() {
        logAppState("background")
        guard case .running = phase, let agent else { return }
        let app = UIApplication.shared
        let task = BackgroundTaskBox()
        task.id = app.beginBackgroundTask(withName: "ideck.sync-linux") {
            DiagLog.write("app: background time ran out before Linux finished syncing")
            task.finish()
        }
        let started = Date()
        Task { @MainActor in
            let ok = (try? await agent.request("fs.sync", timeout: 20)) != nil
            DiagLog.write("app: Linux disks synced for the background: \(ok ? "ok" : "failed") "
                          + "after \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            await self.captureGuestLogs()
            task.finish()
        }
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        if case .booting = phase { return true }
        return false
    }

    func refreshInstalledState() {
        guard !isRunning else { return }
        if IDQemuLauncher.hasStarted && !(launcher?.running ?? false) {
            phase = .needsRelaunch
        } else if RuntimeFiles.current() == nil {
            phase = .notInstalled
        } else if case .notInstalled = phase {
            phase = .stopped
        }
    }

    /// Whether QEMU's JIT can work if started now.
    ///
    /// On iPadOS 26+ (TXM) the utmapp QEMU asks an *attached* debugger to
    /// prepare its code buffer (`brk #0x69`, only when P_TRACED), which is
    /// what StikDebug's legacy.js script services; it stays attached until
    /// that request. CS_DEBUGGED alone (StikDebug without a script attaches
    /// and detaches at once) is not enough. Seen on device: CS_DEBUGGED true,
    /// traced false.
    var jitAvailable: Bool {
        if RuntimeController.edition == "se" { return true }
        if IDPlatform.needsTXMJITProtocol { return IDPlatform.isTraced }
        return IDPlatform.isDebuggerAttached
    }

    /// Plain-language reason JIT is not usable, for the help screen.
    var jitProblem: String {
        if !IDPlatform.isDebuggerAttached {
            return "JIT is not enabled yet."
        }
        if IDPlatform.needsTXMJITProtocol && !IDPlatform.isTraced {
            return "JIT was enabled, but StikDebug detached right away. On \(Device.os) 26 and later iDeck needs StikDebug's legacy.js script, which stays attached until Linux starts."
        }
        return "JIT is ready."
    }

    /// Incremented when StikDebug hands iDeck back with JIT ready; setup and
    /// the game screen continue automatically.
    @Published private(set) var jitReadyEvent = 0
    private var jitRequestPending = false

    /// When this process was first seen with the debugger attached.
    private(set) var jitAttachedAt: Date? = IDPlatform.isTraced ? Date() : nil
    /// Why Linux needs a fresh launch of iDeck (shown instead of the generic text).
    @Published private(set) var relaunchReason: String?
    /// On device (build 16): JIT attached at launch, then a 50 s runtime
    /// download; QEMU's first `brk #0x69` was never answered and iDeck died
    /// with SIGTRAP in tcg_region_init. Boots 1-6 s after attaching worked.
    /// StikDebug is most likely suspended once it has been in the background
    /// for a while, so an old attachment is not trusted.
    static let jitFreshSeconds: TimeInterval = 45

    /// The debugger attached so long ago that StikDebug may no longer answer
    /// QEMU's JIT request.
    var jitIsStale: Bool {
        guard RuntimeController.edition == "jit", IDPlatform.needsTXMJITProtocol, IDPlatform.isTraced,
              let at = jitAttachedAt else { return false }
        return Date().timeIntervalSince(at) > RuntimeController.jitFreshSeconds
    }

    /// Asks StikDebug to attach to this process with legacy.js (StikDebug's
    /// documented enable-jit URL). StikDebug asks the user to confirm, then
    /// returns to iDeck.
    func requestJIT() {
        var c = URLComponents()
        c.scheme = "stikdebug"
        c.host = "enable-jit"
        c.queryItems = [
            URLQueryItem(name: "bundle-id", value: Bundle.main.bundleIdentifier ?? "com.ideck.app"),
            URLQueryItem(name: "pid", value: String(getpid())),
            URLQueryItem(name: "script-name", value: "legacy.js"),
        ]
        guard let url = c.url else { return }
        jitRequestPending = true
        DiagLog.write("requesting JIT: \(url.absoluteString)")
        UIApplication.shared.open(url) { ok in
            if !ok { DiagLog.write("could not open StikDebug (not installed?)") }
        }
    }

    // MARK: Start

    /// The one-tap "Start Gaming" path. Resumes if Linux is already running.
    func startGaming() async {
        switch phase {
        case .running, .booting, .starting:
            return
        default:
            break
        }
        guard let files = RuntimeFiles.current() else {
            phase = .notInstalled
            return
        }
        guard !IDQemuLauncher.hasStarted else {
            phase = .needsRelaunch
            return
        }
        guard jitAvailable else {
            phase = .needsJIT
            return
        }
        if jitIsStale {
            let age = Int(Date().timeIntervalSince(jitAttachedAt ?? Date()))
            DiagLog.write("jit: debugger attached \(age) s ago; not starting QEMU (its JIT request would go unanswered)")
            relaunchReason = "JIT was enabled \(age) seconds ago, and StikDebug stops answering after a while in the background. "
                + "Close iDeck from the app switcher, enable JIT again in StikDebug, and Linux starts right away."
            phase = .needsRelaunch
            return
        }
        do {
            try await boot(files)
        } catch {
            DiagLog.write("boot failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription + tailOfLog())
            lastError = error.localizedDescription
        }
    }

    private func startLogTail() {
        tailTimer?.invalidate()
        tailTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTails() }
        }
        refreshTails()
    }

    private var tailTicks = 0

    func refreshTails() {
        consoleTail = DiagLog.tail(Paths.consoleLog, lines: 12)
        qemuLogTail = DiagLog.tail(Paths.qemuLog, lines: 8)
        // Memory trend every 10 s while Linux runs: if iPadOS terminates
        // iDeck (jetsam), ideck.previous.log shows what led up to it.
        tailTicks += 1
        if tailTicks % 5 == 0, isRunning, let spice {
            // What the display pipeline has; logged when it changes and once a
            // minute, so a black screen can be traced to Linux or to iDeck.
            let summary = spice.diagnosticSummary
            if summary != lastDisplaySummary || Date().timeIntervalSince(displaySummaryLoggedAt) > 60 {
                DiagLog.write("display: \(summary)")
                lastDisplaySummary = summary
                displaySummaryLoggedAt = Date()
            }
        }
        if tailTicks % 15 == 0, isRunning, let spice {
            spice.saveSnapshot(to: Paths.displaySnapshot) { _ in }
        }
        // Linux journals: 20 s after the agent is up (on device a session
        // ended before the old first capture at 60 s), then every 30 s, and
        // every 6 s while Steam installs a client update (progress banner).
        if case .running = phase, let up = runningSince {
            let firstDue = !firstCaptureDone && Date().timeIntervalSince(up) >= 20
            if firstDue || tailTicks % (steamUpdate == nil ? 15 : 3) == 0 {
                if firstDue { firstCaptureDone = true }
                Task { await captureGuestLogs() }
            }
        }
        if tailTicks % 30 == 0, case .running = phase {
            if RuntimeController.sharedMemory.fileFallback {
                let stats = RuntimeController.sharedMemoryStats
                if stats != lastSharedMemoryStats {
                    DiagLog.write("gpu shm: \(stats)")
                    lastSharedMemoryStats = stats
                }
            }
        }
        if tailTicks % 5 == 0 && (isRunning || phase == .stopping) {
            DiagLog.write("mem: footprint \(IDPlatform.physFootprint >> 20) MiB, available \(IDPlatform.availableMemory >> 20) MiB, "
                          + "guest used \(metrics.memUsedKB >> 10)/\(metrics.memTotalKB >> 10) MiB, pressure \(memory.sample.level), "
                          + "guest cpu \(Int(metrics.cpuPercent))%, traced \(IDPlatform.isTraced), "
                          + "thermal \(RuntimeController.thermalLabel), disk free \(StorageManager.usage().free >> 20) MiB")
        }
    }

    /// The guest kernel command line: the manifest's, made verbose so the
    /// serial console shows boot progress (shown live in Diagnostics).
    private func kernelCmdline(_ manifest: String) -> String {
        let base = manifest.isEmpty
            ? "root=/dev/vda rootfstype=ext4 rw console=ttyAMA0 loglevel=4 transparent_hugepage=never ideck.mode=gaming"
            : manifest
        // loglevel=6: the kernel's own boot messages reach the serial console
        // too (at 4 only warnings did), so a start that stalls before systemd
        // still shows how far the kernel got.
        let parts = base.split(separator: " ").map(String.init)
            .filter { $0 != "quiet" && !$0.hasPrefix("systemd.show_status=") && !$0.hasPrefix("loglevel=") }
            + ["loglevel=6"]
        // mitigations=off: the VM runs only this user's Linux, and under TCG
        // every mitigation (branch-history flushes on each syscall and
        // exception) is emulated code. nowatchdog: no lockup-detector timer
        // wakeups on idle vCPUs. kpti=0: with KASLR on a CPU model without
        // E0PD (neoverse-n1/-v1) Linux forces page-table isolation on before
        // it looks at mitigations=off, and each user/kernel switch then
        // flushes QEMU's whole soft TLB (see default_kernel_cmdline).
        let extra = ["systemd.show_status=true", "mitigations=off", "nowatchdog", "kpti=0"]
            .filter { e in !parts.contains { $0.split(separator: "=").first == e.split(separator: "=").first } }
        return (parts + extra).joined(separator: " ")
    }

    private func boot(_ files: RuntimeFiles) async throws {
        let s = settings
        phase = .starting("Planning memory")
        let inputs = MemoryInputs.measured(s)
        let limitMb = inputs.appLimitMb
        let plan = try Core.call("memory.plan", inputs, as: MemoryPlan.self)
        self.plan = plan
        warnings = plan.notes
        DiagLog.write("boot: runtime \(files.version), JIT CS_DEBUGGED \(IDPlatform.isDebuggerAttached) traced \(IDPlatform.isTraced), "
                      + "limit \(limitMb) MiB -> guest \(plan.guestMb) MiB, tb \(plan.tbCacheMb), hostmem \(plan.hostmemMb), "
                      + "cpus \(s.profile.cpus), cpu \(s.cpuModel), vulkan \(s.vulkan)")
        bootStartedAt = Date()
        for log in [Paths.qemuLog, Paths.consoleLog] { try? FileManager.default.removeItem(at: log) }
        startLogTail()

        phase = .starting("Preparing game storage")
        try StorageManager.ensureDataDisk()
        try StorageManager.growBeforeBootIfNeeded()

        phase = .starting("Configuring virtual machine")
        for url in [Paths.spiceSocket, Paths.qmpSocket, Paths.controlSocket, Paths.inputSocket] {
            try? FileManager.default.removeItem(at: url)
        }
        let res = s.resolution.size
        var cfg = VMConfig(kernel: files.kernel.path, initrd: files.initrd?.path ?? "",
                           systemDisk: files.system.path, dataDisk: Paths.dataDisk.path,
                           cmdline: kernelCmdline(files.cmdline), guestMb: plan.guestMb, cpus: s.profile.cpus,
                           tbCacheMb: plan.tbCacheMb, cpuModel: s.cpuModel,
                           hostmemMb: plan.hostmemMb, width: res.width, height: res.height,
                           refreshHz: s.refreshHz, spiceSocket: Paths.spiceSocket.path,
                           qmpSocket: Paths.qmpSocket.path, controlSocket: Paths.controlSocket.path,
                           inputSocket: Paths.inputSocket.path, consoleLog: Paths.consoleLog.path)
        cfg.vulkan = s.vulkan && !s.safeGraphics
        if cfg.vulkan, let problem = RuntimeController.sharedMemory.problem {
            // Without blob memory every Venus blob fails (virtio-gpu
            // RESOURCE_CREATE_BLOB -> ERR_UNSPEC) and Vulkan programs in Linux
            // only error out; OpenGL (VirGL over ANGLE/Metal) needs no blobs.
            cfg.vulkan = false
            warnings.append("Vulkan is off for this session: no GPU shared memory (\(problem)). OpenGL still works.")
            DiagLog.write("vulkan: off, GPU shared memory unavailable: \(problem)")
        } else if cfg.vulkan, RuntimeController.sharedMemory.fileFallback {
            DiagLog.write("vulkan: on, Venus blob memory file-backed (\(Paths.gpuSharedMemory.lastPathComponent)), "
                          + "APP_SANDBOX_GROUP_ID \(ShmGroup.fallback)")
        }
        cfg.gl = !s.safeGraphics
        if s.safeGraphics { DiagLog.write("safe graphics: GPU acceleration off (virtio-gpu 2D)") }
        cfg.audio = s.audio ? "hda" : "none"
        cfg.splitWx = RuntimeController.edition == "jit"
        // The engine options need iDeck's patched QEMU, which only the JIT
        // edition embeds (the interpreter edition uses UTM's build).
        let engine = EngineGuard.decide(anySettingOn: s.nativeFloatingPoint || s.fastProcessSwitch,
                                        supported: RuntimeController.edition == "jit",
                                        unfinishedStarts: EngineGuard.unfinishedStarts(Paths.nativeFPMarker))
        if engine.switchSettingsOff {
            var changed = Settings.load()
            changed.nativeFloatingPoint = false
            changed.fastProcessSwitch = false
            changed.save()
            NotificationCenter.default.post(name: Settings.changedOnDisk, object: nil)
            EngineGuard.clear(Paths.nativeFPMarker)
            warnings.append("Native floating point and Fast process switching were switched off: Linux did not finish "
                            + "starting with them the last \(EngineGuard.maxUnfinishedStarts) times. You can switch them back on in Settings \u{203A} Advanced.")
            DiagLog.write("engine: options switched off after \(EngineGuard.maxUnfinishedStarts) unfinished starts")
        }
        cfg.hostVfp = engine.useEngine && s.nativeFloatingPoint
        cfg.tlbKeepGlobal = engine.useEngine && s.fastProcessSwitch
        nativeFPInUse = cfg.hostVfp
        bootRuntimeVersion = files.version
        if cfg.hostVfp || cfg.tlbKeepGlobal { EngineGuard.noteStart(Paths.nativeFPMarker) }
        DiagLog.write("engine: native floating point \(cfg.hostVfp ? "on (x-host-vfp)" : "off"), "
                      + "kernel translations kept across process switches \(cfg.tlbKeepGlobal ? "on (x-asid-keep-global)" : "off")")
        if s.ramInFile {
            // Guest RAM as a shared file mapping: iPadOS can write those pages
            // back to disk and drop them, and they are not charged to the app's
            // memory footprint the way anonymous memory is (the guest page
            // cache filled during the Steam download got iDeck terminated).
            try? FileManager.default.removeItem(at: Paths.guestRAMFile)
            cfg.ramFile = Paths.guestRAMFile.path
        }
        DiagLog.write("vm: guest RAM \(cfg.ramFile.isEmpty ? "anonymous" : "file-backed"), vulkan \(cfg.vulkan), gl \(cfg.gl)")
        if let ext = StorageManager.externalLibraryImage() { cfg.extraDisks = [ext.path] }
        let args = try Core.call("qemu.args", cfg, as: QemuArgs.self)
        warnings += args.warnings
        var argv = args.argv
        if let qemuData = Bundle.main.url(forResource: "qemu", withExtension: nil) {
            argv.insert(contentsOf: ["-L", qemuData.path], at: 1)
        }

        DiagLog.write("qemu: " + argv.dropFirst().joined(separator: " "))

        phase = .starting("Starting Linux")
        guard let fw = Bundle.main.privateFrameworksURL?.appendingPathComponent("qemu-aarch64-softmmu.framework"),
              FileManager.default.fileExists(atPath: fw.path) else {
            throw Core.CallError(message: "QEMU framework missing from the app bundle (build problem).")
        }
        let launcher = IDQemuLauncher(frameworkPath: fw.path)
        self.launcher = launcher
        bootStarted = Date()
        try launcher.start(withArguments: argv, environment: qemuEnvironment(), logPath: Paths.qemuLog.path) {
            [weak self] status, message in
            Task { @MainActor in self?.qemuExited(status: status, message: message) }
        }
        SessionMarker.begin(runtime: files.version)
        memory.guestMb = plan.guestMb

        phase = .booting("Connecting to Linux")
        try await connectChannels()
        if RuntimeController.sharedMemory.fileFallback {
            // QEMU and virglrenderer are loaded now: their imports should be redirected.
            DiagLog.write("gpu shm: \(RuntimeController.sharedMemoryStats)")
        }
        phase = .booting("Booting Linux")
        Task { await probeBootStall() }
    }

    /// While Linux has not come up, records at 20, 45 and 90 s what QEMU's
    /// vCPUs are doing: the run state, how much code TCG has translated
    /// (HMP "info jit"), each vCPU's PC and exception level, and which host
    /// threads use CPU time. Three samples show whether anything moves.
    private func probeBootStall() async {
        let started = Date()
        for at in [20.0, 45.0, 90.0] {
            let wait = at - Date().timeIntervalSince(started)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            guard case .booting = phase, let qmp else { return }
            let console = DiagLog.tail(Paths.consoleLog, lines: 1).isEmpty ? "no console output" : "console has output"
            var parts = ["boot probe at \(Int(at)) s: \(console)"]
            if let status = try? await qmp.status() { parts.append("status \(status)") }
            var jitNeverRan = false
            if let jit = try? await qmp.execute("human-monitor-command", ["command-line": "info jit"]) as? String {
                parts.append("jit: " + BootProbeParsing.jitSummary(jit))
                jitNeverRan = (BootProbeParsing.tbCount(jit) ?? 2) <= 1
            }
            if let regs = try? await qmp.execute("human-monitor-command", ["command-line": "info registers -a"]) as? String {
                parts.append("vCPUs: " + BootProbeParsing.vcpuSummary(regs))
            }
            parts.append("threads: " + IDPlatform.threadActivitySummary())
            DiagLog.write(parts.joined(separator: "; "))
            if jitNeverRan, case .booting = phase {
                // A normal boot translates thousands of blocks in its first
                // second. One block after 20 s: the generated code does not
                // run (build 40), and only a fresh process gets new JIT memory.
                DiagLog.write("boot: JIT memory does not run; Linux cannot start in this session")
                EngineGuard.clear(Paths.nativeFPMarker)  // says nothing about the engine options
                relaunchReason = "Linux could not start: the JIT memory StikDebug prepared does not run. "
                    + "Close iDeck from the app switcher, open it again and enable JIT."
                phase = .needsRelaunch
                return
            }
        }
    }

    private func qemuEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        env["ANGLE_DEFAULT_PLATFORM"] = "metal"
        if let icd = Bundle.main.url(forResource: "vulkan", withExtension: nil)?
            .appendingPathComponent("icd.d/MoltenVK_icd.json"), FileManager.default.fileExists(atPath: icd.path) {
            env["VK_DRIVER_FILES"] = icd.path
        }
        let shm = RuntimeController.sharedMemory
        if let group = ShmGroup.forQEMU(usable: shm.group, fileFallback: shm.fileFallback) {
            // virglrenderer creates Venus blob memory with shm_open(), which
            // the sandbox only allows under an app group in the signature;
            // otherwise the file fallback answers under ShmGroup.fallback.
            env["APP_SANDBOX_GROUP_ID"] = group
            if group == shm.group,
               let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                let dir = Paths.ensure(container.appendingPathComponent("tmp", isDirectory: true))
                env["XDG_RUNTIME_DIR"] = dir.path
            }
        } else if settings.vulkan {
            warnings.append("No app group in the signing profile and no file fallback: Vulkan (Venus) blob memory will fail.")
        }
        return env
    }

    private func connectChannels() async throws {
        let qmp = QMPClient()
        qmp.onEvent = { [weak self] event, data in
            Task { @MainActor in self?.qmpEvent(event, data) }
        }
        // Assigned before connecting so qemuExited() can abort the wait if
        // QEMU dies during startup.
        self.qmp = qmp
        DiagLog.write("connecting QMP")
        // On device a start froze here with nothing more in the log (build
        // 41). If QEMU has not answered after 12 s, record where every
        // thread is, from a queue that does not need the main thread.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12) { [weak qmp] in
            guard let qmp, !qmp.isReady else { return }
            DiagLog.write("boot: QEMU has not answered after 12 s; threads:\n  " + IDPlatform.threadStackSummary())
        }
        try await qmp.connect(path: Paths.qmpSocket.path)
        DiagLog.write("QMP ready (QEMU main loop running)")
        DiagLog.write("jit memory: executable \(IDPlatform.jitRegionSummary); \(IDPlatform.addressSpaceSummary)")

        let agent = AgentClient()
        agent.onEvent = { [weak self] event, data in
            Task { @MainActor in self?.agentEvent(event, data) }
        }
        agent.onClose = { [weak self] in
            Task { @MainActor in self?.agentClosed() }
        }
        try await agent.connect(path: Paths.controlSocket.path)
        DiagLog.write("agent channel connected; waiting for the guest agent")
        self.agent = agent

        let input = InputChannel()
        try await input.connect(path: Paths.inputSocket.path)
        DiagLog.write("input channel connected")
        self.input = input
        controllers.hapticsEnabled = settings.hapticsEnabled
        controllers.bind(to: input)

        // SPICE plays guest audio through GStreamer/CoreAudio; set up a
        // playback session first, as UTM does on iOS.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            DiagLog.write("audio session: playback active")
        } catch {
            DiagLog.write("audio session setup failed: \(error.localizedDescription)")
        }
        let spice = IDSpiceClient(socketPath: Paths.spiceSocket.path)
        spice.framesPerSecond = settings.refreshHz
        spice.audioEnabled = settings.audio
        spiceEvents.onChange = { [weak self] connected in
            Task { @MainActor in self?.displayConnected = connected }
        }
        spice.delegate = spiceEvents
        self.spice = spice
        // Display setup (scanout, monitor config) in detail for the first two
        // minutes; per-frame messages make it too noisy to keep on.
        IDSpiceClient.setVerboseLogging(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            IDSpiceClient.setVerboseLogging(false)
            DiagLog.write("display: verbose SPICE logging off")
        }
        try? FileManager.default.removeItem(at: Paths.displaySnapshot)
        let spiceOK = spice.connect()
        DiagLog.write("SPICE connect started: \(spiceOK)")
        if !spiceOK { warnings.append("SPICE display connection failed; retrying when the view appears.") }
        displayConnected = spice.connected
    }

    // MARK: Events

    /// Logs QEMU's disk counters (flushes above all, see BlockStats) at
    /// these times after Linux is up, as long as the same QEMU still runs.
    private func logDiskStats(after seconds: [Int]) {
        Task { [weak self] in
            var waited = 0
            for s in seconds {
                try? await Task.sleep(nanoseconds: UInt64(s - waited) * 1_000_000_000)
                waited = s
                guard let self, let qmp = self.qmp, case .running = self.phase,
                      let reply = try? await qmp.execute("query-blockstats") else { return }
                DiagLog.write("disks after \(s / 60) min: \(BlockStats.summary(BlockStats.parse(reply)))")
            }
        }
    }

    private func agentEvent(_ event: String, _ data: [String: Any]) {
        switch event {
        case "ready":
            DiagLog.write("guest agent ready after \(Int(Date().timeIntervalSince(bootStartedAt ?? Date())))s: kernel \(data["kernel"] as? String ?? "?")"
                          + ", page-table isolation: \((data["kpti"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "no kernel message (agent before runtime 0.1.9, or not forced)")")
            EngineGuard.clear(Paths.nativeFPMarker)
            DiagLog.write("address space with Linux running: \(IDPlatform.addressSpaceSummary)")
            DiagLog.write(IDPlatform.raiseVCPUThreadQoS())
            logDiskStats(after: [180, 600])
            guestInfo = data
            if let p = data["provision"] as? [String: Any] { provision = p }
            phase = .running
            runningSince = Date()
            firstCaptureDone = false
            Task { await afterGuestReady() }
        case "metrics":
            var m = GuestMetrics()
            m.cpuPercent = data["cpu_percent"] as? Double ?? 0
            m.perCore = data["cpu_per_core"] as? [Double] ?? []
            m.memTotalKB = (data["mem_total_kb"] as? NSNumber)?.uint64Value ?? 0
            m.memUsedKB = (data["mem_used_kb"] as? NSNumber)?.uint64Value ?? 0
            if let lib = (data["disks"] as? [String: Any])?["library"] as? [String: Any] {
                m.libraryUsed = (lib["used"] as? NSNumber)?.uint64Value ?? 0
                m.librarySize = (lib["size"] as? NSNumber)?.uint64Value ?? 0
            }
            m.steamRunning = data["steam_running"] as? Bool ?? false
            m.uptime = data["uptime_s"] as? Double ?? 0
            m.updated = Date()
            metrics = m
            memory.guestUsedMb = m.memUsedKB >> 10
            StorageManager.recordGuestUsage(used: m.libraryUsed, size: m.librarySize)
            if Date().timeIntervalSince(storageCheckedAt) > 30 {
                storageCheckedAt = Date()
                Task { await growLibraryIfNeeded() }
            }
        case "provision":
            provision = data
            let steps = (data["steps"] as? [[String: Any]] ?? []).map { s -> String in
                let p = (s["progress"] as? Double).map { String(format: " %.0f%%", $0 * 100) } ?? ""
                return "\(s["id"] as? String ?? "?")=\(s["state"] as? String ?? "?")\(p)"
            }
            DiagLog.write("provision[\(data["state"] as? String ?? "?")]: \(steps.joined(separator: ", "))")
            // What failed and why, once per step and outcome.
            for s in data["steps"] as? [[String: Any]] ?? [] {
                guard let id = s["id"] as? String, let state = s["state"] as? String,
                      state == "failed" || state == "warning" else { continue }
                let line = "provision \(id) \(state): \(s["detail"] as? String ?? "")"
                if loggedProvisionDetails.insert(line).inserted { DiagLog.write(line) }
            }
        case "shutdown":
            phase = .stopping
        default:
            break
        }
    }

    private func qmpEvent(_ event: String, _ data: [String: Any]) {
        if event == "SHUTDOWN" { phase = .stopping }
    }

    private func agentClosed() {
        if case .running = phase { warnings.append("Lost connection to the Linux agent.") }
    }

    private func qemuExited(status: Int32, message: String?) {
        DiagLog.write("QEMU exited with status \(status)\(message.map { ": \($0)" } ?? "")")
        SessionMarker.end()
        steamUpdate = nil
        refreshTails()
        spice?.disconnect()
        qmp?.abort("QEMU exited during startup (status \(status)). \(message ?? "")")
        agent?.close()
        input?.close()
        controllers.bind(to: nil)
        displayConnected = false
        // Guest RAM contents are worthless now; unlinking frees the disk space
        // once the mapping goes away with the process.
        try? FileManager.default.removeItem(at: Paths.guestRAMFile)
        if let message, status != 0 {
            phase = .failed(message + tailOfLog())
            lastError = message
        } else {
            phase = .needsRelaunch
        }
    }

    private func tailOfLog() -> String {
        guard let log = try? String(contentsOf: Paths.qemuLog, encoding: .utf8), !log.isEmpty else { return "" }
        return "\n\n" + log.split(separator: "\n").suffix(8).joined(separator: "\n")
    }

    private var capturingGuestLogs = false
    private var lastSteamState = ""
    private var runningSince: Date?
    private var firstCaptureDone = false
    /// Steam's own client update while it runs (nil otherwise).
    @Published private(set) var steamUpdate: SteamUpdateState?

    /// Saves the Steam, X session and provisioning journals from Linux next
    /// to the app logs (Share logs includes them) and notes Steam's state in
    /// ideck.log when it changes. Runs every minute while Linux runs.
    func captureGuestLogs() async {
        guard case .running = phase, let agent, !capturingGuestLogs else { return }
        capturingGuestLogs = true
        defer { capturingGuestLogs = false }
        let units: [(String, Int, URL)] = [("ideck-steam.service", 400, Paths.guestSteamLog),
                                           ("ideck-session.service", 150, Paths.guestSessionLog),
                                           ("ideck-provision.service", 150, Paths.guestProvisionLog)]
        let iso = ISO8601DateFormatter()
        // Which session a saved journal belongs to: on device (build 23) the
        // shared linux-*.log files came from an earlier session than ideck.log.
        let header = "# captured \(iso.string(from: Date())) by iDeck pid \(getpid()), Linux up since "
            + "\(runningSince.map { iso.string(from: $0) } ?? "?")\n"
        for (unit, lines, url) in units {
            // While Steam updates (read every 6 s) only its journal is needed.
            if steamUpdate != nil, unit != "ideck-steam.service" { continue }
            guard let r = try? await agent.requestDict("logs", ["unit": unit, "lines": lines], timeout: 30),
                  let out = r["output"] as? String else { continue }
            try? Data((header + out).utf8).write(to: url, options: .atomic)
            if unit == "ideck-steam.service" { noteSteamUpdate(SteamUpdateState.parse(out)) }
        }
        if let st = try? await agent.requestDict("steam.status", [:], timeout: 15) {
            let pids = (st["pids"] as? [Any])?.count ?? 0
            let state = "service \(st["service"] as? String ?? "?"), \(pids) Steam processes"
            if state != lastSteamState {
                DiagLog.write("steam: \(state)")
                lastSteamState = state
            }
        }
    }

    private func noteSteamUpdate(_ state: SteamUpdateState?) {
        guard state != steamUpdate else { return }
        if state?.stage != steamUpdate?.stage || state == nil {
            DiagLog.write("steam update: \(state?.summary ?? "none in progress")")
        }
        steamUpdate = state
    }

    private func afterGuestReady() async {
        guard let agent else { return }
        _ = try? await agent.request("time.sync", ["unix_ms": Int64(Date().timeIntervalSince1970 * 1000)])
        await applySteamSettings()
        steamScreenSent = nil
        await sendSteamScreen(reason: "Linux ready")
        if let st = try? await agent.requestDict("steam.status"), (st["service"] as? String) != "active" {
            _ = try? await agent.request("steam.start", timeout: 60)
        }
        // Linux's display runs at 60 Hz unless another rate is chosen
        // (runtime 0.1.14+; 0.1.13 cannot add the mode, older agents ignore the rate).
        let s = settings
        if s.refreshHz != 60 {
            let size = s.resolution.size
            await setGuestResolution(width: size.width, height: size.height, refresh: s.refreshHz)
            DiagLog.write("display: \(size.width)x\(size.height) at \(s.refreshHz) Hz requested")
        }
        Task { await runEngineCheckOnce() }
    }

    private static let engineCheckKey = "ideck.engineCheck"

    /// Once per runtime, app build and engine mode: Linux runs every
    /// floating-point instruction pattern and compares with the results
    /// recorded on real hardware when the runtime was built (agent
    /// `fpcheck.run`, runtime 0.1.13+). The outcome goes to the log and to
    /// Settings; a difference with native floating point on is a warning.
    private func runEngineCheckOnce() async {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let stamp = "\(bootRuntimeVersion)|\(build)|\(nativeFPInUse)|"
        if let done = UserDefaults.standard.string(forKey: RuntimeController.engineCheckKey), done.hasPrefix(stamp) {
            engineCheck = String(done.dropFirst(stamp.count))
            return
        }
        // Not while Steam is starting: the check keeps a vCPU busy for some seconds.
        try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
        guard let agent, case .running = phase else { return }
        guard let reply = try? await agent.requestDict("fpcheck.run", ["quick": true], timeout: 900) else {
            DiagLog.write("engine: floating-point check not available (runtime before 0.1.13, or it did not finish)")
            return
        }
        let summary = EngineGuard.checkSummary(reply, nativeFP: nativeFPInUse)
        let seconds = (reply["seconds"] as? NSNumber)?.doubleValue ?? 0
        DiagLog.write("engine: floating-point check, \(summary.text) (\(String(format: "%.1f", seconds)) s)")
        engineCheck = summary.text
        if !summary.ok && nativeFPInUse {
            warnings.append("Floating-point check: \(summary.text). Switch off Native floating point in Settings \u{203A} Advanced.")
        }
        UserDefaults.standard.set(stamp + summary.text, forKey: RuntimeController.engineCheckKey)
    }

    /// The launch options Steam last started with, as sent by this app.
    private static let appliedSteamOptionsKey = "ideck.steamOptionsApplied"

    /// Writes Steam's launch options in Linux and restarts Steam when they
    /// differ from what it started with. Steam is started during boot,
    /// before the app is connected, so on device the Software-rendered UI
    /// switch only took effect on the boot after the one it was set in.
    func applySteamSettings() async {
        guard let agent else { return }
        let s = settings
        // GPU drawing needs Venus in Linux; otherwise Steam stays on software.
        let gpuUI = s.steamGpuUI && s.vulkan && !s.safeGraphics
        let software = s.steamSoftwareUI && !gpuUI
        let options: [String: Any] = ["bigpicture": s.steamBigPicture, "beta": s.steamBeta,
                                      "cef_software": software, "webhelper_zink": gpuUI,
                                      "overlay": s.showPerformanceOverlay, "light_library": s.steamLightLibrary,
                                      "lightweight": s.steamLightweight, "small_mode": s.steamSmallMode]
        let signature = "bigpicture=\(s.steamBigPicture) beta=\(s.steamBeta) cef_software=\(software)"
            + " gpu_ui=\(gpuUI) light_library=\(s.steamLightLibrary) lightweight=\(s.steamLightweight)"
            + " small_mode=\(s.steamSmallMode)"
        guard (try? await agent.request("steam.configure", options)) != nil else { return }
        let applied = UserDefaults.standard.string(forKey: RuntimeController.appliedSteamOptionsKey)
        guard applied != signature else { return }
        if let st = try? await agent.requestDict("steam.status"), (st["service"] as? String) == "active" {
            DiagLog.write("steam: options changed (\(signature)); restarting Steam")
            _ = try? await agent.request("steam.restart", timeout: 60)
        }
        UserDefaults.standard.set(signature, forKey: RuntimeController.appliedSteamOptionsKey)
    }

    private func didReturnToForeground() async {
        if jitRequestPending || phase == .needsJIT {
            // StikDebug attaches, then brings iDeck back; give it a moment.
            for _ in 0..<20 where !jitAvailable {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            DiagLog.write("foreground: CS_DEBUGGED \(IDPlatform.isDebuggerAttached) traced \(IDPlatform.isTraced)")
            if jitAvailable {
                jitRequestPending = false
                jitAttachedAt = Date()
                if phase == .needsJIT { phase = .stopped }
                jitReadyEvent += 1
            }
            return
        }
        guard case .running = phase, let agent else { return }
        // The VM was suspended with the app; correct the guest clock.
        _ = try? await agent.request("time.sync", ["unix_ms": Int64(Date().timeIntervalSince1970 * 1000)])
        if let spice, !spice.connected { _ = spice.connect() }
    }

    // MARK: Memory & storage

    private func applyPressure(_ a: PressureActions) async {
        if a.dropGuestCaches { _ = try? await agent?.request("mem.drop_caches") }
        if a.flushDisks { _ = try? await agent?.request("fs.sync") }
        if a.balloonTargetMb > 0 { try? await qmp?.setBalloon(megabytes: a.balloonTargetMb) }
        if a.releaseUiCaches { ArtworkCache.shared.purge() }
    }

    private var growing = false
    private var storageCheckedAt = Date.distantPast
    private func growLibraryIfNeeded() async {
        guard !growing else { return }
        growing = true
        defer { growing = false }
        // decide() asks iOS for the free space it would make available
        // (volumeAvailableCapacityForImportantUsage), which can take a while
        // under heavy disk writes; it ran on the main thread every 2 s.
        let decision = await Task.detached(priority: .utility) { StorageManager.decide() }.value
        guard let decision, decision.grow else { return }
        do {
            try StorageManager.growDataDisk(to: decision.newSize)
            try await qmp?.resizeBlock(node: "data", bytes: decision.newSize)
            _ = try await agent?.request("disk.resize", timeout: 900)
        } catch {
            warnings.append("Could not enlarge the game library: \(error.localizedDescription)")
        }
    }

    // MARK: Stop

    func shutdown() async {
        guard isRunning else { return }
        phase = .stopping
        _ = try? await agent?.request("fs.sync", timeout: 30)
        if (try? await agent?.request("power.off", timeout: 10)) == nil {
            try? await qmp?.powerdown()
        }
        // Escalate if Linux did not power off in time.
        try? await Task.sleep(nanoseconds: 25_000_000_000)
        if launcher?.running == true { try? await qmp?.quit() }
    }

    // MARK: Steam helpers used by the UI

    func steamStatus() async -> [String: Any] {
        (try? await agent?.requestDict("steam.status")) ?? [:]
    }

    func openSteam(_ url: String) async throws {
        guard let agent else { throw Core.CallError(message: "Linux is not running") }
        _ = try await agent.request("steam.open", ["url": url])
    }

    // MARK: Steam's UI only while it is on screen (steam-ui-daemon)

    /// What the iPad shows, sent to Linux: "visible" (the Linux screen with
    /// Steam), "game" (a game is launching or running) or "away" (iDeck's own
    /// screens). Linux minimises Steam's windows unless "visible", so its UI
    /// (Chromium under emulation) stops drawing, and lowers steamwebhelper's
    /// priority while a game runs.
    enum SteamScreen: String { case visible, game, away }
    @Published private(set) var steamScreen: SteamScreen = .away
    private var steamScreenSent: SteamScreen?
    private var gameLaunchPending = false
    private var gameWatch: Task<Void, Never>?
    /// A game process runs in Linux (steam-ui-daemon), however it was
    /// started. Kept current while the Linux screen is shown; the game view
    /// picks the pointer mode from it.
    @Published private(set) var gameRunning = false

    @discardableResult
    func setSteamScreen(_ wanted: SteamScreen, reason: String) -> Task<Void, Never> {
        let s: SteamScreen = settings.steamInBackground ? wanted : .visible
        steamScreen = s
        gameWatch?.cancel()
        gameWatch = nil
        if s == .game { watchGame() } else if s == .visible { watchForGame() }
        return Task { await sendSteamScreen(reason: reason) }
    }

    /// Before Play sends steam://rungameid (the game view opens after it).
    /// Waits until Linux has the state, so Steam's windows are minimised
    /// before the launch and dialogs the launch opens stay on screen.
    func noteGameLaunch() async {
        gameLaunchPending = true
        await setSteamScreen(.game, reason: "game launch").value
    }

    func gameViewAppeared() {
        if gameLaunchPending {
            gameLaunchPending = false
            if steamScreen != .game { setSteamScreen(.game, reason: "game view") }
        } else {
            setSteamScreen(.visible, reason: "game view")
        }
    }

    func gameViewDisappeared() {
        gameLaunchPending = false
        setSteamScreen(.away, reason: "iDeck screens")
    }

    private func sendSteamScreen(reason: String) async {
        guard let agent, isRunning else { return }
        let s = steamScreen
        guard s != steamScreenSent else { return }
        do {
            _ = try await agent.request("steam.ui", ["state": s.rawValue], timeout: 10)
            steamScreenSent = s
            DiagLog.write("steam ui: \(s.rawValue) (\(reason))")
        } catch {
            // Runtimes before 0.1.9 have no steam-ui-daemon; nothing to do.
            DiagLog.write("steam ui: \(s.rawValue) not applied (\(error.localizedDescription))")
            steamScreenSent = s
        }
    }

    /// While a game is expected: when it has run and quits, or when no game
    /// started within 90 s (Steam may be showing why), show Steam again.
    private func watchGame() {
        gameWatch = Task { [weak self] in
            let started = Date()
            var seenRunning = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled, self.steamScreen == .game else { return }
                let running = await self.readGameRunning()
                if running { seenRunning = true }
                if seenRunning && !running {
                    self.setSteamScreen(.visible, reason: "game exited")
                    return
                }
                if !seenRunning && Date().timeIntervalSince(started) > 90 {
                    self.setSteamScreen(.visible, reason: "no game process after 90 s")
                    return
                }
            }
        }
    }

    /// With Steam on screen: notices a game started from Steam's own window.
    private func watchForGame() {
        gameWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled, self.steamScreen == .visible else { return }
                _ = await self.readGameRunning()
            }
        }
    }

    private func readGameRunning() async -> Bool {
        guard let agent, case .running = phase else { return false }
        // steam.ui without a state only reads the daemon's status file.
        let st = (try? await agent.requestDict("steam.ui", [:], timeout: 10)) ?? [:]
        let running = ((st["daemon"] as? [String: Any])?["game_running"] as? Bool) ?? false
        if running != gameRunning {
            gameRunning = running
            DiagLog.write("steam ui: game process \(running ? "running" : "ended")")
        }
        return running
    }

    func restartSteam() async {
        _ = try? await agent?.request("steam.restart", timeout: 60)
    }

    func runSelfTest() async -> [String: Any] {
        (try? await agent?.requestDict("selftest.run", timeout: 600)) ?? ["ok": false, "error": "Linux is not running"]
    }

    func runBenchmark(quick: Bool) async throws -> [String: Any] {
        guard let agent else { throw Core.CallError(message: "Linux is not running") }
        return try await agent.requestDict("bench.run", ["quick": quick], timeout: 1800)
    }

    func setGuestResolution(width: Int, height: Int, refresh: Int = 60) async {
        _ = try? await agent?.request("display.set", ["width": width, "height": height, "refresh": refresh])
    }
}

/// Files of the active runtime version.
struct RuntimeFiles {
    var version: String
    var kernel: URL
    var initrd: URL?
    var system: URL
    var cmdline: String

    static func current() -> RuntimeFiles? {
        guard let v = Paths.activeRuntimeVersion else { return nil }
        let dir = Paths.runtimeDir(v)
        let kernel = dir.appendingPathComponent("Image")
        let system = dir.appendingPathComponent("system.img")
        let initrd = dir.appendingPathComponent("initrd.img")
        let fm = FileManager.default
        guard fm.fileExists(atPath: kernel.path), fm.fileExists(atPath: system.path) else { return nil }
        var cmdline = ""
        if let data = try? Data(contentsOf: Paths.installedManifest),
           let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            cmdline = m["kernel_cmdline"] as? String ?? ""
        }
        return RuntimeFiles(version: v, kernel: kernel, initrd: fm.fileExists(atPath: initrd.path) ? initrd : nil,
                            system: system, cmdline: cmdline)
    }
}

extension RuntimeController.Phase {
    /// Phase text for the boot trace (failures include their message).
    var traceLabel: String {
        if case .failed(let m) = self { return "failed: \(m)" }
        return label
    }
}

/// A UIKit background task that is ended once, by whichever comes first:
/// the work finishing or iOS's expiry handler. Used on the main thread only.
final class BackgroundTaskBox {
    var id: UIBackgroundTaskIdentifier = .invalid

    func finish() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
