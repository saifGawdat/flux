import AppKit
import FluxCore
import SwiftUI
import UniformTypeIdentifiers

struct DownloadRow: View {
    @Environment(AppModel.self) private var model
    let item: DownloadItemModel

    private var record: DownloadRecord { item.record }

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(item: item)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(record.fileName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if record.priority != .normal, record.status != .completed {
                        PriorityBadge(priority: record.priority)
                    }
                }
                if record.status != .completed {
                    progress
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(record.status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            actionButton
        }
        .padding(.vertical, 5)
        .help(record.url.absoluteString)
    }

    @ViewBuilder
    private var progress: some View {
        if record.totalBytes == nil && record.status.isActive {
            ProgressView().progressViewStyle(.linear).controlSize(.small)
        } else {
            SegmentBar(record: record, tint: tint).frame(height: 6)
        }
    }

    private var tint: Color {
        switch record.status {
        case .downloading, .connecting: .accentColor
        case .failed: .red
        case .paused: .orange
        default: .secondary
        }
    }

    private var detail: String {
        let received = Format.bytes(record.receivedBytes)
        let amount = record.totalBytes.map { "\(received) of \(Format.bytes($0))" } ?? received
        let percent = record.fractionCompleted.map { " (\(Int($0 * 100))%)" } ?? ""
        let host = record.sourceHost
        switch record.status {
        case .queued:
            return "Queued · \(host)" + (record.receivedBytes > 0 ? " · \(amount)" : "")
        case .connecting:
            return "Connecting to \(host)…"
        case .downloading:
            var parts = [amount, Format.speed(item.bytesPerSecond)]
            if let eta = item.secondsRemaining { parts.append("\(Format.duration(eta)) left") }
            if item.activeConnections > 1 { parts.append("\(item.activeConnections) connections") }
            return parts.joined(separator: " · ")
        case .paused:
            let note = record.receivedBytes > 0 && !record.supportsRanges ? " · server can’t resume, will restart" : ""
            return "Paused · \(amount)\(percent)\(note)"
        case .completed:
            let size = Format.bytes(record.totalBytes ?? record.receivedBytes)
            let date = record.completedAt?.formatted(date: .abbreviated, time: .shortened) ?? ""
            return item.fileExists ? "\(size) · \(host) · \(date)" : "\(size) · File moved or deleted"
        case .failed:
            return "Failed: \(record.errorMessage ?? "Unknown error")"
        case .cancelled:
            return "Cancelled · \(host)"
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        Group {
            switch record.status {
            case .downloading, .connecting, .queued:
                Button { model.pause([item.id]) } label: { Image(systemName: "pause.circle.fill") }
                    .help("Pause")
            case .paused:
                Button { model.resume([item.id]) } label: { Image(systemName: "play.circle.fill") }
                    .help("Resume")
            case .failed, .cancelled:
                Button { model.resume([item.id]) } label: { Image(systemName: "arrow.clockwise.circle.fill") }
                    .help("Retry")
            case .completed:
                Button { model.reveal(item) } label: { Image(systemName: "magnifyingglass.circle.fill") }
                    .help("Show in Finder")
            }
        }
        .buttonStyle(.borderless)
        .font(.title2)
        .foregroundStyle(.secondary)
    }
}

struct PriorityBadge: View {
    let priority: DownloadPriority

    var body: some View {
        Text(priority.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(priority == .high ? Color.orange.opacity(0.18) : Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(priority == .high ? Color.orange : Color.secondary)
    }
}

/// Progress bar showing each connection's segment as it fills in.
struct SegmentBar: View {
    let record: DownloadRecord
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
            context.fill(track, with: .color(.secondary.opacity(0.18)))
            guard let total = record.totalBytes, total > 0 else { return }
            context.clip(to: track)
            let scale = size.width / CGFloat(total)
            for segment in record.segments where segment.received > 0 {
                let rect = CGRect(
                    x: CGFloat(segment.start) * scale, y: 0,
                    width: max(1, CGFloat(segment.received) * scale), height: size.height)
                context.fill(Path(rect), with: .color(tint))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Download progress")
        .accessibilityValue("\(Int((record.fractionCompleted ?? 0) * 100)) percent")
    }
}

struct FileIcon: View {
    let item: DownloadItemModel

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }

    private var icon: NSImage {
        if item.record.status == .completed, let path = item.record.finalPath, item.fileExists {
            return NSWorkspace.shared.icon(forFile: path.path)
        }
        let ext = (item.record.fileName as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}
