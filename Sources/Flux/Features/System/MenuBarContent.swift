import AppKit
import FluxCore
import SwiftUI

/// Flux's menu bar icon: fills while downloads run.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Image(systemName: model.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
            .accessibilityLabel(model.activeCount > 0 ? "Flux, \(model.activeCount) downloading" : "Flux")
    }
}

/// The menu bar window: what's running, what just finished, and the everyday actions.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    static let runningLimit = 5
    static let finishedLimit = 3

    private var running: [DownloadItemModel] {
        model.current.filter { $0.record.status.isActive || $0.record.status == .paused || $0.record.status == .queued }
            .sorted { rank($0) < rank($1) }
    }

    private var finished: [DownloadItemModel] {
        model.current.filter { $0.record.status == .completed || $0.record.status == .failed }
            .sorted { ($0.record.completedAt ?? $0.record.createdAt) > ($1.record.completedAt ?? $1.record.createdAt) }
    }

    /// Downloading first, then waiting, then paused.
    private func rank(_ item: DownloadItemModel) -> Int {
        switch item.record.status {
        case .downloading, .connecting: 0
        case .queued: 1
        default: 2
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 6)
            let running = running
            if running.isEmpty && finished.isEmpty {
                Text("No downloads")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            ForEach(running.prefix(Self.runningLimit)) { item in
                MenuBarDownloadRow(item: item) { show(item) }
            }
            if running.count > Self.runningLimit {
                MenuBarButton(title: "\(running.count - Self.runningLimit) more…", systemImage: "ellipsis") { showFlux() }
            }
            if !finished.isEmpty {
                Text("Recent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, running.isEmpty ? 0 : 8)
                    .padding(.bottom, 2)
                ForEach(finished.prefix(Self.finishedLimit)) { item in
                    MenuBarDownloadRow(item: item) {
                        if item.record.status == .completed, item.fileExists { model.open(item); dismiss() } else { show(item) }
                    }
                }
            }
            Divider().padding(.vertical, 6)
            actions
        }
        .padding(8)
        .frame(width: 330)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Flux").font(.headline)
            Spacer()
            Text(summary)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }

    private var summary: String {
        let active = model.activeCount
        var parts: [String] = []
        if active > 0 { parts.append("\(active) downloading · \(Format.speed(model.totalSpeed))") }
        if model.queuedCount > 0 { parts.append("\(model.queuedCount) waiting") }
        if let limit = model.settings.effectiveSpeedLimit { parts.append("max \(Format.limit(limit))") }
        return parts.isEmpty ? "Idle" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actions: some View {
        MenuBarButton(title: "Add Download…", systemImage: "plus", shortcut: model.settings.globalShortcuts[.addDownload]) {
            dismiss()
            model.addFromAnywhere()
        }
        if model.downloads.contains(where: { $0.record.status.canPause }) {
            MenuBarButton(title: "Pause All", systemImage: "pause.fill") { model.pauseAll() }
        } else if model.downloads.contains(where: { $0.record.status == .paused }) {
            MenuBarButton(title: "Resume All", systemImage: "play.fill") { model.resumeAll() }
        }
        MenuBarButton(
            title: model.settings.speedLimitEnabled ? "Remove Speed Limit" : "Limit Speed to \(Format.limit(model.settings.speedLimit))",
            systemImage: model.settings.speedLimitEnabled ? "hare" : "tortoise"
        ) { model.toggleGlobalSpeedLimit() }
        Divider().padding(.vertical, 6)
        MenuBarButton(title: "Open Flux", systemImage: "macwindow") { showFlux() }
        SettingsLink {
            MenuBarButtonLabel(title: "Settings…", systemImage: "gearshape")
        }
        .buttonStyle(MenuBarButtonStyle())
        .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
        MenuBarButton(title: "Quit Flux", systemImage: "power") { NSApp.terminate(nil) }
    }

    private func showFlux() {
        dismiss()
        NSApp.activate()
        openWindow(id: "main")
    }

    private func show(_ item: DownloadItemModel) {
        model.focus([item.id])
        showFlux()
    }
}

private struct MenuBarDownloadRow: View {
    let item: DownloadItemModel
    let action: () -> Void

    var body: some View {
        let record = item.record
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                        .frame(width: 14)
                    Text(record.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if record.status != .completed, record.status != .failed {
                    ProgressView(value: record.fractionCompleted ?? 0)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .tint(tint)
                        .padding(.leading, 20)
                }
                Text(detail)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(record.status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .padding(.leading, 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuBarButtonStyle())
        .help(record.status == .completed ? "Open" : "Show in Flux")
    }

    private var icon: String {
        switch item.record.status {
        case .downloading, .connecting: "arrow.down.circle.fill"
        case .queued: "clock"
        case .paused: "pause.circle.fill"
        case .completed: "checkmark.circle.fill"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch item.record.status {
        case .downloading, .connecting: FluxTheme.accent
        case .paused: .orange
        case .completed: .green
        case .failed, .cancelled: .red
        case .queued: .secondary
        }
    }

    private var detail: String {
        let record = item.record
        let amount = record.totalBytes.map { "\(Format.bytes(record.receivedBytes)) of \(Format.bytes($0))" }
            ?? Format.bytes(record.receivedBytes)
        switch record.status {
        case .downloading:
            var text = "\(amount) · \(Format.speed(item.bytesPerSecond))"
            if let left = item.secondsRemaining { text += " · \(Format.duration(left)) left" }
            return text
        case .connecting: return "Connecting…"
        case .queued: return "Waiting · \(amount)"
        case .paused: return "Paused · \(amount)"
        case .completed: return [record.totalBytes.map(Format.bytes), record.completedAt.map { $0.formatted(.relative(presentation: .named)) }]
            .compactMap { $0 }.joined(separator: " · ")
        default: return record.errorMessage ?? "Failed"
        }
    }
}

private struct MenuBarButton: View {
    let title: String
    let systemImage: String
    var shortcut: KeyCombo?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MenuBarButtonLabel(title: title, systemImage: systemImage, shortcut: shortcut)
        }
        .buttonStyle(MenuBarButtonStyle())
    }
}

private struct MenuBarButtonLabel: View {
    let title: String
    let systemImage: String
    var shortcut: KeyCombo?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).frame(width: 14)
            Text(title)
            Spacer()
            if let shortcut {
                Text(shortcut.displayString).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Menu-like rows: highlight under the pointer.
private struct MenuBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuBarButtonBody(configuration: configuration)
    }

    private struct MenuBarButtonBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering || configuration.isPressed ? Color.primary.opacity(0.09) : .clear)
                }
                .onHover { hovering = $0 }
        }
    }
}
