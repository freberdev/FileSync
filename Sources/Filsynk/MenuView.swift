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
                Text("\(rowName(folder))   \(StatusPresentation.folderLabel(folder, timeZone: .current))")
            }
        }
        Divider()
        Button("Synka nu") { model.syncNow() }
        Button(model.isPaused ? "Fortsätt" : "Pausa") { model.togglePause() }
        Button("Inställningar…") {
            openWindow(id: "settings")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("Visa logg") { model.openLog() }
        Divider()
        Button("Avsluta Filsynk") { model.quit() }
    }

    private func rowName(_ folder: FolderStatus) -> String {
        let path = StatusPresentation.displayPath(folder.path, home: NSHomeDirectory())
        guard let destination = folder.destination else { return path }
        return path + " → " + StatusPresentation.destinationLabel(destination, serverHome: model.config.verifiedHome)
    }
}
