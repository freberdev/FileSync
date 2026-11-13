import SwiftUI
import AppKit
import FilsynkCore

struct SettingsView: View {
    let model: AppModel

    @State private var serverDraft = ""
    @State private var excludesDraft = ""
    @State private var selection: String?
    @State private var pendingLocalPath: String?
    @State private var pendingRemote = ""
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

    private var foldersSection: some View {
        Section("Mappar") {
            Table(model.config.folders, selection: $selection) {
                TableColumn("På Macen") { folder in
                    Text(StatusPresentation.displayPath(folder.path, home: home))
                }
                TableColumn("På servern") { folder in
                    Text(remoteDisplayPath(folder.remotePath))
                }
                TableColumn("") { folder in
                    Text(stateLabel(folder))
                }
            }
            .frame(minHeight: 120)

            HStack {
                Button { chooseFolder() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Lägg till mapp")
                    .disabled(model.isLocked)
                Button {
                    if let folder = model.config.folders.first(where: { $0.path == selection }) {
                        model.removeFolder(folder)
                        selection = nil
                    }
                } label: { Image(systemName: "minus") }
                    .accessibilityLabel("Ta bort mapp")
                    .disabled(selection == nil || model.isLocked)
            }
            Text("Inget tas bort på servern.").font(.caption).foregroundStyle(.secondary)

            if let local = pendingLocalPath {
                HStack {
                    Text(StatusPresentation.displayPath(local, home: home))
                    Image(systemName: "arrow.right")
                    TextField("Sökväg på servern", text: $pendingRemote)
                        .disabled(model.isLocked)
                    Button("Lägg till") {
                        let remote = pendingRemote
                        Task {
                            if await model.addFolder(localPath: local, remoteEntered: remote) {
                                pendingLocalPath = nil
                            }
                        }
                    }
                    .disabled(model.isLocked)
                    Button("Avbryt") { pendingLocalPath = nil }
                        .disabled(model.isLocked)
                    if model.isBusy { ProgressView().controlSize(.small) }
                }
            }

            if let pending = model.pendingFolder {
                ForEach(pending.warnings, id: \.self) { Text($0) }
                HStack {
                    Button("Lägg till ändå") {
                        Task {
                            if await model.confirmPendingFolder() { pendingLocalPath = nil }
                        }
                    }
                    .disabled(model.isBusy)
                    Button("Avbryt") {
                        model.cancelPendingFolder()
                        pendingLocalPath = nil
                    }
                    .disabled(model.isBusy)
                }
            }
        }
    }

    /// The server's home directory is shown as "~", like the Mac's in the other column.
    private func remoteDisplayPath(_ path: String) -> String {
        let remoteHome = model.config.verifiedHome
        return remoteHome.isEmpty ? path : StatusPresentation.displayPath(path, home: remoteHome)
    }

    private func stateLabel(_ folder: FolderConfig) -> String {
        guard folder.isReady else { return "Inte inställd" }
        guard let status = model.state(of: folder) else { return "Väntar" }
        return StatusPresentation.folderLabel(status, timeZone: .current)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingLocalPath = url.path
        pendingRemote = "~/" + url.lastPathComponent
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
