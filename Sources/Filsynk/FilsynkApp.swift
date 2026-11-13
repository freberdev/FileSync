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

        Window("Filsynk — Inställningar", id: "settings") {
            Text("Inställningar kommer snart")
                .padding(40)
        }
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
