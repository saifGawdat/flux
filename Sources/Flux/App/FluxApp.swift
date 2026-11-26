import FluxCore
import SwiftUI

@main
struct FluxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Flux", id: "main") {
            RootView()
                .environment(model)
                .tint(FluxTheme.accent)
                .frame(minWidth: 720, minHeight: 440)
        }
        .defaultSize(width: 1000, height: 640)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.updater.checkForUpdates() }
                    .disabled(!model.updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Download…") { model.presentAddSheet() }
                    .keyboardShortcut("n")
                    .disabled(model.manager == nil)
                Divider()
                QuickLookCommand(model: model)
                Divider()
                Button("Import Links…") { LinkListPanels.importLinks(model) }
                    .keyboardShortcut("o")
                    .disabled(model.manager == nil)
                Menu("Export Downloads") {
                    ForEach(LinkListFormat.allCases) { format in
                        Button("\(format.title)…") { LinkListPanels.export(model, format: format) }
                    }
                }
                .disabled(model.downloads.isEmpty)
            }
            CommandMenu("Downloads") {
                Button("Resume All") { model.resumeAll() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button("Pause All") { model.pauseAll() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Retry Failed") { model.retryFailed() }
                    .disabled(model.failedCount == 0)
                Divider()
                Button("New Queue…") { model.queueEditor = QueueEditorRequest() }
                    .disabled(model.manager == nil)
                if !model.settings.queues.isEmpty {
                    Menu("Start or Stop Queue") {
                        ForEach(model.settings.queues) { queue in
                            Button(queue.isRunning ? "Stop “\(queue.name)”" : "Start “\(queue.name)”") {
                                queue.isRunning ? model.stopQueue(queue.id) : model.startQueue(queue.id)
                            }
                        }
                    }
                }
                Divider()
                Toggle("Limit Download Speed (\(Format.limit(model.settings.speedLimit)))", isOn: Binding(
                    get: { model.settings.speedLimitEnabled },
                    set: { model.setGlobalSpeedLimit(enabled: $0) }))
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Divider()
                Button("Clear Completed") { model.clearCompleted() }
                    .help("Moves finished downloads to History")
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .tint(FluxTheme.accent)
        }

        MenuBarExtra(isInserted: Binding(
            get: { model.settings.showInMenuBar },
            set: { value in model.updateSettings { $0.showInMenuBar = value } }
        )) {
            MenuBarContent()
                .environment(model)
                .tint(FluxTheme.accent)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// File › Quick Look (⌘Y) for the selected finished downloads; Space does the same in the list.
struct QuickLookCommand: View {
    // Commands don't get the window's environment.
    let model: AppModel
    @FocusedValue(\.downloadSelection) private var selection

    var body: some View {
        Button(model.quickLookURL == nil ? "Quick Look" : "Close Quick Look") { model.quickLook(selection ?? []) }
            .keyboardShortcut("y")
            .disabled(model.quickLookURL == nil && !model.canQuickLook(selection ?? []))
    }
}

private struct DownloadSelectionKey: FocusedValueKey {
    typealias Value = Set<UUID>
}

extension FocusedValues {
    /// The downloads selected in the focused window.
    var downloadSelection: Set<UUID>? {
        get { self[DownloadSelectionKey.self] }
        set { self[DownloadSelectionKey.self] = newValue }
    }
}

/// Shows startup progress or a database error instead of a half-working UI.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView("Opening Flux…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { SkyBackground() }
        case .failed(let message):
            ContentUnavailableView {
                Label("Flux couldn’t start", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
            .background { SkyBackground() }
        case .ready:
            DownloadsView()
                .onAppear { model.openMainWindow = { openWindow(id: "main") } }
        }
    }
}
