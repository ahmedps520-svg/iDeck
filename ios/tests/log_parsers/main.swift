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

print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
