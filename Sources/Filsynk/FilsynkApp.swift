import SwiftUI
import FilsynkCore

@main
struct FilsynkApp: App {
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: StatusPresentation.symbolName(model.status.overall))
                .task { startOnce() }
        }
        .menuBarExtraStyle(.menu)

        Window(L("FileSync — Inställningar"), id: "settings") {
            SettingsView(model: model)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }

    @MainActor private func startOnce() {
        guard !model.hasStarted else { return }
        model.start()
        if model.isFirstStart {
            openWindow(id: "settings")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}
