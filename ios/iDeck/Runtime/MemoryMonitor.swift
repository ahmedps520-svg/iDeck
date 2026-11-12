import Foundation
import UIKit

/// Watches the app's jetsam headroom and applies the core's pressure policy:
/// inflate the virtio balloon, drop guest caches, flush disks, release UI
/// caches. Samples feed the Performance screen.
final class MemoryMonitor: ObservableObject {
    struct Sample {
        var footprint: UInt64
        var available: UInt64
        var level: String
    }

    @Published private(set) var sample = Sample(footprint: 0, available: 0, level: "normal")
    @Published private(set) var lastAction: String?

    private var source: DispatchSourceMemoryPressure?
    private var timer: Timer?
    private var lastLevel = "normal"
    var guestMb: UInt64 = 0
    var guestUsedMb: UInt64 = 0
    var apply: ((PressureActions) async -> Void)?

    func start() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, let s = self.source else { return }
            let ev = s.data
            let level = ev.contains(.critical) ? "critical" : ev.contains(.warning) ? "warning" : "normal"
            // System-wide pressure (not only this app's limit): logged so a
            // session that iOS ends can be matched to it.
            DiagLog.write("memory pressure from iOS: \(level) (footprint \(IDPlatform.physFootprint >> 20) MiB, "
                          + "available \(IDPlatform.availableMemory >> 20) MiB)")
            self.react(level)
        }
        src.resume()
        source = src
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.react("warning")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func poll() {
        let avail = IDPlatform.availableMemory
        let fp = IDPlatform.physFootprint
        sample = Sample(footprint: fp, available: avail, level: lastLevel)
        // os_proc_available_memory gives early warning before the system
        // notification: under 384 MiB of headroom act as "warning", under
        // 160 MiB as "critical".
        if avail > 0 {
            if avail < 160 << 20 { react("critical") }
            else if avail < 384 << 20 { react("warning") }
            else if lastLevel != "normal" && avail > 1024 << 20 { react("normal") }
        }
    }

    private func react(_ level: String) {
        guard level != lastLevel, guestMb > 0 else { return }
        lastLevel = level
        sample.level = level
        let request = PressureRequest(level: level, guestMb: guestMb, usedGuestMb: guestUsedMb)
        guard let actions = try? Core.call("memory.pressure", request, as: PressureActions.self) else { return }
        lastAction = "\(level): balloon \(actions.balloonTargetMb) MiB" + (actions.dropGuestCaches ? ", dropped caches" : "")
        DiagLog.write("memory: \(level) -> \(lastAction ?? "")")
        Task { await apply?(actions) }
    }
}

private struct PressureRequest: Encodable {
    var level: String
    var guestMb: UInt64
    var usedGuestMb: UInt64
}
