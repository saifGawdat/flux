import AppKit
import FluxCore
import SwiftUI

/// Settings › System: menu bar, notifications, Dock, Spotlight, login, global shortcuts.
struct SystemSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Menu Bar & Dock") {
                toggle("Show Flux in the menu bar", \.showInMenuBar,
                       note: "Running downloads, Add Download and Pause All, even with the window closed.")
                toggle("Show progress on the Dock icon", \.showDockProgress)
                LoginItemRow()
            }
            Section("Notifications") {
                toggle("When a download finishes", \.notifyWhenFinished,
                       note: "Downloads that finish together, and whole playlists, come as one notification.")
                toggle("When a download fails", \.notifyOnFailure)
                NotificationStatusRow()
            }
            UpdatesSection()
            Section("Spotlight") {
                toggle("Find finished downloads with Spotlight", \.indexInSpotlight,
                       note: "Search by name, site or playlist; choosing a result shows the download in Flux. The list stays on this Mac.")
            }
            Section {
                ForEach(GlobalShortcutAction.allCases) { action in
                    ShortcutRow(action: action)
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("These work in every app. Use at least two of ⌃ ⌥ ⌘ (or a function key) so they don’t take over other apps’ shortcuts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fluxBackground()
        .fixedSize(horizontal: false, vertical: true)
    }

    private func toggle(_ title: String, _ key: WritableKeyPath<FluxSettings, Bool>, note: String? = nil) -> some View {
        Toggle(isOn: Binding(
            get: { model.settings[keyPath: key] },
            set: { value in model.updateSettings { $0[keyPath: key] = value } }
        )) {
            Text(title)
            if let note { Text(note) }
        }
    }
}

private struct UpdatesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var updater = model.updater
        Section {
            if updater.isAvailable {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                Toggle("Download and install updates automatically", isOn: $updater.automaticallyDownloads)
                    .disabled(!updater.automaticallyChecks)
                HStack {
                    Text(updater.lastChecked.map { "Last checked \($0.formatted(.relative(presentation: .named)))" } ?? "Not checked yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            } else {
                Text("This build of Flux can’t update itself (it has no update feed). Builds made with scripts/release.sh can.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Updates")
        } footer: {
            if updater.isAvailable {
                Text("Updates come from Flux’s GitHub releases and are installed only if they carry Flux’s signature.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LoginItemRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let login = model.loginItem
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { login.isEnabled || login.needsApproval }, set: { login.set($0) })) {
                Text("Open Flux when you log in")
                Text("Scheduled queues and the command line need Flux running.")
            }
            .disabled(!login.isAvailable)
            if login.needsApproval {
                HStack {
                    Label("Switched off in System Settings › Login Items.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Login Items") { login.openSystemSettings() }
                }
                .font(.caption)
            }
            if let error = login.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { login.refresh() }
    }
}

private struct NotificationStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.notificationStatus {
            case .denied:
                HStack {
                    Label("Notifications for Flux are off in System Settings.", systemImage: "bell.slash")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Notifications") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }
            case .notDetermined where model.notifier.isAvailable:
                HStack {
                    Text("macOS asks before the first notification.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow Now") { Task { await model.notifier.requestAuthorization(); model.notifierChanged() } }
                }
            default:
                EmptyView()
            }
        }
        .font(.caption)
        .task { await model.notifier.refreshAuthorization(); model.notifierChanged() }
    }
}

private struct ShortcutRow: View {
    @Environment(AppModel.self) private var model
    let action: GlobalShortcutAction

    var body: some View {
        LabeledContent {
            ShortcutRecorder(combo: model.settings.globalShortcuts[action]) { combo in
                model.updateSettings { settings in
                    if let combo { settings.globalShortcuts = settings.globalShortcuts.filter { $0.value != combo } }
                    settings.globalShortcuts[action] = combo
                }
            }
        } label: {
            Text(action.title)
            if model.unavailableShortcuts.contains(action) {
                Text("Another app already uses this shortcut.").foregroundStyle(.orange)
            }
        }
    }
}

/// Click, then press the new combination. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    let combo: KeyCombo?
    let onChange: (KeyCombo?) -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 4) {
                Button(action: toggleRecording) {
                    Text(recording ? "Type Shortcut…" : combo?.displayString ?? "Record Shortcut")
                        .monospacedDigit()
                        .frame(minWidth: 110)
                }
                .buttonStyle(.bordered)
                .tint(recording ? FluxTheme.accent : nil)
                .help(recording ? "Press the keys, Esc to cancel, Delete to remove" : "Click to change")
                if combo != nil, !recording {
                    Button { onChange(nil) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove shortcut")
                }
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggleRecording() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        hint = nil
        GlobalHotKeys.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch Int(event.keyCode) {
            case 0x35 where flags.isEmpty: // Esc
                stop()
            case 0x33 where flags.isEmpty, 0x75 where flags.isEmpty: // Delete
                onChange(nil)
                stop()
            default:
                let combo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: Self.carbonFlags(flags))
                if combo.isAllowedGlobally {
                    onChange(combo)
                    stop()
                } else {
                    hint = "Add another of ⌃ ⌥ ⌘, e.g. ⌃⌥⌘\(combo.displayString.last.map(String.init) ?? "D")."
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { GlobalHotKeys.shared.resume() }
        recording = false
    }

    static func carbonFlags(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= KeyCombo.command }
        if flags.contains(.shift) { result |= KeyCombo.shift }
        if flags.contains(.option) { result |= KeyCombo.option }
        if flags.contains(.control) { result |= KeyCombo.control }
        return result
    }
}
