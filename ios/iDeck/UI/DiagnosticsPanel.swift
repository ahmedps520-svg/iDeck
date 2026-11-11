import SwiftUI

/// Live boot diagnostics: JIT/memory state, guest serial console and QEMU
/// log tails, and one-tap log sharing. Shown during setup and on Runtime.
struct DiagnosticsPanel: View {
    @EnvironmentObject var runtime: RuntimeController
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Diagnostics", systemImage: "stethoscope").font(.headline).foregroundStyle(.white)
                    Spacer()
                    ShareLink(items: [Paths.appLog, Paths.qemuLog, Paths.consoleLog].filter {
                        FileManager.default.fileExists(atPath: $0.path)
                    }) {
                        Label("Share logs", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    row("Linux", runtime.phase.traceLabel + elapsed)
                    row("JIT", IDPlatform.isDebuggerAttached
                        ? "enabled (debugger \(IDPlatform.isTraced ? "attached" : "detached"))"
                        : "NOT enabled (open StikDebug › Enable JIT › iDeck)")
                    row("Memory", "\(IDPlatform.availableMemory >> 20) MiB available · footprint \(IDPlatform.physFootprint >> 20) MiB"
                        + (runtime.plan.map { " · guest \($0.guestMb) MiB" } ?? ""))
                    row("Signing", "\(IDPlatform.signingKind) · app group \(IDPlatform.applicationGroupIdentifier ?? "none")")
                }
                .font(.caption.monospaced())
                logBox("Linux console", runtime.consoleTail, empty: "No output yet. The kernel has not printed anything.")
                logBox("QEMU", runtime.qemuLogTail, empty: "No QEMU messages.")
                Text("Logs are also in the Files app: On My iPad › iDeck › Logs.")
                    .font(.caption2).foregroundStyle(Theme.textTertiary)
            }
        }
        .onReceive(tick) { now = $0 }
        .onAppear { runtime.refreshTails() }
    }

    private var elapsed: String {
        guard let s = runtime.bootStartedAt else { return "" }
        let t = Int(now.timeIntervalSince(s))
        return " · \(t / 60):\(String(format: "%02d", t % 60)) since start"
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(Theme.textTertiary)
            Text(v).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
        }
    }

    private func logBox(_ title: String, _ lines: [String], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(Theme.textTertiary)
            Text(lines.isEmpty ? empty : lines.joined(separator: "\n"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(lines.isEmpty ? Theme.textTertiary : Theme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
