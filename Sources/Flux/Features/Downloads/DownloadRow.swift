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
            DownloadThumbnail(item: item)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(record.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if record.kind == .media {
                        Image(systemName: record.mediaFormat?.isAudioOnly == true ? "music.note" : "play.rectangle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(record.mediaFormat?.title ?? "Media")
                    }
                    if record.priority != .normal, record.status != .completed {
                        PriorityBadge(priority: record.priority)
                    }
                    if record.status == .completed { VerificationBadge(record: record) }
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
        case .downloading, .connecting: FluxTheme.accent
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
            return item.detail ?? "Connecting to \(host)…"
        case .downloading:
            if let detail = item.detail, item.bytesPerSecond == 0 { return detail }
            var parts = [record.totalBytes == nil && record.kind == .file ? "\(amount) (size unknown)" : amount,
                         Format.speed(item.bytesPerSecond)]
            if let limit = record.speedLimit { parts[1] += " (limit \(Format.limit(limit)))" }
            if let eta = item.secondsRemaining { parts.append("\(Format.duration(eta)) left") }
            if item.activeConnections > 1 { parts.append("\(item.activeConnections) connections") }
            if let detail = item.detail { parts.append(detail) }
            return parts.joined(separator: " · ")
        case .paused:
            let note = record.kind == .file && record.receivedBytes > 0 && !record.supportsRanges
                ? " · server can’t resume, will restart" : ""
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
                if canContinueFromNewLink {
                    Button("Update Link…") { model.showInfo(item.id, editLink: true) }
                        .font(.callout)
                        .help("Continue this download from a fresh link")
                }
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

extension DownloadRow {
    /// A failed file download with data worth keeping: a fresh link can pick it up.
    var canContinueFromNewLink: Bool {
        record.status == .failed && record.kind == .file && record.receivedBytes > 0 && record.supportsRanges
    }
}

/// Seal on finished downloads: checksum verified or not, or the size matched the server's.
struct VerificationBadge: View {
    let record: DownloadRecord

    var body: some View {
        switch record.checksumState {
        case .verified:
            badge("checkmark.seal.fill", .green, "\(record.checksum!.algorithm.title) checksum verified")
        case .mismatch:
            badge("xmark.seal.fill", .red, "The file doesn't match the expected \(record.checksum!.algorithm.title) checksum")
        case .none, .pending:
            if record.sizeVerified, let total = record.totalBytes {
                badge("checkmark.seal", .secondary, "Size matches what the server stated (\(Format.exactBytes(total)))")
            }
        }
    }

    private func badge(_ symbol: String, _ color: Color, _ help: String) -> some View {
        Image(systemName: symbol)
            .font(.caption)
            .foregroundStyle(color)
            .help(help)
            .accessibilityLabel(help)
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
