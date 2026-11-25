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
    @State private var inspection: InspectionState = .idle
    @State private var choice: Choice = .video
    @State private var playlistSelection: Set<String> = []
    @State private var imageSelection: Set<Int> = []
    @State private var hideSmallImages = true
    /// Images whose loaded preview turned out to be icon-sized.
    @State private var smallImages: Set<Int> = []
    @State private var useFolder = true

    enum InspectionState {
        case idle
        case loading
        case loaded(URL, LinkInspection)
    }

    /// What to download from a link that offers more than one thing.
    enum Choice: Hashable {
        case video, playlist, images
    }

    init(initialText: String) {
        _text = State(initialValue: initialText)
    }

    private var urls: [URL] { LinkExtractor.urls(in: text) }
    private var effectiveDirectory: URL { directory ?? model.settings.downloadDirectory }
    private var effectiveFormat: MediaFormat { mediaFormat ?? model.settings.defaultMediaFormat }
    private var hasMediaLinks: Bool { urls.contains(where: MediaRouting.prefersMedia) }

    /// A single page link is looked at before adding (video sizes, playlists, images).
    private var inspectURL: URL? {
        guard urls.count == 1, let url = urls.first, LinkInspector.shouldInspect(url) else { return nil }
        return url
    }

    /// The inspection result, if it belongs to the link currently entered.
    private var found: LinkInspection? {
        guard case .loaded(let url, let result) = inspection, url == inspectURL else { return nil }
        return result
    }

    private var choices: [Choice] {
        guard let found else { return [] }
        var list: [Choice] = []
        if found.media?.video != nil { list.append(.video) }
        if let playlist = found.media?.playlist, !playlist.entries.isEmpty { list.append(.playlist) }
        if let images = found.images, !images.items.isEmpty { list.append(.images) }
        return list
    }

    private var activeChoice: Choice? { choices.contains(choice) ? choice : choices.first }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                linksSection
                if choices.count > 1 { choicePicker }
                switch activeChoice {
                case .video: videoSection
                case .playlist: playlistSection
                case .images: imagesSection
                case nil: if hasMediaLinks || isLoading { plainFormatSection }
                }
                saveSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .task(id: inspectURL) { await inspect() }

            HStack {
                if case .images = activeChoice, found?.images?.source == .page, model.mediaTools.galleryDL == nil {
                    Text("Tip: install gallery-dl for full galleries from Instagram, Reddit, Flickr and 100+ more sites.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(addTitle) {
                    model.add(requests)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(requests.isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 600)
        .background { SkyBackground() }
        .tint(FluxTheme.accent)
    }

    // MARK: Sections

    private var isLoading: Bool {
        if case .loading = inspection { return inspectURL != nil }
        return false
    }

    private var linksSection: some View {
        Section {
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Links")
        } header: {
            Text("Links")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                        Text("Looking for videos and images…")
                    } else {
                        Text(urls.isEmpty
                             ? "Paste one or more http or https links, one per line."
                             : "\(urls.count) link\(urls.count == 1 ? "" : "s") found")
                    }
                }
                .foregroundStyle(.secondary)
                if let problem = found?.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if hasMediaLinks && model.mediaTools.ytdlp == nil {
                    MissingToolsNotice()
                }
            }
        }
    }

    private var choicePicker: some View {
        Section {
            Picker("Download", selection: Binding(get: { activeChoice ?? .video }, set: { choice = $0 })) {
                ForEach(choices, id: \.self) { Text(title(for: $0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func title(for choice: Choice) -> String {
        switch choice {
        case .video:
            return found?.media?.playlist != nil ? "This Video" : "Video"
        case .playlist:
            return "Playlist · \(found?.media?.playlist?.availableEntries.count ?? 0)"
        case .images:
            let images = found?.images
            let count = images?.items.count ?? 0
            return (images?.imageCount ?? 0) == 0 ? "Videos · \(count)" : "Images · \(count)"
        }
    }

    @ViewBuilder
    private var videoSection: some View {
        if let video = found?.media?.video {
            Section {
                LabeledContent("Video") {
                    Text(video.duration.map { "\(video.title) · \(Format.clock($0))" } ?? video.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                formatPicker(sizes: video)
            } footer: {
                Text(qualityFootnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var playlistSection: some View {
        if let playlist = found?.media?.playlist {
            Section {
                PlaylistPicker(playlist: playlist, selection: $playlistSelection)
                formatPicker(sizes: nil)
            } header: {
                PlaylistHeader(playlist: playlist, selectedCount: selectedEntries(of: playlist).count)
            } footer: {
                Text(playlist.isTruncated
                     ? "Only the first 1,000 videos are listed. \(qualityFootnote)"
                     : "Each video is downloaded on its own, \(model.settings.maxConcurrentDownloads) at a time. \(qualityFootnote)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var imagesSection: some View {
        if let images = found?.images {
            let visible = visibleImages(images)
            Section {
                ImagePicker(
                    items: visible, selection: $imageSelection,
                    onMeasured: { id, size in
                        if min(size.width, size.height) < CGFloat(ImageCollection.smallImageLimit) { smallImages.insert(id) }
                    })
                HStack {
                    Text("\(selectedImages(of: images).count) of \(visible.count) selected")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    if images.source == .page {
                        Toggle("Hide small images", isOn: $hideSmallImages)
                            .toggleStyle(.checkbox)
                    }
                    Button("All") { imageSelection.formUnion(visible.map(\.id)) }
                    Button("None") { imageSelection.subtract(visible.map(\.id)) }
                }
                .controlSize(.small)
                if images.items.contains(where: \.needsMediaExtractor) {
                    formatPicker(sizes: nil)
                }
            } header: {
                Text(images.title).lineLimit(1).truncationMode(.middle)
            } footer: {
                Text(imagesFootnote(images)).foregroundStyle(.secondary)
            }
        }
    }

    /// Format choice for links that will go to yt-dlp, when no single link was inspected.
    private var plainFormatSection: some View {
        Section {
            formatPicker(sizes: nil)
        } footer: {
            Text("Used for YouTube, Vimeo and other pages with video or audio.")
                .foregroundStyle(.secondary)
        }
    }

    private var saveSection: some View {
        Section {
            LabeledContent("Save to") {
                FolderPickerButton(url: effectiveDirectory) { directory = $0 }
            }
            if let folder = groupTitle {
                Toggle("Put them in a folder named “\(FileNaming.sanitize(folder))”", isOn: $useFolder)
            }
            if usesFileEngine {
                Picker("Connections", selection: Binding(
                    get: { connections ?? model.settings.connectionsPerDownload },
                    set: { connections = $0 }
                )) {
                    ForEach(FluxSettings.connectionChoices, id: \.self) { Text("\($0)").tag($0) }
                }
            }
            Picker("Priority", selection: $priority) {
                ForEach(DownloadPriority.allCases.reversed(), id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Start immediately", isOn: $startImmediately)
        }
    }

    private func formatPicker(sizes: MediaPreview?) -> some View {
        Picker(selection: Binding(get: { effectiveFormat }, set: { mediaFormat = $0 })) {
            ForEach(MediaFormat.allCases) { Text(label(for: $0, sizes: sizes)).tag($0) }
        } label: {
            Text(activeChoice == .playlist ? "Format for all videos" : "Format")
        }
    }

    private var qualityFootnote: String {
        effectiveFormat == .mp4_2160 || effectiveFormat == .mp4_1440
            ? "Above 1080p most sites only offer VP9 or AV1 video, which some older players can't open."
            : ""
    }

    private func imagesFootnote(_ images: ImageCollection) -> String {
        var parts: [String] = []
        switch images.source {
        case .gallery:
            if images.isTruncated { parts.append("Only the first 500 files are listed.") }
        case .page:
            parts.append("Images in the page. Pictures a site loads later while you scroll aren't included.")
        }
        if images.videoCount > 0 { parts.append("Videos are saved alongside the images.") }
        return parts.joined(separator: " ")
    }

    // MARK: What gets added

    /// The playlist or gallery title, when several items will be added together.
    private var groupTitle: String? {
        switch activeChoice {
        case .playlist:
            guard let playlist = found?.media?.playlist, selectedEntries(of: playlist).count > 1 else { return nil }
            return playlist.title
        case .images:
            guard let images = found?.images, selectedImages(of: images).count > 1 else { return nil }
            return images.title
        default:
            return nil
        }
    }

    /// Connections only matter to Flux's own engine (files and images), not yt-dlp.
    private var usesFileEngine: Bool {
        switch activeChoice {
        case .video, .playlist: false
        case .images: true
        case nil: urls.contains { !MediaRouting.prefersMedia($0) }
        }
    }

    private func selectedEntries(of playlist: MediaPlaylist) -> [MediaPlaylist.Entry] {
        playlist.entries.filter { $0.isAvailable && playlistSelection.contains($0.id) }
    }

    private func visibleImages(_ images: ImageCollection) -> [ImageCollection.Item] {
        guard images.source == .page, hideSmallImages else { return images.items }
        return images.items.filter { !$0.isSmall && !smallImages.contains($0.id) }
    }

    private func selectedImages(of images: ImageCollection) -> [ImageCollection.Item] {
        visibleImages(images).filter { imageSelection.contains($0.id) }
    }

    private var requests: [DownloadManager.NewDownload] {
        let folder = groupTitle.flatMap { useFolder ? effectiveDirectory.appendingPathComponent(FileNaming.sanitize($0), isDirectory: true) : nil }
        let directory = folder ?? effectiveDirectory
        guard let url = inspectURL, let found, let choice = activeChoice else {
            return urls.map {
                DownloadManager.NewDownload(
                    url: $0, directory: effectiveDirectory, connections: connections, priority: priority,
                    startImmediately: startImmediately, mediaFormat: mediaFormat)
            }
        }
        switch choice {
        case .video:
            return [DownloadManager.NewDownload(
                url: url, directory: directory, priority: priority, startImmediately: startImmediately,
                kind: .media, mediaFormat: effectiveFormat, title: found.media?.video?.title)]
        case .playlist:
            guard let playlist = found.media?.playlist else { return [] }
            let entries = selectedEntries(of: playlist)
            let group = entries.count > 1 ? DownloadGroup(title: playlist.title, kind: .playlist) : nil
            return entries.enumerated().map { index, entry in
                DownloadManager.NewDownload(
                    url: entry.url, directory: directory, priority: priority, startImmediately: startImmediately,
                    kind: .media, mediaFormat: effectiveFormat, title: entry.title, thumbnailURL: entry.thumbnailURL,
                    group: group, groupIndex: index)
            }
        case .images:
            guard let images = found.images else { return [] }
            let items = selectedImages(of: images)
            let group = items.count > 1 ? DownloadGroup(title: images.title, kind: .images) : nil
            return items.enumerated().map { index, item in
                DownloadManager.NewDownload(
                    url: item.url, directory: directory, fileName: item.fileName, connections: connections,
                    priority: priority, startImmediately: startImmediately,
                    kind: item.needsMediaExtractor ? .media : .file,
                    mediaFormat: item.needsMediaExtractor ? effectiveFormat : nil,
                    referer: images.pageURL, group: group, groupIndex: index)
            }
        }
    }

    private var addTitle: String {
        let count = requests.count
        guard count > 1 else { return "Add Download" }
        switch activeChoice {
        case .playlist: return "Download \(count) Videos"
        case .images:
            let allImages = found?.images.map { selectedImages(of: $0).allSatisfy { !$0.isVideo } } ?? false
            return "Download \(count) \(allImages ? "Images" : "Files")"
        default: return "Add \(count) Downloads"
        }
    }
}

extension AddDownloadSheet {
    /// "1080p MP4 — 155.2 MB", plus the real resolution when the video is smaller than
    /// the preset (or for Best quality).
    func label(for format: MediaFormat, sizes: MediaPreview?) -> String {
        guard let option = sizes?.options[format] else { return format.title }
        var parts: [String] = []
        if let height = option.height {
            if format == .best {
                parts.append("\(height)p")
            } else if let cap = format.maxHeight, height < cap {
                parts.append("only \(height)p available")
            }
        }
        if let bytes = option.bytes {
            parts.append((option.isEstimate ? "≈ " : "") + Format.bytes(bytes))
        }
        return parts.isEmpty ? format.title : "\(format.title) — \(parts.joined(separator: " · "))"
    }

    func inspect() async {
        guard let url = inspectURL else {
            inspection = .idle
            return
        }
        if case .loaded(let current, _) = inspection, current == url { return }
        // Wait for typing/pasting to settle before hitting the network.
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        inspection = .loading
        let result = await model.inspect(url)
        guard !Task.isCancelled else { return }
        inspection = .loaded(url, result)
        choice = Self.defaultChoice(for: result)
        playlistSelection = Set(result.media?.playlist?.availableEntries.map(\.id) ?? [])
        imageSelection = Set(result.images?.items.map(\.id) ?? [])
        smallImages = []
    }

    /// A playlist link opens on the playlist; a video opened from a playlist on that video;
    /// a picture site's gallery on its images.
    static func defaultChoice(for result: LinkInspection) -> Choice {
        if let images = result.images, images.source == .gallery, images.imageCount > 0 { return .images }
        if result.media?.video != nil { return .video }
        if result.media?.playlist != nil { return .playlist }
        return .images
    }
}

/// Explains how to enable video and gallery downloads when the tools aren't installed.
struct MissingToolsNotice: View {
    @Environment(AppModel.self) private var model

    private var headline: String {
        let tools = model.mediaTools
        if tools.ytdlp == nil { return "Video downloads need yt-dlp" }
        if tools.ffmpeg == nil { return "ffmpeg is needed for the best video quality and MP3" }
        return "Install gallery-dl for image galleries"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(headline, systemImage: "exclamationmark.triangle.fill")
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
