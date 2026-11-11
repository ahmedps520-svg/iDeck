import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var runtime: RuntimeController
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if library.downloads.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No active downloads").font(.headline).foregroundStyle(.white)
                            Text(runtime.isRunning ? "Games you install in Steam appear here with their progress." :
                                    "Start Linux to see Steam downloads.")
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                ForEach(library.downloads) { g in
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(g.name).font(.headline).foregroundStyle(.white)
                                Spacer()
                                StatusPill(text: g.state == "paused" ? "Paused" : (g.state == "downloading" ? "Downloading" : "Queued"),
                                           color: g.state == "downloading" ? Theme.accent : Theme.warning)
                            }
                            ProgressView(value: g.progress).tint(Theme.accent)
                            HStack {
                                Text("\(Format.bytes(g.bytesDownloaded)) of \(Format.bytes(g.bytesToDownload))")
                                Spacer()
                                if g.speed > 0 {
                                    Text("\(Format.bytes(Int64(g.speed)))/s · \(Format.duration(Double(g.bytesToDownload - g.bytesDownloaded) / g.speed)) left")
                                }
                            }
                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                HStack(spacing: 12) {
                    Button {
                        Task {
                            try? await runtime.openSteam("steam://open/downloads")
                            model.showGame = true
                        }
                    } label: { Label("Pause / Resume in Steam", systemImage: "playpause") }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!runtime.isRunning)
                }
                Text("Steam manages the queue itself; pausing and reordering happen in Steam's Downloads page. Speeds here are measured from Steam's progress files.")
                    .font(.footnote).foregroundStyle(Theme.textTertiary)
            }
            .padding(28)
        }
        .navigationTitle("Downloads")
        .onAppear { library.startPolling() }
        .onDisappear { library.stopPolling() }
    }
}
