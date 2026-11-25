import FluxCore
import SwiftUI

/// Details and engine settings for one download: its link (and replacing an expired one),
/// mirrors, checksum, size check, priority and speed limit.
struct DownloadInfoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: InfoSheetRequest

    private var item: DownloadItemModel? { model.item(request.download) }

    var body: some View {
        VStack(spacing: 0) {
            if let item {
                DownloadInfoForm(item: item, startEditingLink: request.editLink)
            } else {
                ContentUnavailableView("Download Removed", systemImage: "questionmark.folder")
                    .frame(height: 200)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 560)
        .background { SkyBackground() }
        .tint(FluxTheme.accent)
    }
}

private struct DownloadInfoForm: View {
    @Environment(AppModel.self) private var model
    let item: DownloadItemModel
    let startEditingLink: Bool

    @State private var isEditingLink = false
    @State private var newLink = ""
    @State private var linkCheck: LinkCheck = .idle
    @State private var mirrorsText = ""
    @State private var isEditingMirrors = false
    @State private var checksumText = ""
    @State private var checksumNote: String?
    @State private var isChecking = false
    @State private var digest: String?
    @State private var isHashing = false

    enum LinkCheck: Equatable {
        case idle, checking
        case found(RemoteFileInfo)
        case failed(String)
    }

    private var record: DownloadRecord { item.record }
    private var isFile: Bool { record.kind == .file }
    private var isFinished: Bool { record.status == .completed }

    var body: some View {
        Form {
            header
            linkSection
            if isFile, !isFinished || !record.mirrors.isEmpty { mirrorsSection }
            fileSection
            if isFile || isFinished { checksumSection }
            if !isFinished { transferSection }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: 640)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            isEditingLink = startEditingLink && !isFinished
            mirrorsText = record.mirrors.map(\.absoluteString).joined(separator: "\n")
            isEditingMirrors = !record.mirrors.isEmpty
            checksumText = record.checksum?.hex ?? ""
        }
    }

    // MARK: Header

    private var header: some View {
        Section {
            HStack(spacing: 12) {
                DownloadThumbnail(item: item)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.displayName)
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(record.status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(3)
                }
            }
        }
    }

    private var statusLine: String {
        switch record.status {
        case .failed: "Failed: \(record.errorMessage ?? "Unknown error")"
        case .completed: "Finished " + (record.completedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")
        case .downloading: "Downloading · \(Format.speed(item.bytesPerSecond))"
        default: record.status.rawValue.capitalized
        }
    }

    // MARK: Link

    @ViewBuilder
    private var linkSection: some View {
        Section {
            LabeledContent("Link") {
                Text(record.url.absoluteString)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            if let referer = record.referer {
                LabeledContent("Found on") {
                    Text(referer.absoluteString).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
            }
            if isEditingLink {
                newLinkEditor
            } else if !isFinished {
                HStack {
                    Spacer()
                    Button("Change Link…") {
                        newLink = ""
                        linkCheck = .idle
                        isEditingLink = true
                    }
                }
            }
        } header: {
            Text("Source")
        } footer: {
            if isEditingLink {
                Text(isFile
                     ? "Paste a fresh link to the same file (for example after the old one expired). Flux keeps what it has downloaded when the new link serves the same file."
                     : "Paste a new link to the same video or page.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var newLinkEditor: some View {
        let url = LinkExtractor.urls(in: newLink).first
        TextField("New link", text: $newLink, prompt: Text("https://…"))
            .onChange(of: newLink) { linkCheck = .idle }
            .task(id: url) { await check(url) }
        if let message = linkCheckMessage(for: url) {
            Label(message.text, systemImage: message.icon)
                .font(.callout)
                .foregroundStyle(message.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        HStack {
            Spacer()
            Button("Cancel") { isEditingLink = false }
            Button("Use New Link") {
                guard let url else { return }
                model.updateLink(item.id, to: url)
                isEditingLink = false
            }
            .disabled(url == nil || url == record.url || linkCheck == .checking)
        }
    }

    private func check(_ url: URL?) async {
        guard isFile, let url, url != record.url else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        linkCheck = .checking
        do {
            let info = try await RemoteFileProbe.probe(url, referer: record.referer)
            if !Task.isCancelled { linkCheck = .found(info) }
        } catch {
            if !Task.isCancelled { linkCheck = .failed(error.localizedDescription) }
        }
    }

    private func linkCheckMessage(for url: URL?) -> (text: String, icon: String, isProblem: Bool)? {
        guard let url else {
            return newLink.isEmpty ? nil : ("That isn't an http or https link.", "exclamationmark.triangle", true)
        }
        if url == record.url { return ("That's the current link.", "info.circle", false) }
        switch linkCheck {
        case .idle: return nil
        case .checking: return ("Checking the link…", "hourglass", false)
        case .failed(let message): return (message, "exclamationmark.triangle", true)
        case .found(let info):
            if info.isWebPage {
                return ("This link opens a web page, not the file.", "exclamationmark.triangle", true)
            }
            let size = info.totalBytes.map(Format.bytes) ?? "unknown size"
            guard record.receivedBytes > 0 else { return ("Found the file: \(size).", "checkmark.circle", false) }
            if info.canContinue(expectedBytes: record.totalBytes) {
                let percent = Int((record.fractionCompleted ?? 0) * 100)
                return ("Same file size (\(size)). The download continues from \(percent)%.", "checkmark.circle", false)
            }
            if let total = record.totalBytes, let found = info.totalBytes, found != total {
                return ("This link has a different file (\(size), expected \(Format.bytes(total))). Flux will start over.",
                        "exclamationmark.triangle", true)
            }
            return ("This server can't resume downloads, so Flux will start over.", "exclamationmark.triangle", true)
        }
    }

    // MARK: Mirrors

    private var parsedMirrors: [URL] { LinkExtractor.urls(in: mirrorsText) }

    @ViewBuilder
    private var mirrorsSection: some View {
        Section {
            if isEditingMirrors {
                TextEditor(text: $mirrorsText)
                    .font(.callout.monospaced())
                    .frame(minHeight: 44, maxHeight: 90)
                    .scrollContentBackground(.hidden)
                    .disabled(isFinished)
                    .accessibilityLabel("Mirror links")
                if !isFinished {
                    HStack {
                        Text(parsedMirrors.isEmpty ? "One link per line" : "\(parsedMirrors.count) mirror\(parsedMirrors.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Save Mirrors") { model.setMirrors(parsedMirrors, for: item.id) }
                            .disabled(parsedMirrors == record.mirrors)
                    }
                    .controlSize(.small)
                }
            } else {
                LabeledContent("Mirrors") {
                    Button("Add Mirrors…") { isEditingMirrors = true }
                }
            }
        } header: {
            if isEditingMirrors { Text("Mirrors") }
        } footer: {
            if isEditingMirrors {
                Text("Other links to exactly the same file. Flux spreads connections across all links and keeps going if one fails. A mirror with a different file is ignored.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: File

    private var fileSection: some View {
        Section("File") {
            LabeledContent("Saved to") {
                HStack {
                    Text(((record.finalPath ?? record.directory).path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Show") { model.reveal(item) }
                        .controlSize(.small)
                }
            }
            LabeledContent("Size") {
                Text(record.totalBytes.map(Format.exactBytes) ?? "Not known yet")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
            if let filedBy = record.filedBy {
                LabeledContent("Organized") { Text(DownloadRow.filedText(filedBy)).foregroundStyle(.secondary) }
            }
            if let note = record.automationNote {
                LabeledContent("Rule actions") { Text(note).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if let duplicate = record.duplicateOf {
                LabeledContent("Duplicate of") {
                    HStack {
                        Text((duplicate.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.orange)
                        Button("Show") { model.reveal(duplicate) }.controlSize(.small)
                    }
                }
            }
            if let extracted = record.extractedPath {
                LabeledContent("Extracted to") {
                    HStack {
                        Text(extracted.lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Show") { model.reveal(extracted) }.controlSize(.small)
                    }
                }
            } else if let problem = record.extractionError {
                LabeledContent("Extraction") {
                    HStack {
                        Text(problem).foregroundStyle(.orange).lineLimit(2)
                        Button("Try Again") { model.extract(item.id) }.controlSize(.small)
                    }
                }
            }
            if isFile {
                LabeledContent("Size check") {
                    Label(sizeCheck.text, systemImage: sizeCheck.icon)
                        .foregroundStyle(sizeCheck.color)
                }
            }
        }
    }

    private var sizeCheck: (text: String, icon: String, color: Color) {
        if isFinished {
            return record.sizeVerified
                ? ("Matches the size the server stated", "checkmark.seal.fill", .green)
                : ("The server didn't state a size to check", "questionmark.circle", .secondary)
        }
        return record.totalBytes == nil
            ? ("The server hasn't stated a size", "questionmark.circle", .secondary)
            : ("Checked when the download finishes", "clock", .secondary)
    }

    // MARK: Checksum

    private var enteredChecksum: Checksum? { Checksum.parse(checksumText) }

    private var checksumSection: some View {
        Section {
            LabeledContent("Expected") {
                TextField("Expected", text: $checksumText, prompt: Text("Paste a SHA-256, SHA-1, SHA-512 or MD5"))
                    .labelsHidden()
                    .font(.callout.monospaced())
                    .multilineTextAlignment(.trailing)
                    .onChange(of: checksumText) { checksumNote = nil }
            }
            HStack(spacing: 8) {
                checksumStatus
                Spacer()
                if isChecking { ProgressView().controlSize(.small) }
                if record.checksum != nil {
                    Button("Remove") { save(nil) }
                }
                Button(isFinished ? "Verify" : "Save") { save(enteredChecksum) }
                    .disabled(enteredChecksum == nil || isChecking || (enteredChecksum == record.checksum && !isFinished))
            }
            .controlSize(.small)
            if isFinished, item.fileExists {
                HStack {
                    if let digest {
                        Text(digest)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(digest, forType: .string)
                        }
                    } else {
                        Text("SHA-256 of the file").foregroundStyle(.secondary)
                        Spacer()
                        if isHashing { ProgressView().controlSize(.small) }
                        Button("Calculate") { calculateDigest() }.disabled(isHashing)
                    }
                }
                .controlSize(.small)
            }
        } header: {
            Text("Checksum")
        } footer: {
            Text(isFinished
                 ? "Compare the file with the checksum published by its source."
                 : "When the download finishes, Flux checks the file against this checksum before saving it. A file that doesn't match is discarded.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var checksumStatus: some View {
        if let checksumNote {
            Text(checksumNote).foregroundStyle(.orange)
        } else if !checksumText.isEmpty, enteredChecksum == nil {
            Text("Not a recognized checksum").foregroundStyle(.orange)
        } else {
            switch record.checksumState {
            case .none:
                Text(enteredChecksum.map { "\($0.algorithm.title)" } ?? "None").foregroundStyle(.secondary)
            case .pending:
                Label("\(record.checksum!.algorithm.title) · checked when finished", systemImage: "clock")
                    .foregroundStyle(.secondary)
            case .verified:
                Label("\(record.checksum!.algorithm.title) matches", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            case .mismatch:
                Label("\(record.checksum!.algorithm.title) doesn't match", systemImage: "xmark.seal.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private func save(_ checksum: Checksum?) {
        isChecking = true
        checksumNote = nil
        Task {
            do {
                _ = try await model.setChecksum(checksum, for: item.id)
                if checksum == nil { checksumText = "" }
            } catch {
                checksumNote = error.localizedDescription
            }
            isChecking = false
        }
    }

    private func calculateDigest() {
        guard let file = record.finalPath else { return }
        isHashing = true
        Task {
            digest = try? await Checksum.digest(of: file, algorithm: .sha256)
            isHashing = false
        }
    }

    // MARK: Transfer

    private var transferSection: some View {
        Section("Transfer") {
            Picker("Priority", selection: Binding(
                get: { record.priority },
                set: { model.setPriority($0, for: [item.id]) }
            )) {
                ForEach(DownloadPriority.allCases.reversed(), id: \.self) { Text($0.title).tag($0) }
            }
            SpeedLimitPicker(title: "Speed limit", limit: Binding(
                get: { record.speedLimit },
                set: { model.setSpeedLimit($0, for: [item.id]) }))
            if let global = model.settings.effectiveSpeedLimit {
                Text("All downloads together are also limited to \(Format.limit(global)) (Settings).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isFile {
                LabeledContent("Connections") {
                    Text("Up to \(record.maxConnections)").foregroundStyle(.secondary)
                }
            }
        }
    }
}
