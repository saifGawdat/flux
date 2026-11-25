import FluxCore
import SwiftUI

/// Header above a playlist's or gallery's downloads: overall progress and group actions.
/// Clicking it selects the group's downloads, so the toolbar and menus act on all of them.
struct GroupHeaderRow: View {
    @Environment(AppModel.self) private var model
    let group: DownloadGroup
    let members: [DownloadItemModel]
    let isCollapsed: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void

    private var ids: Set<UUID> { Set(members.map(\.id)) }
    private func count(_ match: (DownloadStatus) -> Bool) -> Int { members.reduce(0) { $0 + (match($1.record.status) ? 1 : 0) } }

    private var done: Int { count { $0 == .completed } }
    private var failed: Int { count { $0 == .failed } }
    private var active: Int { count(\.isActive) }
    private var canPause: Bool { members.contains { $0.record.status.canPause } }
    private var canResume: Bool { members.contains { $0.record.status.canResume } }
    private var speed: Double { members.reduce(0) { $0 + $1.bytesPerSecond } }
    private var folder: URL? { members.first?.record.directory }

    /// Finished items count fully; running ones by their own progress.
    private var fraction: Double {
        guard !members.isEmpty else { return 0 }
        let sum = members.reduce(0.0) { total, item in
            total + (item.record.status == .completed ? 1 : (item.record.fractionCompleted ?? 0))
        }
        return sum / Double(members.count)
    }

    private var noun: String {
        let isVideo = group.kind == .playlist
        return isVideo ? (members.count == 1 ? "video" : "videos") : (members.count == 1 ? "file" : "files")
    }

    private var summary: String {
        if done == members.count {
            let size = members.reduce(Int64(0)) { $0 + ($1.record.totalBytes ?? 0) }
            return "\(members.count) \(noun) · \(Format.bytes(size)) · Done"
        }
        var parts = ["\(done) of \(members.count) \(noun) done"]
        if active > 0 { parts.append("\(active) downloading") }
        if speed > 0 { parts.append(Format.speed(speed)) }
        if failed > 0 { parts.append("\(failed) failed") }
        let paused = count { $0 == .paused }
        if paused > 0 && active == 0 { parts.append("\(paused) paused") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(isCollapsed ? "Show downloads" : "Hide downloads")
            .accessibilityLabel(isCollapsed ? "Expand" : "Collapse")

            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: DownloadThumbnail.size.width - 8, height: DownloadThumbnail.size.height)
                    .offset(y: -4)
                if let first = members.first {
                    DownloadThumbnail(item: first)
                } else {
                    Image(systemName: group.kind == .playlist ? "list.and.film" : "photo.on.rectangle")
                }
            }
            .frame(width: DownloadThumbnail.size.width, height: DownloadThumbnail.size.height + 4)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: group.kind == .playlist ? "list.and.film" : "photo.on.rectangle.angled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(group.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if done < members.count {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .tint(failed > 0 && active == 0 ? .red : FluxTheme.accent)
                }
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            actionButton
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(group.title), \(summary)")
    }

    @ViewBuilder
    private var actionButton: some View {
        Group {
            if canPause {
                Button { model.pause(ids) } label: { Image(systemName: "pause.circle.fill") }
                    .help("Pause all")
            } else if canResume {
                Button { model.resume(ids) } label: {
                    Image(systemName: failed > 0 ? "arrow.clockwise.circle.fill" : "play.circle.fill")
                }
                .help(failed > 0 ? "Retry" : "Resume all")
            } else if let folder {
                Button { model.revealFolder(folder) } label: { Image(systemName: "magnifyingglass.circle.fill") }
                    .help("Show in Finder")
            }
        }
        .buttonStyle(.borderless)
        .font(.title2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Select Downloads") { onSelect() }
        if let folder { Button("Show in Finder") { model.revealFolder(folder) } }
        Divider()
        if canResume { Button(failed > 0 ? "Resume / Retry All" : "Resume All") { model.resume(ids) } }
        if canPause { Button("Pause All") { model.pause(ids) } }
        if members.contains(where: { $0.record.status.canCancel }) {
            Button("Cancel All") { model.cancel(ids) }
        }
        Menu("Priority") {
            ForEach(DownloadPriority.allCases.reversed(), id: \.self) { priority in
                Button(priority.title) { model.setPriority(priority, for: ids) }
            }
        }
        Button("Copy Links") { model.copyLinks(ids) }
        Divider()
        Button("Remove from List") { model.remove(ids, trashFiles: false) }
    }
}
