import SwiftUI
import UIKit

struct PerformanceView: View {
    @EnvironmentObject var runtime: RuntimeController
    @EnvironmentObject var model: AppModel
    @State private var cpuHistory: [Double] = []
    @State private var memHistory: [Double] = []
    @State private var footprintHistory: [Double] = []
    @State private var battery: [(Date, Float)] = []
    @State private var bench: [String: Any]?
    @State private var benching = false
    @State private var benchError: String?
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                    chartTile("Guest CPU", Format.percent(runtime.metrics.cpuPercent), cpuHistory, 100)
                    chartTile("Guest memory", Format.bytes(runtime.metrics.memUsedKB * 1024), memHistory,
                              Double(max(1, runtime.metrics.memTotalKB)) / 1024)
                    chartTile("iDeck footprint", Format.bytes(runtime.memory.sample.footprint), footprintHistory,
                              Double(max(1, runtime.memory.sample.footprint + runtime.memory.sample.available) >> 20))
                    StatTile(label: "Memory headroom", value: Format.bytes(runtime.memory.sample.available),
                             tint: runtime.memory.sample.level == "normal" ? Theme.success : Theme.warning,
                             detail: "Pressure: \(runtime.memory.sample.level)" + (runtime.memory.lastAction.map { " · \($0)" } ?? ""))
                    StatTile(label: "Thermal", value: thermal.0, tint: thermal.1,
                             detail: "\(Device.os) thermal state (exact temperatures are not exposed to apps)")
                    StatTile(label: "Battery", value: batteryText, detail: drainText)
                }
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Frame rate").font(.headline).foregroundStyle(.white)
                        Text("Game FPS and frame time are measured inside Linux by MangoHud and drawn over the game. GPU utilisation is not exposed by \(Device.os), so iDeck does not show an estimate.")
                            .font(.callout).foregroundStyle(Theme.textSecondary)
                        Toggle("Show FPS overlay in games (MangoHud)", isOn: $model.settings.showPerformanceOverlay)
                            .onChange(of: model.settings.showPerformanceOverlay) { _ in
                                Task { await runtime.applySteamSettings() }
                            }
                        Text("Takes effect for games started after Steam restarts.").font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("CPU benchmark").font(.headline).foregroundStyle(.white)
                            Spacer()
                            Button(benching ? "Running…" : "Run (≈2 min)") {
                                benching = true
                                benchError = nil
                                Task {
                                    do { bench = try await runtime.runBenchmark(quick: false) }
                                    catch { benchError = error.localizedDescription }
                                    benching = false
                                }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(!runtime.isRunning || benching)
                        }
                        Text("Measures the emulated CPU inside Linux: integer, floating point, multithread, memory bandwidth and latency, syscalls, instruction throughput and JIT translation cost.")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                        if let benchError { Text(benchError).font(.caption).foregroundStyle(Theme.danger) }
                        if let results = bench?["results"] as? [[String: Any]] {
                            ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                                HStack {
                                    Text(r["name"] as? String ?? "").font(.caption.monospaced()).frame(width: 130, alignment: .leading)
                                    Text(String(format: "%.2f", (r["value"] as? Double) ?? 0)).font(.caption.monospacedDigit().weight(.semibold))
                                        .frame(width: 100, alignment: .trailing)
                                    Text(r["unit"] as? String ?? "").font(.caption).foregroundStyle(Theme.textSecondary).frame(width: 70, alignment: .leading)
                                    Text(r["note"] as? String ?? "").font(.caption2).foregroundStyle(Theme.textTertiary).lineLimit(1)
                                }
                            }
                            ShareLink(item: (try? String(data: JSONSerialization.data(withJSONObject: bench ?? [:], options: .prettyPrinted), encoding: .utf8)) ?? "{}") {
                                Label("Share results", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .navigationTitle("Performance")
        .onAppear { UIDevice.current.isBatteryMonitoringEnabled = true }
        .onReceive(timer) { _ in sample() }
    }

    private func chartTile(_ label: String, _ value: String, _ data: [Double], _ maxV: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased()).font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(Theme.textTertiary)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit()).foregroundStyle(Theme.accent)
            Sparkline(values: data, maxValue: maxV).frame(height: 40)
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func sample() {
        cpuHistory.append(runtime.metrics.cpuPercent)
        memHistory.append(Double(runtime.metrics.memUsedKB) / 1024)
        footprintHistory.append(Double(runtime.memory.sample.footprint >> 20))
        if cpuHistory.count > 120 { cpuHistory.removeFirst(cpuHistory.count - 120) }
        if memHistory.count > 120 { memHistory.removeFirst(memHistory.count - 120) }
        if footprintHistory.count > 120 { footprintHistory.removeFirst(footprintHistory.count - 120) }
        let level = UIDevice.current.batteryLevel
        if level >= 0 { battery.append((Date(), level)) }
        if battery.count > 400 { battery.removeFirst() }
    }

    private var thermal: (String, Color) {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return ("Nominal", Theme.success)
        case .fair: return ("Fair", Theme.accent)
        case .serious: return ("Serious", Theme.warning)
        case .critical: return ("Critical", Theme.danger)
        @unknown default: return ("Unknown", Theme.textSecondary)
        }
    }

    private var batteryText: String {
        let l = UIDevice.current.batteryLevel
        return l < 0 ? "—" : Format.percent(Double(l) * 100)
    }

    private var drainText: String {
        guard let first = battery.first, let last = battery.last, last.0.timeIntervalSince(first.0) > 300 else {
            return "Drain rate after 5 minutes of sampling"
        }
        let perHour = Double(first.1 - last.1) * 100 / (last.0.timeIntervalSince(first.0) / 3600)
        return perHour > 0 ? String(format: "%.0f%% per hour", perHour) : "Charging or stable"
    }
}
