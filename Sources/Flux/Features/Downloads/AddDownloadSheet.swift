import FluxCore
import SwiftUI

struct AddDownloadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var directory: URL?
    @State private var connections: Int?
    @State private var priority: DownloadPriority = .normal
    @State private var startImmediately = true
    @State private var mediaFormat: MediaFormat?

    init(initialText: String) {
        _text = State(initialValue: initialText)
    }

    private var urls: [URL] { LinkExtractor.urls(in: text) }
    private var effectiveDirectory: URL { directory ?? model.settings.downloadDirectory }
    private var hasMediaLinks: Bool { urls.contains(where: MediaRouting.prefersMedia) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .frame(minHeight: 110)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Links")
                } header: {
                    Text("Links")
                } footer: {
                    Text(urls.isEmpty
                         ? "Paste one or more http or https links, one per line."
                         : "\(urls.count) link\(urls.count == 1 ? "" : "s") found")
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Save to") {
                        FolderPickerButton(url: effectiveDirectory) { directory = $0 }
                    }
                    Picker("Connections", selection: Binding(
                        get: { connections ?? model.settings.connectionsPerDownload },
                        set: { connections = $0 }
                    )) {
                        ForEach(FluxSettings.connectionChoices, id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("Priority", selection: $priority) {
                        ForEach(DownloadPriority.allCases.reversed(), id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Start immediately", isOn: $startImmediately)
                }

                Section {
                    Picker("Video format", selection: Binding(
                        get: { mediaFormat ?? model.settings.defaultMediaFormat },
                        set: { mediaFormat = $0 }
                    )) {
                        ForEach(MediaFormat.allCases) { Text($0.title).tag($0) }
                    }
                    if hasMediaLinks && model.mediaTools.ytdlp == nil {
                        MissingToolsNotice()
                    }
                } footer: {
                    Text("Used for YouTube, Vimeo and other pages with video or audio.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(urls.count > 1 ? "Add \(urls.count) Downloads" : "Add Download") {
                    model.add(urls, directory: effectiveDirectory, connections: connections,
                              priority: priority, startImmediately: startImmediately,
                              mediaFormat: mediaFormat)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(urls.isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 540)
    }
}

/// Explains how to enable video downloads when yt-dlp isn't installed.
struct MissingToolsNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Video downloads need yt-dlp", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout.weight(.medium))
            Text("Run this in Terminal, then click Check Again:")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(AppModel.installCommand)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Spacer()
                Button("Copy") { model.copyInstallCommand() }
                Button("Check Again") { model.refreshMediaTools() }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Shows a folder path with a native “Choose…” panel.
struct FolderPickerButton: View {
    let url: URL
    let onPick: (URL) -> Void

    var body: some View {
        HStack {
            Text((url.path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = "Choose"
                panel.directoryURL = url
                if panel.runModal() == .OK, let chosen = panel.url { onPick(chosen) }
            }
        }
    }
}
