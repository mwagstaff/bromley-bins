import BinsCore
import SwiftUI

@main
struct BromleyBinsApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        NotificationPresenter.shared.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.binsBrand)
                .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                    model.dayDidChange()
                }
                #if DEBUG
                .onOpenURL { url in
                    Task { await DebugReminderTester.handle(url) }
                }
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.refreshIfDue() }
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            BackgroundRefresh.schedule()
            await model.refresh()
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.hasProperty {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        .animation(.default, value: model.hasProperty)
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Collections", systemImage: "trash") {
                CollectionsView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
    }
}
