import Foundation

// Checks ios/iDeck/Runtime/LogParsers.swift against journal and trace lines in
// the formats seen on device (build 23, runtime 0.1.8) and in CI (runtime
// 0.1.6). Build: swiftc LogParsers.swift main.swift -o log_parsers

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "ok   " : "FAIL ") + what)
    if !ok { failures += 1 }
}

func steam(_ lines: [String]) -> String {
    lines.enumerated().map { i, l in
        "[   \(22 + i).000000] ideck ideck-steam-launch[596]: [2026-11-12 04:07:\(10 + i % 50)] \(l)"
    }.joined(separator: "\n")
}

let start = [
    "Startup - updater built Oct 21 2026 21:09:58",
    "Startup - Steam Client launched with: '/home/deck/.local/share/Steam/steamrtarm64/steam' '-noverifyfiles'",
    "Looks like steam didn't shutdown cleanly, scheduling immediate update check",
    "Checking for update on startup",
    "Checking for available updates...",
    "Downloading manifest: https://client-update.akamai.steamstatic.com/steam_client_linuxarm64",
    "Manifest download: send request",
]
let checking = SteamUpdateState.parse(steam(start))
check(checking?.stage == .checking, "manifest request -> checking")

let downloading = start + [
    "Downloaded new manifest: /steam_client_linuxarm64 version 1794424036, installed version 1792618285, existing pending version 0",
    "Package file steamui_websrc_all.zip.vz.3ed8681b_28971200 missing or incorrect size",
    "Add pending download: https://client-update.akamai.steamstatic.com/steamui_websrc_all.zip.vz.3ed8681b_28971200",
    "Downloading update (23,253 of 574,010 KB)...",
    "Set status message: Downloading update (23,253 of 574,010 KB)...",
    "Set percent complete: 4",
    "Downloading update (563,432 of 574,010 KB)...",
    "Set status message: Downloading update (563,432 of 574,010 KB)...",
    "Set percent complete: 98",
]
let d = SteamUpdateState.parse(steam(downloading))
check(d?.stage == .downloading && d?.doneKB == 563_432 && d?.totalKB == 574_010,
      "download progress parsed with thousands separators: \(String(describing: d))")
check(d?.summary == "Steam is downloading a client update: 563 of 574 MB (98%)", "summary: \(d?.summary ?? "nil")")

let extracting = downloading + [
    "Downloading update (574,010 of 574,010 KB)...",
    "Download complete.",
    "Saving metrics to disk (/home/deck/.local/share/Steam/package/steam_client_metrics.bin)",
    "Found pending update",
    "Installing update...",
    "Extracting package...",
    "Set status message: Extracting package...",
]
check(SteamUpdateState.parse(steam(extracting))?.stage == .installing, "extracting -> installing")

let finished = extracting + [
    "Installing update...",
    "Cleaning up...",
    "Update complete, launching Steam...",
    "Set status message: Update complete, launching Steam...",
    "Shutdown",
]
check(SteamUpdateState.parse(steam(finished)) == nil, "update complete -> none")

let restarted = finished + [
    "Startup - updater built Oct 21 2026 21:09:58",
    "Verifying installation...",
]
check(SteamUpdateState.parse(steam(restarted))?.stage == .verifying, "restart verifying -> verifying")
check(SteamUpdateState.parse(steam(restarted + ["Verification skipped"])) == nil, "verification skipped -> none")

let upToDate = [
    "Checking for available updates...",
    "Downloading manifest: https://client-update.akamai.steamstatic.com/steam_client_linuxarm64",
    "Download skipped: /steam_client_linuxarm64 version 1792618285, installed version 1792618285, existing pending version 0",
    "Nothing to do",
    "Verifying installation...",
    "Verification skipped",
    "Steam Runtime Launch Service: starting steam-runtime-launcher-service",
]
check(SteamUpdateState.parse(steam(upToDate)) == nil, "no update -> none")
check(SteamUpdateState.parse("") == nil, "empty journal -> none")
check(SteamUpdateState.parse(steam(["Looks like steam didn't shutdown cleanly, scheduling immediate update check"])) == nil,
      "'didn't shutdown cleanly' is not an updater stage")

// crash.log entries (IDCrashLog.m format)
let crashLog = """

=== iDeck crash: SIGTRAP (5) at 0x0000000119cc908c code 0 thread '?' time 1794402737
0   iDeck                               0x00000001004b02ac iDeck + 17068
=== end
"""
check(SessionLogParsing.crashSignal(in: crashLog, since: 1_794_402_000) == "SIGTRAP", "crash after session start -> SIGTRAP")
check(SessionLogParsing.crashSignal(in: crashLog, since: 1_794_450_000) == nil, "older crash is not this session's")
check(SessionLogParsing.crashSignal(in: "", since: 0) == nil, "empty crash.log")

// ideck.log trace lines
let trace = [
    "2026-11-12T04:10:29.941Z mem: footprint 981 MiB, available 4138 MiB, guest used 640/2972 MiB, pressure normal, guest cpu 56%",
    "2026-11-12T04:10:30.100Z app: inactive (Linux running, footprint 981 MiB, available 4138 MiB, thermal fair, traced false)",
    "2026-11-12T04:10:30.400Z app: background (Linux running, footprint 981 MiB, available 4138 MiB, thermal fair, traced false)",
    "2026-11-12T04:10:31.000Z app: memory-warning (Linux running, footprint 990 MiB, available 4129 MiB, thermal fair, traced false)",
    "2026-11-12T04:10:31.200Z app: thermal (Linux running, footprint 990 MiB, available 4129 MiB, thermal serious, traced false)",
]
check(SessionLogParsing.lastAppPlacement(in: trace) == "background", "placement ignores memory-warning and thermal lines")
check(SessionLogParsing.sawMemoryPressure(in: trace), "memory warning seen")
check(!SessionLogParsing.sawMemoryPressure(in: Array(trace.prefix(3))), "no memory warning before it")
check(SessionLogParsing.lastAppPlacement(in: Array(trace.prefix(1))) == nil, "no app lines -> nil (builds before 26)")

// Signing profile: a CMS envelope around an XML plist, as Sideloadly embeds it.
func profileData(created: Date, expires: Date) -> Data {
    let plist: [String: Any] = ["Name": "iOS Team Provisioning Profile: com.ideck.app",
                                "CreationDate": created, "ExpirationDate": expires,
                                "Entitlements": ["get-task-allow": true]]
    let xml = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    return Data([0x30, 0x82, 0x2a, 0x1b, 0x06, 0x09, 0x2a, 0x86, 0x48]) + xml + Data([0xa0, 0x82, 0x0b, 0x00, 0x30])
}
let created = Date(timeIntervalSince1970: 1_794_400_000)
let weekly = SigningProfile.parse(profileData(created: created, expires: created.addingTimeInterval(7 * 86_400)))
check(weekly?.name == "iOS Team Provisioning Profile: com.ideck.app", "profile name")
check(weekly?.expires == created.addingTimeInterval(7 * 86_400), "profile expiry")
check(weekly?.isShortLived == true, "7-day profile is short-lived")
let yearly = SigningProfile.parse(profileData(created: created, expires: created.addingTimeInterval(365 * 86_400)))
check(yearly?.isShortLived == false, "1-year profile is long-lived")
check(SigningProfile.parse(Data("no plist here".utf8)) == nil, "garbage -> nil")
if let w = weekly {
    check(!w.needsWarning(now: w.expires.addingTimeInterval(-3 * 86_400)), "no warning 3 days before")
    check(w.needsWarning(now: w.expires.addingTimeInterval(-86_400)), "warning 1 day before")
    check(w.warning(now: w.expires.addingTimeInterval(-(28 * 3600 + 60)))?.title == "iDeck stops opening in 1 day, 4 hours",
          "warning title: \(w.warning(now: w.expires.addingTimeInterval(-(28 * 3600 + 60)))?.title ?? "nil")")
    check(w.warning(now: w.expires.addingTimeInterval(60))?.title == "iDeck's signature has expired", "expired title")
    check(w.logLine(now: w.expires.addingTimeInterval(-3 * 3600 - 60)).hasSuffix("(3 hours left), 7-day (free Apple ID)"),
          "log line: \(w.logLine(now: w.expires.addingTimeInterval(-3 * 3600 - 60)))")
}
check(SigningProfile.remaining(1800) == "less than an hour", "under an hour")
check(SigningProfile.remaining(-1) == nil, "expired -> nil")

// QMP query-blockstats (BlockStats.swift).
let blockReply: Any = [
    ["device": "system", "qdev": "/machine/peripheral-anon/device[1]/virtio-backend",
     "stats": ["flush_operations": 1200, "flush_total_time_ns": 45_500_000_000, "wr_operations": 9000,
               "wr_bytes": 314_572_800, "wr_total_time_ns": 12_000_000_000, "rd_operations": 4000,
               "rd_bytes": 104_857_600, "rd_total_time_ns": 3_000_000_000]],
    ["device": "", "qdev": "data-qdev", "stats": ["flush_operations": 3]],
    ["device": "broken"],
]
let disks = BlockStats.parse(blockReply)
check(disks.count == 2, "two disks with stats, got \(disks.count)")
check(disks.first?.name == "system" && disks.first?.flushes == 1200 && disks.first?.flushSeconds == 45.5,
      "system disk flushes: \(String(describing: disks.first))")
check(disks.last?.name == "data-qdev" && disks.last?.flushes == 3 && disks.last?.writeMB == 0, "qdev fallback name")
check(BlockStats.summary(disks).hasPrefix("system: flush 1200 ops 45.5 s, write 9000 ops 300 MB 12.0 s, read 4000 ops 100 MB 3.0 s"),
      "summary: \(BlockStats.summary(disks))")
check(BlockStats.parse("nonsense").isEmpty && BlockStats.summary([]) == "no disks reported", "bad reply")

// APP_SANDBOX_GROUP_ID for QEMU (ShmGroup.swift).
check(ShmGroup.forQEMU(usable: "group.ideck.ABCDE12345", fileFallback: false) == "group.ideck.ABCDE12345",
      "a working app group is passed on")
check(ShmGroup.forQEMU(usable: nil, fileFallback: true) == ShmGroup.fallback,
      "no working group + file fallback -> short fallback name")
check(ShmGroup.forQEMU(usable: "group.com.ideck.app.ABCDE12345", fileFallback: true) == ShmGroup.fallback,
      "a 30-character group is never passed (anon_file.c refuses it before shm_open)")
check(ShmGroup.forQEMU(usable: nil, fileFallback: false) == nil, "nothing usable -> unset")
check(ShmGroup.fallback.count <= ShmGroup.maxLength && ShmGroup.fallback.hasPrefix("group."), "fallback name fits")

// Engine options: tried, and switched off when QEMU ran with them and Linux did
// not come up; once until they have worked, twice in a row after (EngineGuard.swift).
let engineUse = EngineGuard.Decision(useEngine: true, switchSettingsOff: false)
let engineOff = EngineGuard.Decision(useEngine: false, switchSettingsOff: true)
check(EngineGuard.decide(anySettingOn: true, supported: true, unfinishedStarts: 0, proven: false) == engineUse,
      "engine options: used when on and supported")
check(EngineGuard.decide(anySettingOn: true, supported: true, unfinishedStarts: 1, proven: false) == engineOff,
      "engine options: one unfinished start switches them off while they have never worked")
check(EngineGuard.decide(anySettingOn: true, supported: true, unfinishedStarts: 1, proven: true) == engineUse,
      "engine options: one unfinished start is tolerated once they have worked")
check(EngineGuard.decide(anySettingOn: true, supported: true, unfinishedStarts: 2, proven: true) == engineOff,
      "engine options: two unfinished starts switch them off")
check(EngineGuard.decide(anySettingOn: true, supported: false, unfinishedStarts: 0, proven: false)
      == EngineGuard.Decision(useEngine: false, switchSettingsOff: false), "engine options: not in the interpreter edition")
check(EngineGuard.decide(anySettingOn: false, supported: true, unfinishedStarts: 5, proven: true)
      == EngineGuard.Decision(useEngine: false, switchSettingsOff: false), "engine options: off stays off")
let fpMarker = FileManager.default.temporaryDirectory.appendingPathComponent("ideck-native-fp-\(ProcessInfo.processInfo.processIdentifier)")
EngineGuard.clear(fpMarker)
check(EngineGuard.unfinishedStarts(fpMarker) == 0, "native FP marker: none -> 0")
EngineGuard.noteStart(fpMarker)
EngineGuard.noteStart(fpMarker)
check(EngineGuard.unfinishedStarts(fpMarker) == 2, "native FP marker: counts starts")
EngineGuard.clear(fpMarker)
check(EngineGuard.unfinishedStarts(fpMarker) == 0, "native FP marker: cleared when Linux comes up")

// A start is counted once, from whichever place sees QEMU running first; a
// start the debugger stops before that is never counted.
let engineNote = EngineStartNote(marker: fpMarker)
engineNote.fire()
check(EngineGuard.unfinishedStarts(fpMarker) == 0, "engine start: not counted when the start has no engine options")
engineNote.arm(true)
check(EngineGuard.unfinishedStarts(fpMarker) == 0, "engine start: not counted before QEMU runs")
engineNote.fire()
engineNote.fire()
check(EngineGuard.unfinishedStarts(fpMarker) == 1, "engine start: counted once")
engineNote.arm(true)
engineNote.arm(false)
engineNote.fire()
check(EngineGuard.unfinishedStarts(fpMarker) == 1, "engine start: not counted after Linux came up")
EngineGuard.clear(fpMarker)

let provenFile = FileManager.default.temporaryDirectory.appendingPathComponent("ideck-engine-proven-\(ProcessInfo.processInfo.processIdentifier)")
EngineGuard.clear(provenFile)
let stamp43 = EngineGuard.stamp(build: "43", runtime: "0.1.14", hostVfp: true, keepGlobal: true)
check(stamp43 == "43|0.1.14|11", "engine stamp: \(stamp43)")
check(!EngineGuard.isProven(provenFile, stamp: stamp43), "engine: not proven before Linux came up with it")
EngineGuard.noteProven(provenFile, stamp: stamp43)
check(EngineGuard.isProven(provenFile, stamp: stamp43), "engine: proven for this build, runtime and options")
check(!EngineGuard.isProven(provenFile, stamp: EngineGuard.stamp(build: "44", runtime: "0.1.14", hostVfp: true, keepGlobal: true)),
      "engine: a new build has to prove it again")
check(!EngineGuard.isProven(provenFile, stamp: EngineGuard.stamp(build: "43", runtime: "0.1.14", hostVfp: true, keepGlobal: false)),
      "engine: other options have to prove themselves")
EngineGuard.clear(provenFile)

// The agent's fpcheck.run reply, as JSONSerialization delivers it.
func fpReply(_ json: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
}
let fpGood = EngineGuard.checkSummary(fpReply(#"{"reference": true, "patterns": 189, "match": true, "flags_match": true, "reference_cpu": "Neoverse-N2"}"#), nativeFP: true)
check(fpGood.ok && fpGood.text == "native: all 189 instruction patterns match Neoverse-N2", "fpcheck summary: \(fpGood.text)")
let fpFlags = EngineGuard.checkSummary(fpReply(#"{"reference": true, "patterns": 189, "match": true, "flags_match": false, "reference_cpu": ""}"#), nativeFP: false)
check(fpFlags.ok && fpFlags.text == "emulated: all 189 instruction patterns match hardware; exception flags differ", "fpcheck summary: \(fpFlags.text)")
let fpBad = EngineGuard.checkSummary(fpReply(#"{"reference": true, "patterns": 189, "match": false, "flags_match": true, "values_differ": 2, "values_differ_names": ["FADD_s", "FCMP"], "mix_values_equal": false, "sigill": 0, "missing": 0, "reference_cpu": "Neoverse-N2"}"#), nativeFP: true)
check(!fpBad.ok && fpBad.text == "native: 2 of 189 instruction patterns differ from Neoverse-N2 (FADD_s, FCMP); mixed sequences differ", "fpcheck summary: \(fpBad.text)")
let fpNone = EngineGuard.checkSummary(fpReply(#"{"reference": false, "patterns": 0, "match": false}"#), nativeFP: true)
check(!fpNone.ok && fpNone.text.contains("no hardware reference"), "fpcheck summary without a reference")
check(EngineGuard.checkFoundDifference(fpReply(#"{"reference": true, "patterns": 189, "match": false, "values_differ": 2}"#)),
      "fpcheck: a difference from hardware is a finding")
check(!EngineGuard.checkFoundDifference(fpReply(#"{"reference": true, "patterns": 189, "match": true, "flags_match": false}"#)),
      "fpcheck: matching values are not a finding")
check(!EngineGuard.checkFoundDifference(fpReply(#"{"reference": false, "patterns": 0, "match": false}"#)),
      "fpcheck: no reference is not a finding")

// TCG cache size from where QEMU would map it (JITCachePlan.swift).
func placed(_ mb: UInt64, _ view: UInt64) -> JITCachePlan.Placement {
    JITCachePlan.Placement(mb: mb, buffer: 0x1_2000_0000, view: view)
}
let gib64: UInt64 = 1 << 36
check(placed(384, 0x1_3a7c_0000).addressable, "jit placement: the cache of build 41 (0x13a7c0000) is addressable")
check(placed(1024, gib64 - (1024 << 20)).addressable, "jit placement: ending exactly at 64 GiB is addressable")
check(!placed(1024, gib64 - (1024 << 20) + 16384).addressable, "jit placement: one page past 64 GiB is not")
check(!placed(512, 0).addressable, "jit placement: an address of zero is no placement")
check(placed(768, 0x10_4000_0000).text == "768 MiB at 0x1040000000 (reaches 64 GiB or above)", "jit placement text")

let highOnly1024 = [placed(1024, 0x10_4000_0000), placed(768, 0x1_2a00_0000), placed(512, 0x1_2a00_0000)]
check(JITCachePlan.choose(placements: highOnly1024, failedMb: nil).mb == 768,
      "jit cache: 1 GiB above 64 GiB, 768 MiB below -> 768")
let high768 = [placed(1024, 0x10_4000_0000), placed(768, 0x10_4000_0000), placed(512, 0x1_4a00_0000)]
check(JITCachePlan.choose(placements: high768, failedMb: nil).mb == 512,
      "jit cache: only 512 MiB stays below 64 GiB -> 512")
let allHigh = [placed(1024, 0x10_4000_0000), placed(768, 0x10_4000_0000), placed(512, 0x10_4000_0000)]
check(JITCachePlan.choose(placements: allHigh, failedMb: nil).mb == 384, "jit cache: nothing larger stays below 64 GiB -> 384")
let allLow = [placed(1024, 0x2_8000_0000), placed(768, 0x1_2a00_0000), placed(512, 0x1_2a00_0000)]
let unexplained = JITCachePlan.choose(placements: allLow, failedMb: nil)
check(unexplained.mb == 384 && unexplained.reason.contains("does not explain"),
      "jit cache: 1 GiB below 64 GiB did not run for another reason -> 384")
check(JITCachePlan.choose(placements: highOnly1024, failedMb: 768).mb == 384, "jit cache: a size that did not run -> 384")
check(JITCachePlan.choose(placements: [], failedMb: nil).mb == 384, "jit cache: no measurement -> 384")
check(JITCachePlan.choose(placements: [placed(768, 0x1_2a00_0000)], failedMb: nil).mb == 384,
      "jit cache: 1 GiB not measured -> 384")

check(JITCachePlan.failureRecord(mb: 768, build: "43") == "768|43", "jit failure record")
check(JITCachePlan.failedMb(record: "768|43\n", build: "43") == 768, "jit failure: this build")
check(JITCachePlan.failedMb(record: "768|43", build: "44") == nil, "jit failure: another build may try again")
check(JITCachePlan.failedMb(record: "384|43", build: "43") == nil, "jit failure: the proven size is never a failure")
check(JITCachePlan.failedMb(record: "nonsense", build: "43") == nil && JITCachePlan.failedMb(record: nil, build: "43") == nil,
      "jit failure: no record")

let preparedMarks = JITCachePlan.PageMarks(pages: 24576, marked: 24570, zero: 2, firstZeroMb: 0)
check(!preparedMarks.unprepared, "jit marks: a few zero pages are QEMU's own code")
check(preparedMarks.text == "24570 of 24576 pages carry the debugger's mark, 2 read zero (first at 0 MiB)", "jit marks text")
check(JITCachePlan.PageMarks(pages: 65536, marked: 0, zero: 65530, firstZeroMb: 0).unprepared, "jit marks: nothing written")
check(JITCachePlan.PageMarks(pages: 65536, marked: 32768, zero: 32768, firstZeroMb: 512).unprepared, "jit marks: half written")
check(!JITCachePlan.PageMarks(pages: 0, marked: 0, zero: 0, firstZeroMb: -1).unprepared, "jit marks: no region")

// crash.log entry from the device (build 41, GPU-drawn Steam UI).
let gpuCrash = """

=== iDeck crash: SIGSEGV (11) at 0x0000000000000688 code 2 thread 'vkr-ring-6' time 1795516854
0   iDeck                               0x0000000100de42ac iDeck + 17068
2   MoltenVK                            0x000000015cf4ce80 _ZN16MVKCommandBuffer18recordBindPipelineEP18MVKCmdBindPipeline + 36
=== end
"""
check(SessionLogParsing.crashThread(in: gpuCrash, since: 1795516000) == "vkr-ring-6", "crash thread of a session's entry")
check(SessionLogParsing.crashThread(in: gpuCrash, since: 1795517000) == nil, "crash thread: older entries are not this session's")
check(SessionLogParsing.crashSignal(in: gpuCrash, since: 1795516000) == "SIGSEGV", "crash signal of the same entry")

// Pointer mode and movement.
check(PointerMode.automatic.usesTrackpad(gameRunning: true) && !PointerMode.automatic.usesTrackpad(gameRunning: false),
      "pointer: automatic is trackpad only while a game runs")
check(!PointerMode.touch.usesTrackpad(gameRunning: true) && PointerMode.trackpad.usesTrackpad(gameRunning: false),
      "pointer: a chosen mode wins over the game")
var motion = RelativeMotion()
var movedX = 0, movedY = 0
for _ in 0..<8 {
    let step = motion.add(dx: 0.25, dy: -0.25)
    movedX += step.x
    movedY += step.y
}
check(movedX == 2 && movedY == -2, "pointer: slow movement adds up (\(movedX), \(movedY))")
let big = motion.add(dx: 5.75, dy: 0)
let rest = motion.add(dx: 0.25, dy: 0)
check(big.x == 5 && rest.x == 1, "pointer: the fraction is carried over")
motion.reset()
check(motion.add(dx: 0.5, dy: 0.5) == (0, 0), "pointer: reset drops the carried fraction")

// HMP output as QEMU 10 prints it (accel/tcg/monitor.c, target/arm/cpu.c).
let jitText = """
Translation buffer state:
gen code size       27486532/1073736704
TB count            61290
TB avg target size  17 max=1024 bytes
TB avg host size    448 bytes (expansion ratio: 25.7)

Statistics:
TB flush count      0
TB invalidate count 1923
TLB full flushes    12
TLB partial flushes 3301
"""
check(BootProbeParsing.jitSummary(jitText)
      == "gen code size 27486532/1073736704, TB count 61290, TB flush count 0, TB invalidate count 1923, TLB full flushes 12",
      "info jit summary: \(BootProbeParsing.jitSummary(jitText))")
check(BootProbeParsing.jitSummary("x-query-jit: not supported").hasPrefix("no counters"), "info jit summary without counters")
check(BootProbeParsing.tbCount(jitText) == 61290, "info jit TB count")
check(BootProbeParsing.tbCount("TB count            1\n") == 1, "info jit TB count of a stuck start")
check(BootProbeParsing.tbCount("x-query-jit: not supported") == nil, "info jit TB count missing")
let regsText = """

CPU#0
 PC=ffff800080e1c2a4 X00=0000000000000000 X01=0000000000000001 X02=0000000000000000
X03=0000000000000000 X04=0000000000000000 X05=0000000000000000
 SP=ffff800082e03e80
PSTATE=600003c5 -ZC- EL1h     FPCR=00000000 FPSR=00000000

CPU#1
 PC=0000000040000000 X00=0000000000000000 X01=0000000000000000 X02=0000000000000000
 SP=0000000000000000
PSTATE=400003c5 -Z-- NS EL1h     FPCR=00000000 FPSR=00000000
"""
check(BootProbeParsing.vcpuSummary(regsText) == "0 PC=ffff800080e1c2a4 EL1h, 1 PC=0000000040000000 EL1h",
      "vCPU summary: \(BootProbeParsing.vcpuSummary(regsText))")
check(BootProbeParsing.vcpuSummary("").hasPrefix("no registers"), "vCPU summary without registers")

print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
