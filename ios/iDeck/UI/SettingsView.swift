import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var runtime: RuntimeController
    @AppStorage("ideck.manifestURL") private var manifestURL = ""
    @State private var showAdvanced = false

    var body: some View {
        Form {
            Section("Display") {
                Picker("Resolution", selection: $model.settings.resolution) {
                    ForEach(Settings.Resolution.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Refresh rate", selection: $model.settings.refreshHz) {
                    Text("30 Hz").tag(30)
                    Text("60 Hz").tag(60)
                }
                Text("720p is the target for emulated games; higher resolutions cost GPU time and memory.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
            Section("Performance") {
                Picker("Profile", selection: $model.settings.profile) {
                    ForEach(Settings.PerformanceProfile.allCases) { Text("\($0.title) (\($0.cpus) vCPUs)").tag($0) }
                }
                Picker("Linux memory", selection: $model.settings.guestMemoryMb) {
                    Text("Automatic").tag(UInt64(0))
                    ForEach([UInt64(2048), 3072, 4096, 5120, 6144], id: \.self) { mb in
                        Text("\(mb / 1024) GB" + ((runtime.plan?.allowedTiers.contains(mb) ?? true) ? "" : " (over limit)")).tag(mb)
                    }
                }
                Toggle("Vulkan (Venus)", isOn: $model.settings.vulkan)
                    .disabled(model.settings.safeGraphics)
                Toggle("Safe graphics (no GPU acceleration)", isOn: $model.settings.safeGraphics)
                Text("Troubleshooting: boots Linux with software rendering. Very slow, but tells whether a crash comes from the GPU path.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
            Section("Steam") {
                Toggle("Start in Big Picture mode", isOn: $model.settings.steamBigPicture)
                    .onChange(of: model.settings.steamBigPicture) { _ in applySteam() }
                Toggle("Steam beta client", isOn: $model.settings.steamBeta)
                    .onChange(of: model.settings.steamBeta) { _ in applySteam() }
                Toggle("Software-rendered Steam UI (compatibility)", isOn: $model.settings.steamSoftwareUI)
                    .onChange(of: model.settings.steamSoftwareUI) { _ in applySteam() }
                Toggle("Lightweight Steam (no Friends & Chat, no web sandbox)", isOn: $model.settings.steamLightweight)
                    .onChange(of: model.settings.steamLightweight) { _ in applySteam() }
                Toggle("Compact library (Steam Small Mode)", isOn: $model.settings.steamSmallMode)
                    .onChange(of: model.settings.steamSmallMode) { _ in applySteam() }
                DisclosureGroup("Make Steam lighter (settings inside Steam)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("These are Steam's own settings; set them once in Steam and they are kept:")
                        Text("• Settings › Downloads › Shader Pre-Caching: off (it compiles shaders in the background, which is slow under emulation)")
                        Text("• Settings › Library › Low Performance Mode and Low Bandwidth Mode: on")
                        Text("• Settings › In Game › Steam Overlay: off")
                        Text("• Settings › Interface › smooth scrolling and hardware video decoding: off")
                    }
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Toggle("FPS overlay in games (MangoHud)", isOn: $model.settings.showPerformanceOverlay)
            }
            Section("Audio & feedback") {
                Toggle("Game audio", isOn: $model.settings.audio)
                Toggle("Controller vibration", isOn: $model.settings.hapticsEnabled)
                Toggle("Notifications", isOn: $model.settings.notifications)
            }
            Section("Runtime") {
                LabeledContent("Runtime version", value: RuntimeFiles.current()?.version ?? "not installed")
                LabeledContent("Core", value: Core.version)
                LabeledContent("Edition", value: RuntimeController.edition == "jit" ? "Sideload (JIT)" : "TestFlight (interpreter)")
                LabeledContent("Signing", value: IDPlatform.signingKind)
                LabeledContent("Device", value: Device.summary)
                LabeledContent("GPU shared memory", value: RuntimeController.sharedMemory.group != nil ? "app group"
                               : RuntimeController.sharedMemory.fileFallback ? "file fallback" : "unavailable")
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    Picker("CPU model", selection: $model.settings.cpuModel) {
                        Text("Neoverse N1 (ARMv8.2, default)").tag("neoverse-n1")
                        Text("Neoverse V1 (ARMv8.4, no SVE or PAuth)").tag("neoverse-v1")
                        Text("max (all emulated features)").tag("max")
                    }
                    Toggle("Linux memory in a file", isOn: $model.settings.ramInFile)
                    Text("On by default. Keeps Linux's RAM in a file so \(Device.os) can write it out instead of terminating iDeck when memory runs low. Turn off only to compare.")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                    TextField("Runtime manifest URL (https)", text: $manifestURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.footnote.monospaced())
                }
            }
            Section("Diagnostics") {
                ShareLink(item: Paths.qemuLog) { Label("Share QEMU log", systemImage: "doc.text") }
                ShareLink(item: Paths.consoleLog) { Label("Share Linux console log", systemImage: "terminal") }
            }
            Text("Steam options apply right away (Steam restarts). Other changes apply the next time Linux starts.").font(.caption).foregroundStyle(Theme.textTertiary)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Settings")
    }

    /// Steam options take effect right away while Linux runs (Steam is
    /// restarted); the setting is saved by AppModel before this runs.
    private func applySteam() {
        Task { await runtime.applySteamSettings() }
    }
}
