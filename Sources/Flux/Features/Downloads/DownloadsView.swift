import FluxCore
import QuickLook
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

/// What the sidebar shows: a status filter, a kind of file, or History.
enum SidebarItem: Hashable {
    case status(StatusFilter)
    case category(FileCategory)
    /// nil = the main queue.
    case queue(UUID?)
    case history
    case statistics
}

struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var sidebar: SidebarItem? = .status(.all)
    @State private var selection = Set<UUID>()
    @State private var search = ""
    /// Selection to apply once the sidebar switch (which clears selection) has happened.
    @State private var pendingSelection: Set<UUID>?

    private var visible: [DownloadItemModel] {
        model.current.filter { item in
            let shown = switch sidebar ?? .status(.all) {
            case .status(let filter): filter.matches(item.record.status)
            case .category(let category): item.record.category == category
            case .queue(let id): item.record.queueID == id
            case .history, .statistics: false
            }
            return shown && (search.isEmpty || item.record.matches(search))
        }
    }

    private var selected: [DownloadItemModel] { model.downloads.filter { selection.contains($0.id) } }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $sidebar) {
                Section("Downloads") {
                    ForEach(StatusFilter.allCases) { f in
                        Label(f.title, systemImage: f.systemImage)
                            .badge(model.current.lazy.filter { f.matches($0.record.status) }.count)
                            .tag(SidebarItem.status(f))
                    }
                }
                let counts = Dictionary(grouping: model.current, by: \.record.category).mapValues(\.count)
                if !counts.isEmpty {
                    Section("Kinds") {
                        ForEach(FileCategory.allCases.filter { counts[$0] != nil }) { category in
                            Label(category.title, systemImage: category.systemImage)
                                .badge(counts[category] ?? 0)
                                .tag(SidebarItem.category(category))
                        }
                    }
                }
                Section {
                    if model.settings.queues.isEmpty {
                        Button { model.queueEditor = QueueEditorRequest() } label: {
                            Label("New Queue…", systemImage: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("A queue holds downloads until you start it, or until its scheduled time")
                    } else {
                        Label("Main", systemImage: "tray")
                            .badge(model.current.lazy.filter { $0.record.queueID == nil && $0.record.status != .completed }.count)
                            .tag(SidebarItem.queue(nil))
                        ForEach(model.settings.queues) { queue in
                            QueueSidebarRow(queue: queue).tag(SidebarItem.queue(queue.id))
                        }
                    }
                } header: {
                    HStack {
                        Text("Queues")
                        Spacer()
                        if !model.settings.queues.isEmpty {
                            Button { model.queueEditor = QueueEditorRequest() } label: { Image(systemName: "plus") }
                                .buttonStyle(.borderless)
                                .help("New queue")
                        }
                    }
                }
                Section {
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .badge(model.history.count)
                        .tag(SidebarItem.history)
                    Label("Statistics", systemImage: "chart.bar.xaxis")
                        .tag(SidebarItem.statistics)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } detail: {
            Group {
                if sidebar == .history {
                    HistoryView(search: search, selection: $selection)
                } else if sidebar == .statistics {
                    StatisticsView()
                } else {
                    DownloadList(items: visible, selection: $selection, emptyFilter: statusFilter,
                                 category: category, isSearching: !search.isEmpty, inQueue: isQueue)
                        .safeAreaInset(edge: .top, spacing: 0) {
                            if case .queue(let id?) = sidebar, let queue = model.queue(id) {
                                QueueHeaderBar(queue: queue)
                            }
                        }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        }
        .onChange(of: sidebar) {
            selection = pendingSelection ?? []
            pendingSelection = nil
        }
        .modifier(FocusAndPreview(selection: selection, show: show))
        .onChange(of: model.settings.queues.map(\.id)) { _, ids in
            // The shown queue was deleted.
            if case .queue(let id?) = sidebar, !ids.contains(id) { sidebar = .status(.all) }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search downloads")
        .toolbar { toolbar }
        // In full screen macOS hosts the toolbar in its own strip with an opaque backdrop
        // that covers the top of the floating sidebar. Hide it so the sidebar and sky run
        // up under the toolbar, as they do in a normal window.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .sheet(item: $model.addSheet) { request in
            AddDownloadSheet(initialText: request.text)
        }
        .sheet(item: $model.infoSheet) { request in
            DownloadInfoSheet(request: request)
        }
        .sheet(item: $model.importSheet) { request in
            ImportSheet(request: request)
        }
        .sheet(item: $model.queueEditor) { request in
            QueueEditor(queue: request.queue)
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
        // The main action stands on its own, in Flux Blue.
        ToolbarItem(placement: .primaryAction) {
            Button { model.presentAddSheet() } label: { Label("Add", systemImage: "plus") }
                .help("Add download (⌘N)")
                .prominentToolbarStyle()
        }
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.resume(selection) } label: { Label("Resume", systemImage: "play.fill") }
                .help("Resume or retry selected")
                .disabled(!selected.contains { $0.record.status.canResume })
            Button { model.pause(selection) } label: { Label("Pause", systemImage: "pause.fill") }
                .help("Pause selected")
                .disabled(!selected.contains { $0.record.status.canPause })
            Button { model.cancel(selection) } label: { Label("Cancel", systemImage: "xmark") }
                .help("Cancel selected and delete partial data")
                .disabled(!selected.contains { $0.record.status.canCancel })
            Button {
                if let id = selection.first { model.showInfo(id) }
            } label: { Label("Info", systemImage: "info.circle") }
                .help("Link, mirrors, checksum and speed limit (⌘I)")
                .keyboardShortcut("i")
                .disabled(selection.count != 1)
        }
    }

    /// Selects downloads, switching to History or back to the list as needed.
    private func show(_ ids: Set<UUID>) {
        let items = model.downloads.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        search = ""
        let target: SidebarItem = items.allSatisfy(\.record.isArchived) ? .history : .status(.all)
        if sidebar == target {
            selection = Set(items.filter { $0.record.isArchived == (target == .history) }.map(\.id))
        } else {
            pendingSelection = Set(items.filter { $0.record.isArchived == (target == .history) }.map(\.id))
            sidebar = target
        }
    }

    private var statusFilter: StatusFilter {
        if case .status(let filter) = sidebar { return filter }
        return .all
    }

    private var category: FileCategory? {
        if case .category(let category) = sidebar { return category }
        return nil
    }

    private var isQueue: Bool {
        if case .queue = sidebar { return true }
        return false
    }

    private var subtitle: String {
        let active = model.activeCount
        guard active > 0 else { return "\(model.current.count) downloads" }
        return "\(active) active · \(Format.speed(model.totalSpeed))"
    }
}

/// Spotlight / notification / menu bar requests to show downloads, and Quick Look.
private struct FocusAndPreview: ViewModifier {
    @Environment(AppModel.self) private var model
    let selection: Set<UUID>
    let show: (Set<UUID>) -> Void

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .onChange(of: model.focusRequest, initial: true) { _, request in
                guard let request else { return }
                model.focusRequest = nil
                show(request.downloads)
            }
            .focusedSceneValue(\.downloadSelection, selection)
            .quickLookPreview($model.quickLookURL, in: model.quickLookURLs)
    }
}

struct DownloadList: View {
    @Environment(AppModel.self) private var model
    let items: [DownloadItemModel]
    @Binding var selection: Set<UUID>
    let emptyFilter: StatusFilter
    var category: FileCategory? = nil
    let isSearching: Bool
    var inQueue = false
    /// Groups the user opened or closed (big groups start closed, small ones open).
    @State private var toggledGroups: Set<UUID> = []

    private enum Row: Identifiable {
        case header(DownloadGroup, members: [DownloadItemModel])
        case item(DownloadItemModel, inGroup: Bool)

        var id: String {
            switch self {
            case .header(let group, _): "group-" + group.id.uuidString
            case .item(let item, _): item.id.uuidString
            }
        }
    }

    static let collapseAbove = 12

    private func isCollapsed(_ group: DownloadGroup, count: Int) -> Bool {
        // While filtering or searching, show the matches instead of hiding them.
        guard emptyFilter == .all, category == nil, !inQueue, !isSearching else { return false }
        return (count > Self.collapseAbove) != toggledGroups.contains(group.id)
    }

    /// Consecutive downloads of one playlist/gallery get a header; members follow it.
    private var rows: [Row] {
        var rows: [Row] = []
        var index = 0
        while index < items.count {
            let item = items[index]
            guard let group = item.record.group else {
                rows.append(.item(item, inGroup: false))
                index += 1
                continue
            }
            var end = index
            while end < items.count, items[end].record.group?.id == group.id { end += 1 }
            let members = model.members(of: group.id)
            rows.append(.header(group, members: members))
            if !isCollapsed(group, count: members.count) {
                rows += items[index..<end].map { .item($0, inGroup: true) }
            }
            index = end
        }
        return rows
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(rows) { row in
                switch row {
                case .header(let group, let members):
                    GroupHeaderRow(
                        group: group, members: members,
                        isCollapsed: isCollapsed(group, count: members.count),
                        onToggle: { toggledGroups.formSymmetricDifference([group.id]) },
                        onSelect: { selection = Set(members.map(\.id)) })
                case .item(let item, let inGroup):
                    DownloadRow(item: item)
                        .padding(.leading, inGroup ? 22 : 0)
                        .tag(item.id)
                }
            }
        }
        .listStyle(.inset)
        .fluxBackground()
        .overlay { if items.isEmpty { emptyState } }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty { DownloadContextMenu(ids: ids) }
        } primaryAction: { ids in
            for id in ids {
                guard let item = model.item(id) else { continue }
                if item.record.status == .completed { model.open(item) } else { model.reveal(item) }
            }
        }
        .onDeleteCommand { model.remove(selection, trashFiles: false) }
        .onKeyPress(.space) {
            guard model.quickLookURL != nil || model.canQuickLook(selection) else { return .ignored }
            model.quickLook(selection)
            return .handled
        }
        .dropDestination(for: URL.self) { urls, _ in
            let links = urls.filter(LinkExtractor.isDownloadable)
            guard !links.isEmpty else { return false }
            // A single page might be a playlist or hold images: let the add sheet show the choices.
            if links.count == 1, let link = links.first, LinkInspector.shouldInspect(link) {
                model.presentAddSheet(prefill: link.absoluteString)
            } else {
                model.add(links)
            }
            return true
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isSearching {
            ContentUnavailableView.search
        } else if let category {
            ContentUnavailableView("No \(category.title)", systemImage: category.systemImage)
        } else if inQueue {
            ContentUnavailableView {
                Label("Queue Is Empty", systemImage: "tray")
            } description: {
                Text("Choose this queue when adding downloads, or right-click downloads › Queue.")
            }
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
            if single.previewFile != nil {
                Button("Quick Look") { model.quickLook([single.id]) }
            }
            Button("Get Info") { model.showInfo(single.id) }
            if single.record.status != .completed {
                Button("Update Link…") { model.showInfo(single.id, editLink: true) }
            }
            if let extracted = single.record.extractedPath {
                Button("Show Extracted Files") { model.reveal(extracted) }
            } else if single.fileExists, let file = single.record.finalPath, ArchiveExtractor.canExtract(file) {
                Button("Extract") { model.extract(single.id) }
            }
            if let original = single.record.duplicateOf {
                Button("Show Existing Copy") { model.reveal(original) }
            }
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
        let unfinished = targets.filter { $0.record.status != .completed }
        if !unfinished.isEmpty {
            Menu("Priority") {
                ForEach(DownloadPriority.allCases.reversed(), id: \.self) { priority in
                    Button(priority.title) { model.setPriority(priority, for: ids) }
                }
            }
            let limits = Set(unfinished.map(\.record.speedLimit))
            SpeedLimitMenu(ids: Set(unfinished.map(\.id)), current: limits.count == 1 ? limits.first : nil)
            MoveToQueueMenu(ids: Set(unfinished.map(\.id)))
        }
        if targets.contains(where: { $0.record.status == .failed }), targets.count > 1 {
            Button("Retry Failed") { model.resume(Set(targets.filter { $0.record.status == .failed }.map(\.id))) }
        }
        Button(targets.count == 1 ? "Copy Link" : "Copy Links") { model.copyLinks(ids) }
        Divider()
        if targets.contains(where: { [.completed, .failed, .cancelled].contains($0.record.status) }) {
            Button("Move to History") { model.archive(ids) }
        }
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
            if model.failedCount > 0 {
                Button("Retry Failed (\(model.failedCount))") { model.retryFailed() }
            }
            Button("Resume All") { model.resumeAll() }
            Button("Pause All") { model.pauseAll() }
            GlobalSpeedMenu()
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

/// The total speed in the status bar; click it to set a limit for all downloads.
struct GlobalSpeedMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let limit = model.settings.effectiveSpeedLimit
        Menu {
            Toggle("No Limit", isOn: Binding(
                get: { limit == nil },
                set: { _ in model.setGlobalSpeedLimit(enabled: false) }))
            Divider()
            ForEach(FluxSettings.speedLimitPresets, id: \.self) { preset in
                Toggle("Limit to \(Format.limit(preset))", isOn: Binding(
                    get: { limit == preset },
                    set: { _ in model.setGlobalSpeedLimit(enabled: true, amount: preset) }))
            }
            Divider()
            SettingsLink { Text("Custom Limit…") }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: limit == nil ? "arrow.down" : "tortoise.fill")
                Text(Format.speed(model.totalSpeed))
                if let limit {
                    Text("/ \(Format.limit(limit))").foregroundStyle(.tertiary)
                }
            }
            .monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(minWidth: 90, alignment: .trailing)
        .help(limit == nil ? "Total speed. Click to limit it." : "All downloads together are limited to \(Format.limit(limit))")
    }
}

private extension View {
    /// Tinted glass on macOS 26, a filled accent button before that.
    @ViewBuilder
    func prominentToolbarStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent).tint(FluxTheme.accent)
        } else {
            buttonStyle(.borderedProminent).tint(FluxTheme.accent)
        }
    }
}
