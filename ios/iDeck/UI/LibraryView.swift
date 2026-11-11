import SwiftUI
import UIKit

struct LibraryView: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var runtime: RuntimeController
    @State private var selected: LibraryModel.Game?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Filter", selection: $library.filter) {
                    ForEach(LibraryModel.Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)

                if let e = library.error, library.games.isEmpty {
                    Card { Text(e).foregroundStyle(Theme.textSecondary) }
                } else if library.visible.isEmpty && !library.loading {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No games here yet").font(.headline).foregroundStyle(.white)
                            Text("Install games from the Steam client: browse your library or the store in Steam, then press Install. They appear here as soon as Steam starts downloading.")
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18)], spacing: 22) {
                    ForEach(library.visible) { g in
                        Button { selected = g } label: { PosterTile(game: g) }.buttonStyle(.plain)
                    }
                }
                Text("Shows games Steam has installed or is downloading in Linux. Your full library and the store are in the Steam client itself.")
                    .font(.footnote).foregroundStyle(Theme.textTertiary)
            }
            .padding(28)
        }
        .searchable(text: $library.search, prompt: "Search games")
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await library.refresh() } } label: {
                    if library.loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .refreshable { await library.refresh() }
        .task { await library.refresh() }
        .sheet(item: $selected) { g in GameDetailView(game: g) }
    }
}

struct PosterTile: View {
    var game: LibraryModel.Game
    @State private var image: UIImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surfaceRaised)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Text(game.name).font(.headline).multilineTextAlignment(.center).foregroundStyle(Theme.textSecondary).padding()
                }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if game.isDownloading {
                    Text("\(Int(game.progress * 100))%").font(.caption2.weight(.bold).monospacedDigit())
                        .padding(6).background(.black.opacity(0.6), in: Capsule()).padding(8)
                }
            }
            Text(game.name).font(.subheadline.weight(.medium)).foregroundStyle(.white).lineLimit(1)
            Text(game.isInstalled ? Format.bytes(game.sizeOnDisk) : game.state.capitalized)
                .font(.caption).foregroundStyle(Theme.textTertiary)
        }
        .task(id: game.appid) {
            image = await ArtworkCache.shared.image(appid: game.appid, kind: "library_600x900")
        }
    }
}

struct GameDetailView: View {
    var game: LibraryModel.Game
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var hero: UIImage?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ZStack(alignment: .bottomLeading) {
                    if let hero { Image(uiImage: hero).resizable().aspectRatio(contentMode: .fill).frame(height: 240).clipped() }
                    else { Rectangle().fill(Theme.surfaceRaised).frame(height: 240) }
                    LinearGradient(colors: [.clear, Theme.background], startPoint: .center, endPoint: .bottom)
                    Text(game.name).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white).padding(20)
                }
                HStack(spacing: 12) {
                    if game.isInstalled {
                        Button {
                            Task {
                                do {
                                    try await library.play(game)
                                    dismiss()
                                    model.showGame = true
                                } catch { self.error = error.localizedDescription }
                            }
                        } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button {
                            Task {
                                try? await library.install(game)
                                dismiss()
                                model.showGame = true
                            }
                        } label: { Label("Install in Steam", systemImage: "arrow.down") }.buttonStyle(PrimaryButtonStyle())
                    }
                    Button("Close") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                }.padding(.horizontal, 20)
                if let error { Text(error).foregroundStyle(Theme.danger).padding(.horizontal, 20) }
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        StatTile(label: "Status", value: game.state.capitalized)
                        StatTile(label: "Size", value: Format.bytes(game.sizeOnDisk))
                    }
                    HStack(spacing: 12) {
                        StatTile(label: "Compatibility", value: library.compatStatus(game.appid).capitalized,
                                 detail: "From iDeck's tested-games database")
                        StatTile(label: "Last played", value: game.lastPlayed.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Never")
                    }
                }.padding(.horizontal, 20)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .task { hero = await ArtworkCache.shared.image(appid: game.appid, kind: "library_hero") }
    }
}
