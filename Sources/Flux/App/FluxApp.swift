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
                Divider()
                Button("Clear Completed") { model.clearCompleted() }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
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
        case .failed(let message):
            ContentUnavailableView {
                Label("Flux couldn’t start", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .ready:
            DownloadsView()
        }
    }
}
