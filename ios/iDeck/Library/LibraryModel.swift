import Foundation

/// The Steam library as the Steam client in Linux sees it (read from its
/// local appmanifest files by the guest agent). Download speeds are derived
/// from successive samples.
@MainActor
final class LibraryModel: ObservableObject {
    struct Game: Identifiable, Equatable {
        var id: Int { appid }
        var appid: Int
        var name: String
        var state: String
        var sizeOnDisk: Int64
        var bytesToDownload: Int64
        var bytesDownloaded: Int64
        var lastPlayed: Date?
        var isTool: Bool
        var speed: Double = 0

        var isInstalled: Bool { state == "installed" }
        var isDownloading: Bool { state == "downloading" || state == "paused" || state == "update-queued" }
        var progress: Double {
            bytesToDownload > 0 ? Double(bytesDownloaded) / Double(bytesToDownload) : (isInstalled ? 1 : 0)
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", installed = "Installed", downloading = "Downloading", recent = "Recent"
        var id: String { rawValue }
    }

    @Published private(set) var games: [Game] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var search = ""
    @Published var filter: Filter = .all
    private(set) var compat: [Int: [String: Any]] = [:]
    private let runtime: RuntimeController
    private var lastSample: [Int: (Date, Int64)] = [:]
    private var pollTask: Task<Void, Never>?

    init(runtime: RuntimeController) {
        self.runtime = runtime
        loadCompat()
    }

    var visible: [Game] {
        let base = games.filter { !$0.isTool }
        let filtered: [Game]
        switch filter {
        case .all: filtered = base
        case .installed: filtered = base.filter(\.isInstalled)
        case .downloading: filtered = base.filter(\.isDownloading)
        case .recent: filtered = base.filter { $0.lastPlayed != nil }.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? filtered : filtered.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var downloads: [Game] { games.filter(\.isDownloading) }
    var recent: [Game] {
        Array(games.filter { !$0.isTool && $0.lastPlayed != nil }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }.prefix(8))
    }

    func refresh() async {
        guard runtime.isRunning, let agent = runtime.agent else {
            error = "Start Linux to see your Steam library."
            return
        }
        loading = true
        defer { loading = false }
        do {
            let r = try await agent.requestDict("steam.library", timeout: 90)
            let now = Date()
            games = (r["games"] as? [[String: Any]] ?? []).map { g in
                let appid = (g["appid"] as? NSNumber)?.intValue ?? 0
                let downloaded = (g["bytes_downloaded"] as? NSNumber)?.int64Value ?? 0
                var game = Game(appid: appid, name: g["name"] as? String ?? "App \(appid)",
                                state: g["state"] as? String ?? "unknown",
                                sizeOnDisk: (g["size_on_disk"] as? NSNumber)?.int64Value ?? 0,
                                bytesToDownload: (g["bytes_to_download"] as? NSNumber)?.int64Value ?? 0,
                                bytesDownloaded: downloaded,
                                lastPlayed: ((g["last_played"] as? NSNumber)?.doubleValue).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                                isTool: g["is_tool"] as? Bool ?? false)
                if let (t, b) = lastSample[appid], now.timeIntervalSince(t) > 0.5, downloaded >= b {
                    game.speed = Double(downloaded - b) / now.timeIntervalSince(t)
                }
                lastSample[appid] = (now, downloaded)
                return game
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Polls while a screen showing downloads is visible.
    func startPolling(interval: TimeInterval = 3) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func play(_ game: Game) async throws {
        try await runtime.openSteam("steam://rungameid/\(game.appid)")
    }

    func install(_ game: Game) async throws {
        try await runtime.openSteam("steam://install/\(game.appid)")
    }

    // MARK: Compatibility database (bundled; results only from real tests)

    private func loadCompat() {
        guard let url = Bundle.main.url(forResource: "compat", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for g in obj["games"] as? [[String: Any]] ?? [] {
            if let id = (g["appid"] as? NSNumber)?.intValue { compat[id] = g }
        }
    }

    func compatStatus(_ appid: Int) -> String { compat[appid]?["status"] as? String ?? "untested" }
}
