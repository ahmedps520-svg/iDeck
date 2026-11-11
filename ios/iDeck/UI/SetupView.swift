import SwiftUI

/// First run: one button, then the installer works through every step.
struct SetupView: View {
    @EnvironmentObject var installer: Installer
    @EnvironmentObject var runtime: RuntimeController
    @EnvironmentObject var model: AppModel
    @State private var started = false
    @State private var showDiagnostics = false

    /// Diagnostics open by themselves once Linux is starting or anything failed.
    private var diagnosticsVisible: Bool {
        if showDiagnostics || installer.failure != nil { return true }
        switch runtime.phase {
        case .starting, .booting, .failed: return true
        default: return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("iDeck").font(.system(size: 52, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.accentGradient)
                    Text("Steam on your iPad, running locally.")
                        .font(.system(.title2, design: .rounded).weight(.semibold)).foregroundStyle(.white)
                    Text("Setup downloads a small Linux system, verifies it, installs Steam and checks graphics, audio and controllers. You only need to sign in to Steam.")
                        .foregroundStyle(Theme.textSecondary).frame(maxWidth: 640, alignment: .leading)
                }
                if let summary = installer.manifestSummary {
                    Text(summary).font(.footnote.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                }
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(installer.steps) { s in StepRow(step: s) }
                    }
                }
                if installer.needsJIT {
                    JITHelpView(onClose: {}).frame(maxWidth: .infinity)
                }
                if let p = installer.pausedMessage, installer.failure == nil {
                    Card {
                        Label(p, systemImage: "pause.circle.fill").foregroundStyle(Theme.warning)
                    }
                }
                if let f = installer.failure {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Setup stopped", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                            Text(f).font(.callout).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                HStack(spacing: 12) {
                    Button(installer.running ? "Installing…" : (started ? "Continue Setup" : "Install iDeck")) {
                        started = true
                        Task { await installer.run() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(installer.running)
                    if installer.downloading {
                        Button("Pause Download") { installer.pauseDownloads() }.buttonStyle(SecondaryButtonStyle())
                    }
                    if case .running = runtime.phase {
                        Button("Show Linux") { model.showGame = true }.buttonStyle(SecondaryButtonStyle())
                    }
                    Button(diagnosticsVisible ? "Hide Diagnostics" : "Diagnostics") { showDiagnostics.toggle() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if diagnosticsVisible {
                    DiagnosticsPanel()
                }
            }
            .padding(36)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
        // StikDebug returned with JIT ready: continue setup automatically.
        .onChange(of: runtime.jitReadyEvent) { _ in
            if !installer.isComplete && !installer.running { Task { await installer.run() } }
        }
    }
}

private struct StepRow: View {
    var step: Installer.StepView
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            icon.frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title).font(.body.weight(.medium)).foregroundStyle(step.state == "pending" ? Theme.textTertiary : .white)
                if !step.detail.isEmpty {
                    Text(step.detail).font(.caption).foregroundStyle(step.state == "failed" ? Theme.danger : Theme.textSecondary)
                        .lineLimit(3)
                }
                if step.state == "running" && step.progress > 0 && step.progress < 1 {
                    ProgressView(value: step.progress).tint(Theme.accent)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder private var icon: some View {
        switch step.state {
        case "done": Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case "skipped": Image(systemName: "minus.circle.fill").foregroundStyle(Theme.textTertiary)
        case "running": ProgressView().controlSize(.small)
        case "failed": Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.danger)
        default: Image(systemName: "circle").foregroundStyle(Theme.textTertiary)
        }
    }
}
