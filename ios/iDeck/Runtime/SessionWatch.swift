import Foundation
import UIKit

/// Records in the app's own files that Linux is running, so the next launch
/// can tell that iDeck ended in the middle of a session and say how.
///
/// iOS ends apps with SIGKILL (memory limits, watchdog, the app switcher,
/// another app relaunching iDeck under a debugger). No signal handler sees
/// that, so before this ideck.previous.log simply stopped, with nothing in
/// crash.log (device run, build 23: two sessions ended that way while Steam
/// installed a client update).
enum SessionMarker {
    private static var url: URL { Paths.support.appendingPathComponent("linux-session.json") }

    /// How far a start got. QEMU reads its settings, builds the machine and
    /// answers the app only after the debugger has prepared JIT memory.
    enum Stage: String {
        /// QEMU's thread was started; nothing has been heard since.
        case started
        /// iDeck was still running 12 s later, but QEMU had not answered.
        case silent
        /// QEMU answered: its main loop runs.
        case qemu
        /// The guest agent in Linux reported ready.
        case linux
    }

    static func begin(runtime: String) {
        let info: [String: Any] = ["started": Date().timeIntervalSince1970, "pid": Int(getpid()), "runtime": runtime,
                                   "stage": Stage.started.rawValue]
        if let data = try? JSONSerialization.data(withJSONObject: info) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Records the stage this process's start has reached (any thread).
    static func update(stage: Stage) {
        guard let data = try? Data(contentsOf: url),
              var info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (info["pid"] as? NSNumber)?.intValue == Int(getpid()) else { return }
        info["stage"] = stage.rawValue
        if let out = try? JSONSerialization.data(withJSONObject: info) {
            try? out.write(to: url, options: .atomic)
        }
    }

    static func end() {
        try? FileManager.default.removeItem(at: url)
    }

    struct Previous {
        var started: Date
        var pid: Int
        var runtime: String
        /// Signal name when crash.log has an entry from that session.
        var signal: String?
        /// Name of the thread that crashed, from the same entry.
        var crashThread: String?
        /// Last app state the previous trace recorded ("foreground", "background", ...).
        var lastAppState: String?
        /// Timestamp of the last line in ideck.previous.log.
        var lastLogLine: String?
        /// iOS reported memory pressure or a memory warning during it.
        var memoryPressure = false
        /// How far the start got (nil: recorded by a build before 43).
        var stage: Stage?

        /// The process ended without a crash while QEMU had been started and
        /// was never heard from, not even by the check 12 s later. A running
        /// process logs that check, so iDeck was held stopped: by the
        /// debugger, in the step that prepares JIT memory. (Closing iDeck
        /// within a second or two of starting Linux looks the same.)
        var stoppedBeforeQEMUAnswered: Bool { stage == .started && signal == nil }

        var logLine: String {
            let age = lastLogLine.map { ", last log line \($0)" } ?? ""
            let state = (lastAppState.map { ", app was \($0)" } ?? ", no app state recorded")
                + (memoryPressure ? ", iOS reported memory pressure" : "")
            let how = signal.map { "crashed with \($0) (see crash.log)" }
                ?? "ended without a crash signal (SIGKILL from iOS or a debugger, or closed in the app switcher)"
            let reached: String
            switch stage {
            case .started: reached = "; QEMU never answered and iDeck logged nothing after starting it (stopped in JIT preparation)"
            case .silent: reached = "; QEMU never answered, iDeck kept running"
            case .qemu: reached = "; QEMU answered, Linux did not reach the guest agent"
            case .linux: reached = "; Linux was up"
            case nil: reached = ""
            }
            return "previous session: Linux \(runtime) was running in pid \(pid) since "
                + "\(ISO8601DateFormatter().string(from: started))\(state)\(age); iDeck \(how)\(reached)"
        }

        /// Plain-language notice for the home screen.
        var userMessage: String {
            if stoppedBeforeQEMUAnswered {
                return "The last start stopped before Linux began. Most likely StikDebug held iDeck while it prepared JIT memory "
                    + "and did not let it continue, which leaves the screen on Connecting to Linux. "
                    + "No iDeck setting is involved at that point. Start Linux again; "
                    + "if it happens twice in a row, close StikDebug in the app switcher as well before the next try."
            }
            if signal == nil, stage == .silent || stage == .qemu {
                return "The last start did not get as far as Linux: QEMU was started, but Linux had not come up when iDeck closed. "
                    + "If that was not you closing it, share the logs from Diagnostics."
            }
            if let signal {
                return "iDeck crashed while Linux was running (\(signal)). Share the logs from Diagnostics so it can be fixed."
            }
            if lastAppState == "background" {
                return "\(Device.os) closed iDeck while it was in the background with Linux running. "
                    + "Apps in the background are suspended and can be closed to free memory, so keep iDeck open while Steam installs or updates. "
                    + "Steam may repeat an update it was installing."
            }
            return "iDeck closed while Linux was running, and no crash was recorded. "
                + "That happens when \(Device.os) ends the app (for example to free memory), when iDeck is swiped away in the app switcher, "
                + "or when StikDebug opens iDeck again while it runs. If you did not close it, share the logs from Diagnostics "
                + "and any iDeck or JetsamEvent file from Settings › Privacy & Security › Analytics & Improvements › Analytics Data."
        }
    }

    /// The previous session, if Linux was still running when that iDeck
    /// process ended (nil after a clean stop). Clears the record.
    static func takePrevious() -> Previous? {
        defer { end() }
        guard let data = try? Data(contentsOf: url),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let started = info["started"] as? Double else { return nil }
        let pid = (info["pid"] as? NSNumber)?.intValue ?? 0
        guard pid != Int(getpid()) else { return nil }
        var p = Previous(started: Date(timeIntervalSince1970: started), pid: pid,
                         runtime: info["runtime"] as? String ?? "?")
        p.stage = (info["stage"] as? String).flatMap(Stage.init(rawValue:))
        if let crashes = try? String(contentsOf: Paths.crashLog, encoding: .utf8) {
            p.signal = SessionLogParsing.crashSignal(in: crashes, since: started)
            p.crashThread = SessionLogParsing.crashThread(in: crashes, since: started)
        }
        let trace = DiagLog.tail(Paths.previousAppLog, lines: 400, maxBytes: 262_144)
        p.lastLogLine = trace.last.flatMap { $0.split(separator: " ").first.map(String.init) }
        p.lastAppState = SessionLogParsing.lastAppPlacement(in: trace)
        p.memoryPressure = SessionLogParsing.sawMemoryPressure(in: trace)
        return p
    }
}
