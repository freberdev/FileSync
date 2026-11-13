import SwiftUI
import AppKit
import FilsynkCore

struct SettingsView: View {
    let model: AppModel

    @State private var serverDraft = ""
    @State private var excludesDraft = ""
    @State private var selection: String?
    @State private var showsForm = false
    @State private var formFolder: String?
    @State private var formKind = DestinationKind.server
    @State private var formRemote = ""
    @State private var formDiskPath: String?
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @FocusState private var serverFocused: Bool
    @FocusState private var excludesFocused: Bool

    private var home: String { NSHomeDirectory() }

    var body: some View {
        Form {
            if model.configError != nil {
                Section {
                    Text("Konfigurationsfilen kan inte läsas. Rätta eller ta bort filen och starta om Filsynk.")
                        .foregroundStyle(.red)
                    Text(model.configFilePath).textSelection(.enabled)
                }
            } else {
                serverSection
                foldersSection
                excludesSection
            }
            startSection
            if let message = model.issue ?? loginError {
                Text(message).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 560)
        .onAppear {
            serverDraft = model.config.server
            excludesDraft = model.config.excludesText()
            launchAtLogin = LoginItem.isEnabled
        }
    }

    // MARK: Server

    private var serverSection: some View {
        Section("Server") {
            TextField("Adress", text: $serverDraft, prompt: Text("användare@server"))
                .focused($serverFocused)
                .disabled(model.isLocked)
                .onSubmit { model.setServer(serverDraft) }
                .onChange(of: serverFocused) { _, focused in if !focused { model.setServer(serverDraft) } }
            LabeledContent("Nyckel") { Text(model.config.identityFile).textSelection(.enabled) }
            HStack {
                Button("Testa anslutning") {
                    model.setServer(serverDraft)
                    guard model.config.server == serverDraft.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                    Task { await model.testConnection() }
                }
                .disabled(model.isLocked)
                connectionLine
            }
            if !model.config.isVerified && model.connection == .unknown {
                Text("Skriv serverns adress och tryck Testa anslutning. Första gången skapas en egen nyckel, och du får ett kommando att köra i Terminal för att lägga in den på servern.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.needsKeyInstall {
                HStack {
                    Text(model.copyIdCommand)
                        .textSelection(.enabled)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Button("Kopiera") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.copyIdCommand, forType: .string)
                    }
                }
            }
        }
    }

    @ViewBuilder private var connectionLine: some View {
        switch model.connection {
        case .unknown: EmptyView()
        case .testing: ProgressView().controlSize(.small)
        case .ok(let text): Text(text)
        case .problem(let text): Text(text).foregroundStyle(.red)
        }
    }

    // MARK: Folders

    private enum DestinationKind: Hashable { case server, disk }

    /// Tag of the menu entry that opens the folder picker.
    private let chooseFolderTag = "\u{0}choose"

    private var foldersSection: some View {
        Section("Mappar") {
            Table(model.destinationRows, selection: $selection) {
                TableColumn("På Macen", value: \.local)
                TableColumn("Mål", value: \.destination)
                TableColumn("", value: \.state)
            }
            .frame(minHeight: 120)

            HStack {
                Button { openForm() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Lägg till mål")
                    .disabled(model.isLocked)
                Button {
                    if let row = model.destinationRows.first(where: { $0.id == selection }) {
                        model.removeDestination(row)
                        selection = nil
                    }
                } label: { Image(systemName: "minus") }
                    .accessibilityLabel("Ta bort mål")
                    .disabled(selection == nil || model.isLocked)
            }
            Text("Inget tas bort på servern eller disken.").font(.caption).foregroundStyle(.secondary)

            if showsForm { addForm }

            if let pending = model.pendingFolder {
                ForEach(pending.warnings, id: \.self) { Text($0) }
                HStack {
                    Button("Lägg till ändå") {
                        Task {
                            if await model.confirmPendingFolder() { closeForm() }
                        }
                    }
                    .disabled(model.isBusy)
                    Button("Avbryt") {
                        model.cancelPendingFolder()
                        closeForm()
                    }
                    .disabled(model.isBusy)
                }
            }
        }
    }

    @ViewBuilder private var addForm: some View {
        Picker("Mapp på Macen", selection: folderChoice) {
            if let chosen = formFolder, !model.config.folders.contains(where: { $0.path == chosen }) {
                Text(StatusPresentation.displayPath(chosen, home: home)).tag(Optional(chosen))
            }
            ForEach(model.config.folders) { folder in
                Text(StatusPresentation.displayPath(folder.path, home: home)).tag(Optional(folder.path))
            }
            Divider()
            Text("Välj mapp…").tag(Optional(chooseFolderTag))
        }
        .disabled(model.isLocked)

        Picker("Mål", selection: $formKind) {
            Text("Server").tag(DestinationKind.server)
            Text("Extern disk").tag(DestinationKind.disk)
        }
        .pickerStyle(.segmented)
        .disabled(model.isLocked)

        switch formKind {
        case .server:
            TextField("Sökväg på servern", text: $formRemote)
                .disabled(model.isLocked)
        case .disk:
            HStack {
                Button("Välj mapp på disken…") { chooseDiskFolder() }
                    .disabled(model.isLocked)
                if let picked = formDiskPath {
                    Text(model.pickedDiskText(picked)).textSelection(.enabled)
                }
            }
        }

        HStack {
            Button("Lägg till") { submitForm() }
                .disabled(model.isLocked || !formIsComplete)
            Button("Avbryt") { closeForm() }
                .disabled(model.isLocked)
            if model.isBusy { ProgressView().controlSize(.small) }
        }
    }

    private var formIsComplete: Bool {
        guard formFolder != nil else { return false }
        return formKind == .server || formDiskPath != nil
    }

    private var folderChoice: Binding<String?> {
        Binding(
            get: { formFolder },
            set: { choice in
                guard let choice else { return }
                if choice == chooseFolderTag {
                    chooseFolder()
                } else {
                    selectFolder(choice)
                }
            })
    }

    private func selectFolder(_ path: String) {
        formFolder = path
        formRemote = "~/" + (path as NSString).lastPathComponent
    }

    private func openForm() {
        formFolder = nil
        formKind = .server
        formRemote = ""
        formDiskPath = nil
        showsForm = true
    }

    private func closeForm() {
        showsForm = false
        formFolder = nil
        formDiskPath = nil
    }

    private func submitForm() {
        guard let folder = formFolder else { return }
        let destination: NewDestination
        switch formKind {
        case .server: destination = .server(remoteEntered: formRemote)
        case .disk:
            guard let picked = formDiskPath else { return }
            destination = .disk(pickedPath: picked)
        }
        Task {
            if await model.addDestination(destination, toFolder: folder) { closeForm() }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectFolder(url.path)
    }

    private func chooseDiskFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        formDiskPath = url.path
    }

    // MARK: Excludes and start

    private var excludesSection: some View {
        Section("Undantag (gäller alla mappar)") {
            TextField("Undantag", text: $excludesDraft, prompt: Text("node_modules, *.tmp"))
                .focused($excludesFocused)
                .disabled(model.isLocked)
                .onSubmit { model.setExcludes(excludesDraft) }
                .onChange(of: excludesFocused) { _, focused in if !focused { model.setExcludes(excludesDraft) } }
        }
    }

    private var startSection: some View {
        Section("Start") {
            Toggle("Starta vid inloggning", isOn: Binding(
                get: { launchAtLogin },
                set: { on in
                    do {
                        try LoginItem.setEnabled(on)
                        loginError = nil
                    } catch {
                        loginError = "Kunde inte ändra inloggningsobjektet"
                    }
                    launchAtLogin = LoginItem.isEnabled
                }))
        }
    }
}
