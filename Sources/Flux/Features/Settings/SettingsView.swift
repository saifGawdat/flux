import FluxCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            settingsPage {
                Section("Downloads") {
                    LabeledContent("Save downloads to") {
                        FolderPickerButton(url: model.settings.downloadDirectory) { url in
                            model.updateSettings { $0.downloadDirectory = url }
                        }
                    }
                    Toggle("Resume unfinished downloads at launch", isOn: Binding(
                        get: { model.settings.resumeOnLaunch },
                        set: { value in model.updateSettings { $0.resumeOnLaunch = value } }
                    ))
                }
                Section("Connections") {
                    Stepper(
                        "Simultaneous downloads: \(model.settings.maxConcurrentDownloads)",
                        value: Binding(
                            get: { model.settings.maxConcurrentDownloads },
                            set: { value in model.updateSettings { $0.maxConcurrentDownloads = value } }
                        ),
                        in: FluxSettings.concurrentRange)
                    Picker("Connections per download", selection: Binding(
                        get: { model.settings.connectionsPerDownload },
                        set: { value in model.updateSettings { $0.connectionsPerDownload = value } }
                    )) {
                        ForEach(FluxSettings.connectionChoices, id: \.self) { Text("\($0)").tag($0) }
                    }
                    Text("More connections help on fast links to servers that allow them. Flux lowers the count automatically when a server refuses extra connections.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Speed") {
                    Toggle("Limit total download speed", isOn: Binding(
                        get: { model.settings.speedLimitEnabled },
                        set: { value in model.setGlobalSpeedLimit(enabled: value) }
                    ))
                    LabeledContent("All downloads together") {
                        SpeedAmountField(bytesPerSecond: Binding(
                            get: { model.settings.speedLimit },
                            set: { value in model.setGlobalSpeedLimit(enabled: model.settings.speedLimitEnabled, amount: value) }))
                    }
                    .disabled(!model.settings.speedLimitEnabled)
                    Text("Shared by every running download, including videos. Individual downloads can have their own limit too (right-click › Speed Limit). Toggle quickly with ⌥⌘L or from the speed in the status bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            settingsPage {
                Section("Video, Audio & Images") {
                    Picker("Default format", selection: Binding(
                        get: { model.settings.defaultMediaFormat },
                        set: { value in model.updateSettings { $0.defaultMediaFormat = value } }
                    )) {
                        ForEach(MediaFormat.allCases) { Text($0.title).tag($0) }
                    }
                    ToolStatusRow(name: "yt-dlp", purpose: "Finds and downloads media from 1,800+ sites",
                                  url: model.mediaTools.ytdlp, version: model.toolVersions["yt-dlp"])
                    ToolStatusRow(name: "ffmpeg", purpose: "Merges video + audio, converts to MP3/MP4",
                                  url: model.mediaTools.ffmpeg, version: model.toolVersions["ffmpeg"])
                    ToolStatusRow(name: "gallery-dl", purpose: "Image galleries: Instagram, Reddit, Flickr, Tumblr, …",
                                  url: model.mediaTools.galleryDL, version: model.toolVersions["gallery-dl"])
                    if model.mediaTools.ytdlp == nil || model.mediaTools.ffmpeg == nil || model.mediaTools.galleryDL == nil {
                        MissingToolsNotice()
                    } else {
                        Button("Check Again") { model.refreshMediaTools() }
                    }
                }
            }
            .tabItem { Label("Media", systemImage: "play.rectangle") }
            .onAppear { model.refreshMediaTools() }

            OrganizeSettings()
                .tabItem { Label("Organize", systemImage: "folder.badge.gearshape") }
        }
        .frame(width: 540)
        .disabled(model.manager == nil)
    }

    private func settingsPage(@ViewBuilder _ content: () -> some View) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .fluxBackground()
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ToolStatusRow: View {
    let name: String
    let purpose: String
    let url: URL?
    let version: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: url == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(url == nil ? Color.red : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.medium))
                Text(purpose).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(url == nil ? "Not installed" : (version ?? url?.path ?? ""))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
