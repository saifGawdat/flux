import FluxCore
import SwiftUI

enum StatusFilter: String, CaseIterable, Identifiable, Hashable {
    case all, active, queued, paused, completed, failed

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .all: "tray.full"
        case .active: "arrow.down.circle"
        case .queued: "clock"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    func matches(_ status: DownloadStatus) -> Bool {
        switch self {
        case .all: true
        case .active: status.isActive
        case .queued: status == .queued
        case .paused: status == .paused
        case .completed: status == .completed
        case .failed: status == .failed || status == .cancelled
        }
    }
}

struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: StatusFilter? = .all
    @State private var selection = Set<UUID>()
    @State private var search = ""

    private var visible: [DownloadItemModel] {
        let filter = filter ?? .all
        return model.downloads.filter { item in
            filter.matches(item.record.status)
                && (search.isEmpty
                    || item.record.fileName.localizedCaseInsensitiveContains(search)
                    || item.record.url.absoluteString.localizedCaseInsensitiveContains(search))
        }
    }

    private var selected: [DownloadItemModel] { model.downloads.filter { selection.contains($0.id) } }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $filter) {
                Section("Downloads") {
                    ForEach(StatusFilter.allCases) { f in
                        Label(f.title, systemImage: f.systemImage)
                            .badge(model.downloads.lazy.filter { f.matches($0.record.status) }.count)
                            .tag(f)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } detail: {
            DownloadList(items: visible, selection: $selection, emptyFilter: filter ?? .all, isSearching: !search.isEmpty)
                .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search downloads")
        .toolbar { toolbar }
        .sheet(item: $model.addSheet) { request in
            AddDownloadSheet(initialText: request.text)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .navigationTitle("Flux")
        .navigationSubtitle(subtitle)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.presentAddSheet() } label: { Label("Add", systemImage: "plus") }
                .help("Add download (⌘N)")
            Button { model.resume(selection) } label: { Label("Resume", systemImage: "play.fill") }
                .help("Resume or retry selected")
                .disabled(!selected.contains { $0.record.status.canResume })
            Button { model.pause(selection) } label: { Label("Pause", systemImage: "pause.fill") }
                .help("Pause selected")
                .disabled(!selected.contains { $0.record.status.canPause })
            Button { model.cancel(selection) } label: { Label("Cancel", systemImage: "xmark") }
                .help("Cancel selected and delete partial data")
                .disabled(!selected.contains { $0.record.status.canCancel })
        }
    }

    private var subtitle: String {
        let active = model.activeCount
        guard active > 0 else { return "\(model.downloads.count) downloads" }
        return "\(active) active · \(Format.speed(model.totalSpeed))"
    }
}

struct DownloadList: View {
    @Environment(AppModel.self) private var model
    let items: [DownloadItemModel]
    @Binding var selection: Set<UUID>
    let emptyFilter: StatusFilter
    let isSearching: Bool

    var body: some View {
        List(selection: $selection) {
            ForEach(items) { item in
                DownloadRow(item: item).tag(item.id)
            }
        }
        .listStyle(.inset)
        .fluxBackground()
        .overlay { if items.isEmpty { emptyState } }
        .contextMenu(forSelectionType: UUID.self) { ids in
            DownloadContextMenu(ids: ids)
        } primaryAction: { ids in
            for id in ids {
                guard let item = model.item(id) else { continue }
                if item.record.status == .completed { model.open(item) } else { model.reveal(item) }
            }
        }
        .onDeleteCommand { model.remove(selection, trashFiles: false) }
        .dropDestination(for: URL.self) { urls, _ in
            let links = urls.filter(LinkExtractor.isDownloadable)
            guard !links.isEmpty else { return false }
            model.add(links)
            return true
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isSearching {
            ContentUnavailableView.search
        } else if emptyFilter == .all {
            ContentUnavailableView {
                Label("No Downloads Yet", systemImage: "icloud.and.arrow.down")
            } description: {
                Text("Add a link with ⌘N, or drag one onto this window.")
            } actions: {
                Button("Add Download…") { model.presentAddSheet() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView("Nothing \(emptyFilter.title)", systemImage: emptyFilter.systemImage)
        }
    }
}

struct DownloadContextMenu: View {
    @Environment(AppModel.self) private var model
    let ids: Set<UUID>

    var body: some View {
        let targets = model.downloads.filter { ids.contains($0.id) }
        if let single = targets.first, targets.count == 1 {
            if single.record.status == .completed {
                Button("Open") { model.open(single) }.disabled(!single.fileExists)
            }
            Button("Show in Finder") { model.reveal(single) }
            Divider()
        }
        if targets.contains(where: { $0.record.status.canResume }) {
            Button(targets.allSatisfy { $0.record.status == .paused } ? "Resume" : "Retry") { model.resume(ids) }
        }
        if targets.contains(where: { $0.record.status.canPause }) {
            Button("Pause") { model.pause(ids) }
        }
        if targets.contains(where: { $0.record.status.canCancel }) {
            Button("Cancel Download") { model.cancel(ids) }
        }
        if targets.contains(where: { $0.record.status != .completed }) {
            Menu("Priority") {
                ForEach(DownloadPriority.allCases.reversed(), id: \.self) { priority in
                    Button(priority.title) { model.setPriority(priority, for: ids) }
                }
            }
        }
        Button(targets.count == 1 ? "Copy Link" : "Copy Links") { model.copyLinks(ids) }
        Divider()
        Button("Remove from List") { model.remove(ids, trashFiles: false) }
        if targets.contains(where: { $0.record.status == .completed && $0.fileExists }) {
            Button("Move File to Trash", role: .destructive) { model.remove(ids, trashFiles: true) }
        }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Text("\(model.activeCount) active · \(model.queuedCount) queued")
            Spacer()
            Button("Resume All") { model.resumeAll() }
            Button("Pause All") { model.pauseAll() }
            Label(Format.speed(model.totalSpeed), systemImage: "arrow.down")
                .monospacedDigit()
                .frame(minWidth: 90, alignment: .trailing)
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
