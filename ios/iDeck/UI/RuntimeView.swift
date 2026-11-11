import SwiftUI

struct RuntimeView: View {
    @EnvironmentObject var runtime: RuntimeController
    @EnvironmentObject var installer: Installer
    @EnvironmentObject var model: AppModel
    @State private var selfTest: [String: Any]?
    @State private var testing = false
    @State private var log = ""
    @State private var showLog = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    StatTile(label: "Linux", value: runtime.phase.label, tint: runtime.phase.color)
                    StatTile(label: "Runtime", value: RuntimeFiles.current()?.version ?? "—",
                             detail: (runtime.guestInfo["kernel"] as? String).map { "Kernel \($0)" })
                    StatTile(label: "Steam", value: runtime.metrics.steamRunning ? "Running" : "Not running",
                             tint: runtime.metrics.steamRunning ? Theme.success : Theme.textSecondary)
                }
                HStack(spacing: 16) {
                    StatTile(label: "Guest memory", value: runtime.plan.map { "\($0.guestMb / 1024) GB" } ?? "—",
                             detail: runtime.metrics.memTotalKB > 0 ? "\(Format.bytes(runtime.metrics.memUsedKB * 1024)) in use" : nil)
                    StatTile(label: "Guest CPU", value: Format.percent(runtime.metrics.cpuPercent),
                             detail: "\(runtime.metrics.perCore.count) vCPUs · TCG \(RuntimeController.edition == "jit" ? "JIT" : "interpreter")")
                    StatTile(label: "JIT", value: IDPlatform.isDebuggerAttached ? "Enabled" : "Off",
                             tint: IDPlatform.isDebuggerAttached ? Theme.success : Theme.warning,
                             detail: IDPlatform.signingKind)
                }
                if let plan = runtime.plan {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Memory plan").font(.headline).foregroundStyle(.white)
                            Text("Limit \(plan.limitMb) MiB · guest \(plan.guestMb) · translation cache \(plan.tbCacheMb) · GPU budget \(plan.gpuBudgetMb) · overhead \(plan.overheadMb)")
                                .font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                            ForEach(plan.notes + runtime.warnings, id: \.self) { n in
                                Text("• \(n)").font(.caption).foregroundStyle(Theme.warning)
                            }
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Actions").font(.headline).foregroundStyle(.white)
                        HStack(spacing: 12) {
                            if runtime.isRunning {
                                Button("Shut Down Linux") { Task { await runtime.shutdown() } }.buttonStyle(SecondaryButtonStyle())
                                Button("Restart Steam") { Task { await runtime.restartSteam() } }.buttonStyle(SecondaryButtonStyle())
                                Button(testing ? "Testing…" : "Run Self-Test") {
                                    testing = true
                                    Task {
                                        selfTest = await runtime.runSelfTest()
                                        testing = false
                                    }
                                }.buttonStyle(SecondaryButtonStyle()).disabled(testing)
                            } else {
                                Button("Start Linux") { model.startGaming() }.buttonStyle(PrimaryButtonStyle())
                            }
                        }
                        HStack(spacing: 12) {
                            Button("QEMU Log") { showFile(Paths.qemuLog) }.buttonStyle(SecondaryButtonStyle())
                            Button("Console Log") { showFile(Paths.consoleLog) }.buttonStyle(SecondaryButtonStyle())
                            Button("Roll Back Runtime") {
                                do { try installer.rollbackRuntime(); message = "Rolled back. Restart iDeck to boot it." }
                                catch { message = error.localizedDescription }
                            }.buttonStyle(SecondaryButtonStyle()).disabled(runtime.isRunning)
                            Button("Repair Setup") { Task { await installer.retry(from: "install-steam") } }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                        if let message { Text(message).font(.caption).foregroundStyle(Theme.textSecondary) }
                    }
                }
                if let t = selfTest { SelfTestCard(report: t) }
                DiagnosticsPanel()
            }
            .padding(28)
        }
        .navigationTitle("Runtime")
        .sheet(isPresented: $showLog) {
            NavigationStack {
                ScrollView { Text(log).font(.caption.monospaced()).textSelection(.enabled).padding() }
                    .navigationTitle("Log")
                    .toolbar { ShareLink(item: log) }
            }
        }
    }

    private func showFile(_ url: URL) {
        log = (try? String(contentsOf: url, encoding: .utf8)) ?? "No log yet."
        if log.count > 200_000 { log = String(log.suffix(200_000)) }
        showLog = true
    }
}

struct SelfTestCard: View {
    var report: [String: Any]
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label((report["ok"] as? Bool) == true ? "All required checks passed" : "Some checks failed",
                      systemImage: (report["ok"] as? Bool) == true ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .font(.headline).foregroundStyle((report["ok"] as? Bool) == true ? Theme.success : Theme.danger)
                ForEach(Array((report["checks"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .top) {
                        Image(systemName: (c["ok"] as? Bool) == true ? "checkmark" : "xmark")
                            .foregroundStyle((c["ok"] as? Bool) == true ? Theme.success : ((c["required"] as? Bool) == true ? Theme.danger : Theme.warning))
                        Text(c["id"] as? String ?? "").font(.caption.weight(.semibold)).frame(width: 130, alignment: .leading)
                        Text(c["detail"] as? String ?? "").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                if let e = report["error"] as? String { Text(e).font(.caption).foregroundStyle(Theme.danger) }
            }
        }
    }
}
