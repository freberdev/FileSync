import SwiftUI
import FilsynkCore

struct MenuView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let status = model.status
        Text(StatusPresentation.headline(status, timeZone: .current))
        if !status.folders.isEmpty {
            Divider()
            ForEach(status.folders) { folder in
                Text(DestinationRows.menuLine(
                    folder, home: NSHomeDirectory(), serverHome: model.config.verifiedHome, timeZone: .current))
            }
        }
        Divider()
        Button(L("Synka nu")) { model.syncNow() }
        Button(model.isPaused ? L("Fortsätt") : L("Pausa")) { model.togglePause() }
        Button(L("Inställningar…")) {
            openWindow(id: "settings")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button(L("Visa logg")) { model.openLog() }
        Divider()
        Button(L("Avsluta FileSync")) { model.quit() }
    }
}
