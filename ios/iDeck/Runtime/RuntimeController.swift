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
    static let edition: String = (Bundle.main.object(forInfoDictionaryKey: "IDeckEdition") as? String) ?? "jit"

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
        refreshInstalledState()
        memory.apply = { [weak self] actions in await self?.applyPressure(actions) }
        memory.start()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.didReturnToForeground() }
        })
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
        if tailTicks % 30 == 0, case .running = phase {
            Task { await captureGuestLogs() }
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
                          + "guest cpu \(Int(metrics.cpuPercent))%")
        }
    }

    /// The guest kernel command line: the manifest's, made verbose so the
    /// serial console shows boot progress (shown live in Diagnostics).
    private func kernelCmdline(_ manifest: String) -> String {
        let base = manifest.isEmpty
            ? "root=/dev/vda rootfstype=ext4 rw console=ttyAMA0 loglevel=4 transparent_hugepage=never ideck.mode=gaming"
            : manifest
        let parts = base.split(separator: " ").map(String.init)
            .filter { $0 != "quiet" && !$0.hasPrefix("systemd.show_status=") }
        // mitigations=off: the VM runs only this user's Linux, and under TCG
        // every mitigation (branch-history flushes on each syscall and
        // exception) is emulated code. nowatchdog: no lockup-detector timer
        // wakeups on idle vCPUs.
        let extra = ["systemd.show_status=true", "mitigations=off", "nowatchdog"]
            .filter { e in !parts.contains { $0.split(separator: "=").first == e.split(separator: "=").first } }
        return (parts + extra).joined(separator: " ")
    }

    private func boot(_ files: RuntimeFiles) async throws {
        let s = settings
        phase = .starting("Planning memory")
        let physMb = IDPlatform.physicalMemory >> 20
        let limitMb = (IDPlatform.availableMemory + IDPlatform.physFootprint) >> 20
        let inputs = MemoryInputs(physicalMb: physMb, appLimitMb: limitMb,
                                  currentFootprintMb: IDPlatform.physFootprint >> 20,
                                  increasedMemoryLimit: IDPlatform.hasIncreasedMemoryLimit,
                                  userGuestMb: s.guestMemoryMb, cpus: s.profile.cpus, vulkan: s.vulkan,
                                  ramFile: s.ramInFile)
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
            DiagLog.write("vulkan: on, Venus blob memory file-backed (\(Paths.gpuSharedMemory.lastPathComponent))")
        }
        cfg.gl = !s.safeGraphics
        if s.safeGraphics { DiagLog.write("safe graphics: GPU acceleration off (virtio-gpu 2D)") }
        cfg.audio = s.audio ? "hda" : "none"
        cfg.splitWx = RuntimeController.edition == "jit"
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
        memory.guestMb = plan.guestMb

        phase = .booting("Connecting to Linux")
        try await connectChannels()
        if RuntimeController.sharedMemory.fileFallback {
            // QEMU and virglrenderer are loaded now: their imports should be redirected.
            DiagLog.write("gpu shm: \(RuntimeController.sharedMemoryStats)")
        }
        phase = .booting("Booting Linux")
    }

    private func qemuEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        env["ANGLE_DEFAULT_PLATFORM"] = "metal"
        if let icd = Bundle.main.url(forResource: "vulkan", withExtension: nil)?
            .appendingPathComponent("icd.d/MoltenVK_icd.json"), FileManager.default.fileExists(atPath: icd.path) {
            env["VK_DRIVER_FILES"] = icd.path
        }
        if let group = RuntimeController.sharedMemory.group ?? IDPlatform.applicationGroupIdentifier {
            // virglrenderer creates Venus blob memory with shm_open(), which
            // the sandbox only allows under the app group prefix.
            env["APP_SANDBOX_GROUP_ID"] = group
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                let shm = Paths.ensure(container.appendingPathComponent("tmp", isDirectory: true))
                env["XDG_RUNTIME_DIR"] = shm.path
            }
        } else if settings.vulkan && !RuntimeController.sharedMemory.fileFallback {
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
        try await qmp.connect(path: Paths.qmpSocket.path)
        DiagLog.write("QMP ready (QEMU main loop running)")

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

    private func agentEvent(_ event: String, _ data: [String: Any]) {
        switch event {
        case "ready":
            DiagLog.write("guest agent ready after \(Int(Date().timeIntervalSince(bootStartedAt ?? Date())))s: kernel \(data["kernel"] as? String ?? "?")")
            guestInfo = data
            if let p = data["provision"] as? [String: Any] { provision = p }
            phase = .running
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
            Task { await growLibraryIfNeeded() }
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
        for (unit, lines, url) in units {
            guard let r = try? await agent.requestDict("logs", ["unit": unit, "lines": lines], timeout: 30),
                  let out = r["output"] as? String else { continue }
            try? Data(out.utf8).write(to: url, options: .atomic)
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

    private func afterGuestReady() async {
        guard let agent else { return }
        _ = try? await agent.request("time.sync", ["unix_ms": Int64(Date().timeIntervalSince1970 * 1000)])
        await applySteamSettings()
        if let st = try? await agent.requestDict("steam.status"), (st["service"] as? String) != "active" {
            _ = try? await agent.request("steam.start", timeout: 60)
        }
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
        let options: [String: Any] = ["bigpicture": s.steamBigPicture, "beta": s.steamBeta,
                                      "cef_software": s.steamSoftwareUI, "overlay": s.showPerformanceOverlay,
                                      "lightweight": s.steamLightweight, "small_mode": s.steamSmallMode]
        let signature = "bigpicture=\(s.steamBigPicture) beta=\(s.steamBeta) cef_software=\(s.steamSoftwareUI)"
            + " lightweight=\(s.steamLightweight) small_mode=\(s.steamSmallMode)"
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
    private func growLibraryIfNeeded() async {
        guard !growing, let decision = StorageManager.decide(), decision.grow else { return }
        growing = true
        defer { growing = false }
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

    func setGuestResolution(width: Int, height: Int) async {
        _ = try? await agent?.request("display.set", ["width": width, "height": height])
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
