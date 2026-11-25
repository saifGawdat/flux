import FluxCore
import SwiftUI

/// "Google Search Stories · 13 videos · 23 min", with select all / none.
struct PlaylistHeader: View {
    let playlist: MediaPlaylist
    let selectedCount: Int

    private var summary: String {
        let available = playlist.availableEntries
        var parts = ["\(available.count) video\(available.count == 1 ? "" : "s")"]
        let total = available.compactMap(\.duration).reduce(0, +)
        // "20 min" reads better than "20 min, 2 secs" for a whole playlist.
        if total > 0 { parts.append(Format.duration(total >= 600 ? (total / 60).rounded() * 60 : total)) }
        if let uploader = playlist.uploader, uploader != playlist.title { parts.append(uploader) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(playlist.title).lineLimit(1).truncationMode(.middle)
            Text("\(summary) · \(selectedCount) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// Checkbox list of a playlist's videos, with thumbnails and durations.
struct PlaylistPicker: View {
    let playlist: MediaPlaylist
    @Binding var selection: Set<String>

    var body: some View {
        VStack(spacing: 6) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(playlist.entries.enumerated()), id: \.element.id) { index, entry in
                        PlaylistEntryRow(index: index, entry: entry, isOn: Binding(
                            get: { selection.contains(entry.id) },
                            set: { if $0 { selection.insert(entry.id) } else { selection.remove(entry.id) } }))
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: min(CGFloat(playlist.entries.count) * 36 + 4, 216))
            HStack {
                Spacer()
                Button("Select All") { selection = Set(playlist.availableEntries.map(\.id)) }
                Button("Select None") { selection = [] }
            }
            .controlSize(.small)
        }
    }
}

private struct PlaylistEntryRow: View {
    let index: Int
    let entry: MediaPlaylist.Entry
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 26, alignment: .trailing)
                RemoteThumbnail(urls: thumbnails, size: CGSize(width: 48, height: 27))
                Text(entry.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(entry.isAvailable ? .primary : .tertiary)
                Spacer(minLength: 4)
                if !entry.isAvailable {
                    Text("Unavailable").font(.caption).foregroundStyle(.tertiary)
                } else if let duration = entry.duration {
                    Text(Format.clock(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(height: 32)
        }
        .toggleStyle(.checkbox)
        .disabled(!entry.isAvailable)
    }

    private var thumbnails: [URL] {
        var urls: [URL] = []
        if let youTube = Thumbnails.youTube(for: entry.url) { urls.append(youTube) }
        if let own = entry.thumbnailURL { urls.append(own) }
        return urls
    }
}

/// Grid of found images; click to include or leave out.
struct ImagePicker: View {
    static let cell = CGSize(width: 100, height: 75)

    let items: [ImageCollection.Item]
    @Binding var selection: Set<Int>
    /// Reports the real pixel size of an image once its preview loads.
    let onMeasured: (Int, CGSize) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cell.width, maximum: Self.cell.width + 20), spacing: 8)], spacing: 8) {
                ForEach(items) { item in
                    ImagePickerCell(item: item, isSelected: selection.contains(item.id), onMeasured: onMeasured) {
                        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
                    }
                }
            }
            .padding(4)
        }
        .frame(height: items.count > 10 ? 260 : (items.count > 5 ? 172 : 88))
        .overlay {
            if items.isEmpty {
                Text("All images here are small. Turn off “Hide small images” to see them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

private struct ImagePickerCell: View {
    let item: ImageCollection.Item
    let isSelected: Bool
    let onMeasured: (Int, CGSize) -> Void
    let onToggle: () -> Void
    @State private var image: NSImage?
    @State private var failed = false
    @State private var measured: CGSize?

    var body: some View {
        Button(action: onToggle) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if item.isVideo || failed {
                    Image(systemName: item.isVideo ? "play.rectangle" : "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: ImagePicker.cell.width, height: ImagePicker.cell.height)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? FluxTheme.accent : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 0.5)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? FluxTheme.accent : .white)
                    .background(Circle().fill(isSelected ? .white : .black.opacity(0.3)).padding(1))
                    .padding(4)
            }
            .overlay(alignment: .bottomLeading) {
                if item.isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(4)
                }
            }
            .opacity(isSelected ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .help(caption)
        .accessibilityLabel(caption)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: item.url) {
            guard !item.isVideo else { return }
            let loaded = await ThumbnailLoader.shared.image(localFile: nil, remote: [item.url], size: ImagePicker.cell)
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
            if let size = ThumbnailLoader.shared.pixelSize(of: item.url) {
                measured = size
                onMeasured(item.id, size)
            }
        }
    }

    /// "beach.jpg · 4000 × 3000 · 2.5 MB"
    private var caption: String {
        var parts = [item.fileName ?? item.url.lastPathComponent]
        let width = item.width ?? measured.map { Int($0.width) }
        let height = item.height ?? measured.map { Int($0.height) }
        if let width, let height { parts.append("\(width) × \(height)") }
        if let bytes = item.bytes { parts.append(Format.bytes(bytes)) }
        return parts.joined(separator: " · ")
    }
}

/// A small remote picture (playlist thumbnails), via the shared thumbnail cache.
struct RemoteThumbnail: View {
    let urls: [URL]
    let size: CGSize
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .task(id: urls) {
            let loaded = await ThumbnailLoader.shared.image(localFile: nil, remote: urls, size: size)
            if !Task.isCancelled { image = loaded }
        }
    }
}
