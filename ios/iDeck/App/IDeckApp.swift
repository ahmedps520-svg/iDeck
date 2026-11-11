import SwiftUI

@main
struct IDeckApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.runtime)
                .environmentObject(model.installer)
                .environmentObject(model.library)
                .environmentObject(model.runtime.controllers)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let runtime: RuntimeController
    let installer: Installer
    let library: LibraryModel
    @Published var showGame = false
    @Published var settings = Settings.load() {
        didSet { settings.save() }
    }

    init() {
        let rt = RuntimeController()
        runtime = rt
        installer = Installer(runtime: rt)
        library = LibraryModel(runtime: rt)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// The home screen's main action.
    func startGaming() {
        showGame = true
        Task { await runtime.startGaming() }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var installer: Installer

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if installer.isComplete {
                MainView()
                    .transition(.opacity)
            } else {
                SetupView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: installer.isComplete)
        .fullScreenCover(isPresented: $model.showGame) {
            GameView()
        }
    }
}

enum Screen: String, CaseIterable, Identifiable, Hashable {
    case home, library, downloads, runtime, performance, controls, storage, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "square.grid.2x2.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .runtime: return "cpu.fill"
        case .performance: return "speedometer"
        case .controls: return "gamecontroller.fill"
        case .storage: return "internaldrive.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct MainView: View {
    @State private var selection: Screen? = .home
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .compact {
            TabView {
                // iPhone: iOS puts the tabs past the fifth under "More", so
                // Performance, Controls and Storage stay reachable.
                ForEach([Screen.home, .library, .downloads, .settings, .runtime, .performance, .controls, .storage]) { s in
                    NavigationStack { detail(for: s) }
                        .tabItem { Label(s.title, systemImage: s.icon) }
                }
            }
        } else {
            NavigationSplitView {
                List(Screen.allCases, selection: $selection) { s in
                    Label(s.title, systemImage: s.icon)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .tag(s)
                }
                .scrollContentBackground(.hidden)
                .background(Theme.surface)
                .navigationTitle("iDeck")
            } detail: {
                NavigationStack { detail(for: selection ?? .home) }
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    @ViewBuilder
    private func detail(for s: Screen) -> some View {
        Group {
            switch s {
            case .home: HomeView()
            case .library: LibraryView()
            case .downloads: DownloadsView()
            case .runtime: RuntimeView()
            case .performance: PerformanceView()
            case .controls: ControlsView()
            case .storage: StorageView()
            case .settings: SettingsView()
            }
        }
        .background(Theme.background.ignoresSafeArea())
    }
}
