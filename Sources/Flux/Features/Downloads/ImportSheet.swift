import FluxCore
import SwiftUI
import UniformTypeIdentifiers

/// Confirms an import: how many links, a preview, and where they go.
struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ImportRequest
    @State private var queue: UUID?
    @State private var startImmediately = true

    private var known: Int {
        let urls = Set(model.current.map(\.record.url))
        return request.entries.filter { urls.contains($0.url) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(request.entries.prefix(5), id: \.url) { entry in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.fileName ?? entry.url.lastPathComponent.removingPercentEncoding ?? entry.url.absoluteString)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(entry.url.host() ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if request.entries.count > 5 {
                        Text("and \(request.entries.count - 5) more")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("\(request.entries.count) link\(request.entries.count == 1 ? "" : "s") in “\(request.fileName)”")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if known > 0 {
                            Text("\(known) of these \(known == 1 ? "is" : "are") already in your list; importing adds \(known == 1 ? "it" : "them") again.")
                        }
                        if request.entries.contains(where: { $0.directory != nil }) {
                            Text("Folders named in the file are used when they’re in your home folder or on an external drive; the rest go to your download folder. Folders like Library or hidden ones are never used.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Section {
                    QueuePicker(selection: $queue)
                    Toggle("Start immediately", isOn: $startImmediately)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add \(request.entries.count) Download\(request.entries.count == 1 ? "" : "s")") {
                    model.importLinks(request.entries, queue: queue, startImmediately: startImmediately)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .fluxBackground()
    }
}

/// File-menu panels for importing and exporting lists of links.
@MainActor
enum LinkListPanels {
    static let importTypes: [UTType] = [.plainText, .commaSeparatedText, .json, .tabSeparatedText]

    static func importLinks(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.title = "Import Links"
        panel.message = "Choose a text, CSV or JSON file with links."
        panel.allowedContentTypes = importTypes
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.openMainWindow?()
        model.importLinks(from: url)
    }

    static func export(_ model: AppModel, format: LinkListFormat) {
        let panel = NSSavePanel()
        panel.title = "Export Downloads"
        panel.nameFieldStringValue = "Flux Downloads.\(format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        let includeHistory = NSButton(checkboxWithTitle: "Include History", target: nil, action: nil)
        includeHistory.state = .off
        let accessory = NSStackView(views: [includeHistory])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.export(to: url, format: format, includeHistory: includeHistory.state == .on)
    }
}
