import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var runtime: RuntimeController
    @EnvironmentObject var library: LibraryModel
    @State private var signingNoticeDismissed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                if let notice = runtime.previousSessionNotice {
                    NoticeCard(icon: "exclamationmark.triangle.fill", title: "The last session ended unexpectedly",
                               message: notice) { runtime.previousSessionNotice = nil }
                }
                if !signingNoticeDismissed, let w = SigningProfile.current?.warning(device: Device.name) {
                    NoticeCard(icon: "clock.badge.exclamationmark", title: w.title, message: w.message) {
                        signingNoticeDismissed = true
                    }
                }
                if !library.recent.isEmpty {
                    SectionHeader(title: "Recently Played")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(library.recent) { g in
                                GameCapsule(game: g).frame(width: 300)
                            }
                        }
                    }
                }
                let installed = library.games.filter { $0.isInstalled && !$0.isTool }
                if !installed.isEmpty {
                    SectionHeader(title: "Installed", subtitle: "\(installed.count) games")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                        ForEach(installed.prefix(12)) { g in GameCapsule(game: g) }
                    }
                }
                HStack(spacing: 16) {
                    StatTile(label: "Linux", value: runtime.phase.label, tint: runtime.phase.color)
                    StatTile(label: "Steam", value: runtime.metrics.steamRunning ? "Running" : "Stopped",
                             tint: runtime.metrics.steamRunning ? Theme.success : Theme.textSecondary)
                    StatTile(label: "Downloads", value: "\(library.downloads.count)",
                             detail: library.downloads.first.map { "\($0.name) \(Int($0.progress * 100))%" })
                }
            }
            .padding(28)
        }
        .navigationTitle("Home")
        .task { if runtime.isRunning { await library.refresh() } }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(LinearGradient(colors: [Theme.surfaceRaised, Theme.background], startPoint: .topTrailing, endPoint: .bottomLeading))
                .overlay(
                    RadialGradient(colors: [Theme.accent.opacity(0.28), .clear], center: .topTrailing, startRadius: 10, endRadius: 520)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                )
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Theme.stroke))
            VStack(alignment: .leading, spacing: 14) {
                StatusPill(text: runtime.phase.label, color: runtime.phase.color)
                Text(runtime.isRunning ? "Steam is ready" : "Ready when you are")
                    .font(.system(size: 38, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text(runtime.isRunning ? "Linux is running. Jump back into Steam." :
                        "Starts Linux on your \(Device.name) and opens the Steam client.")
                    .foregroundStyle(Theme.textSecondary)
                Button {
                    model.startGaming()
                } label: {
                    Label(runtime.isRunning ? "RESUME" : "START GAMING", systemImage: "play.fill")
                        .font(.system(.title3, design: .rounded).weight(.heavy))
                        .padding(.horizontal, 14)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(32)
        }
        .frame(minHeight: 280)
    }
}

/// A dismissible note under the hero (for example after iOS closed iDeck
/// while Linux was running).
struct NoticeCard: View {
    var icon: String
    var title: String
    var message: String
    var onDismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).foregroundStyle(.white)
                Text(message).font(.subheadline).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(Theme.textSecondary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.warning.opacity(0.35)))
    }
}

struct GameCapsule: View {
    var game: LibraryModel.Game
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var model: AppModel
    @State private var image: UIImage?

    var body: some View {
        Button {
            Task {
                try? await library.play(game)
                model.showGame = true
            }
        } label: {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let image { Image(uiImage: image).resizable().aspectRatio(460.0 / 215.0, contentMode: .fill) }
                    else { Rectangle().fill(Theme.surfaceRaised).aspectRatio(460.0 / 215.0, contentMode: .fit) }
                }
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    if game.isDownloading {
                        ProgressView(value: game.progress).tint(Theme.accent)
                    }
                }.padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke))
        }
        .buttonStyle(.plain)
        .task(id: game.appid) { image = await ArtworkCache.shared.image(appid: game.appid, kind: "header") }
    }
}
