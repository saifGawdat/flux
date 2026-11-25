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
            CommandGroup(replacing: .newItem) {
                Button("Add Download…") { model.presentAddSheet() }
                    .keyboardShortcut("n")
                    .disabled(model.manager == nil)
            }
            CommandMenu("Downloads") {
                Button("Resume All") { model.resumeAll() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button("Pause All") { model.pauseAll() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Retry Failed") { model.retryFailed() }
                    .disabled(model.failedCount == 0)
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
    }
}

/// Shows startup progress or a database error instead of a half-working UI.
struct RootView: View {
    @Environment(AppModel.self) private var model

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
        }
    }
}
