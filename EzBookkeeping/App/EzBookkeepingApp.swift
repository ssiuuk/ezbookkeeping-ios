import SwiftUI
import UIKit

@main
struct EzBookkeepingApp: App {
    @StateObject private var appState = AppState()
    @AppStorage(AppState.themeKey) private var theme = ThemeChoice.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    init() {
        if ProcessInfo.processInfo.arguments.contains("-disableAnimations") {
            UIView.setAnimationsEnabled(false)
        }

        TransactionEditModel.makeThumbnail = PhotoProcessing.thumbnail
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .preferredColorScheme(ThemeChoice(rawValue: theme)?.colorScheme)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    await appState.sendWaiting()
                }
            case .background:
                AppState.scheduleBackgroundSync()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(AppState.syncTaskId)) {
            await AppState.sendWaitingInBackground()
        }
    }
}

/// Opens the right screen: the server picker, sign-in, or the app itself.
struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let server = appState.activeServer {
                if server.isSignedIn {
                    MainTabView()
                        .id(server.id)
                } else {
                    NavigationStack {
                        LoginView(server: server)
                    }
                    .id(server.id)
                }
            } else {
                NavigationStack {
                    ServersView(firstRun: true)
                }
            }
        }
        .onOpenURL { url in
            appState.open(url)
        }
        .alert("Signed out", isPresented: Binding(
            get: { appState.notice != nil },
            set: { if !$0 { appState.notice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.notice ?? "")
        }
    }
}
