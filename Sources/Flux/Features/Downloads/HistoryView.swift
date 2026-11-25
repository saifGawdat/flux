import FluxCore
import SwiftUI

/// Downloads cleared from the list, grouped by day. Files on disk are never touched here
/// unless the user explicitly moves one to the Trash.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    let search: String
    @Binding var selection: Set<UUID>
    @State private var confirmClear = false

    private var entries: [DownloadItemModel] {
        model.history.filter { search.isEmpty || $0.record.matches(search) }
    }

    /// (title, items) per day, newest first.
    private var days: [(title: String, items: [DownloadItemModel])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { item in
            calendar.startOfDay(for: item.record.completedAt ?? item.record.createdAt)
        }
        return grouped.keys.sorted(by: >).map { day in
            let title = if calendar.isDateInToday(day) { "Today" }
                else if calendar.isDateInYesterday(day) { "Yesterday" }
                else { day.formatted(date: .complete, time: .omitted) }
            return (title, grouped[day] ?? [])
        }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(days, id: \.title) { day in
                Section(day.title) {
                    ForEach(day.items) { item in
                        DownloadRow(item: item).tag(item.id)
                    }
                }
            }
        }
        .listStyle(.inset)
        .fluxBackground()
        .overlay {
            if entries.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView {
                        Label("No History", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("Finished downloads move here when you choose Clear Completed.")
                    }
                } else {
                    ContentUnavailableView.search
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !model.history.isEmpty {
                HStack {
                    Text("\(model.history.count) download\(model.history.count == 1 ? "" : "s") in History")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History…") { confirmClear = true }
                }
                .font(.callout)
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty { HistoryContextMenu(ids: ids) }
        } primaryAction: { ids in
            for id in ids {
                if let item = model.item(id) { item.fileExists ? model.open(item) : model.reveal(item) }
            }
        }
        .onDeleteCommand { model.remove(selection, trashFiles: false) }
        .confirmationDialog("Clear all History?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("Flux forgets these downloads. The files stay where they are.")
        }
    }
}

struct HistoryContextMenu: View {
    @Environment(AppModel.self) private var model
    let ids: Set<UUID>

    var body: some View {
        let targets = model.downloads.filter { ids.contains($0.id) }
        if let single = targets.first, targets.count == 1 {
            Button("Open") { model.open(single) }.disabled(!single.fileExists)
            Button("Show in Finder") { model.reveal(single) }
            Button("Get Info") { model.showInfo(single.id) }
            Divider()
        }
        Button("Download Again") { model.downloadAgain(ids) }
        Button(targets.count == 1 ? "Copy Link" : "Copy Links") { model.copyLinks(ids) }
        Divider()
        Button("Remove from History") { model.remove(ids, trashFiles: false) }
        if targets.contains(where: \.fileExists) {
            Button("Move File to Trash", role: .destructive) { model.remove(ids, trashFiles: true) }
        }
    }
}
