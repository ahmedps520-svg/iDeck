import SwiftUI
import UniformTypeIdentifiers

struct StorageView: View {
    @EnvironmentObject var runtime: RuntimeController
    @State private var snapshots: [StorageManager.Snapshot] = []
    @State private var usage = StorageManager.usage()
    @State private var message: String?
    @State private var pickingFolder = false
    @State private var confirmRestore: StorageManager.Snapshot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    StatTile(label: "\(Device.name) free", value: Format.bytes(Paths.volumeFreeBytes),
                             detail: "of \(Format.bytes(Paths.volumeTotalBytes))")
                    StatTile(label: "Game library", value: Format.bytes(usage.allocated),
                             detail: "on disk · grows up to \(Format.bytes(usage.size)) and beyond as needed")
                    StatTile(label: "Used in Linux", value: runtime.metrics.librarySize > 0 ? Format.bytes(runtime.metrics.libraryUsed) : "—",
                             detail: runtime.metrics.librarySize > 0 ? "of \(Format.bytes(runtime.metrics.librarySize)) formatted" : "Start Linux to measure")
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Snapshots").font(.headline).foregroundStyle(.white)
                            Spacer()
                            Button("Create Snapshot") {
                                do { try StorageManager.createSnapshot(); reload(); message = "Snapshot created" }
                                catch { message = error.localizedDescription }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(runtime.isRunning)
                        }
                        Text("Snapshots are instant APFS clones of the whole library (Steam, games, saves). They only use space for data that changes afterwards. Shut down Linux first.")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                        ForEach(snapshots) { s in
                            HStack {
                                Text(s.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.white)
                                Text("\(Format.bytes(s.allocated)) unique").font(.caption).foregroundStyle(Theme.textTertiary)
                                Spacer()
                                Button("Restore") { confirmRestore = s }.disabled(runtime.isRunning)
                                Button(role: .destructive) {
                                    try? StorageManager.deleteSnapshot(s)
                                    reload()
                                } label: { Image(systemName: "trash") }
                            }
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("External drive").font(.headline).foregroundStyle(.white)
                        Text("Store additional games on a USB-C SSD. iDeck creates a library image in the folder you choose; in Steam add /mnt/external as a library folder (Settings › Storage).")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                        HStack(spacing: 12) {
                            Button("Choose Folder…") { pickingFolder = true }.buttonStyle(SecondaryButtonStyle())
                            if Settings.load().externalLibraryBookmark != nil {
                                Button("Disconnect") { StorageManager.clearExternalFolder(); message = "External library removed from iDeck (files kept)" }
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                        }
                    }
                }
                Card {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Cache cleanup").font(.headline).foregroundStyle(.white)
                            Text("Removes partial runtime downloads.").font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button("Clean") { message = "Freed \(Format.bytes(StorageManager.cleanCaches()))" }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(Theme.textSecondary) }
            }
            .padding(28)
        }
        .navigationTitle("Storage")
        .onAppear(perform: reload)
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                do { try StorageManager.setExternalFolder(url); message = "External library ready. It is attached the next time Linux starts." }
                catch { message = error.localizedDescription }
            case .failure(let e): message = e.localizedDescription
            }
        }
        .confirmationDialog("Restore this snapshot?", isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } })) {
            Button("Restore (replaces the current library)", role: .destructive) {
                if let s = confirmRestore {
                    do { try StorageManager.restoreSnapshot(s); message = "Library restored" }
                    catch { message = error.localizedDescription }
                }
                confirmRestore = nil
            }
        }
    }

    private func reload() {
        snapshots = StorageManager.snapshots()
        usage = StorageManager.usage()
    }
}
