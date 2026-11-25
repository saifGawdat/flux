import AppKit
import FluxCore

/// A progress bar across the bottom of the Dock icon while downloads run.
@MainActor
final class DockProgress {
    private var view: DockProgressView?
    /// Whole percent last drawn; redrawn only when it changes.
    private var shown: Int?

    func update(_ fraction: Double?) {
        let percent = fraction.map { Int(($0 * 100).rounded(.down)) }
        guard percent != shown, let app = NSApp else { return }
        shown = percent
        let tile = app.dockTile
        if let percent {
            let view = self.view ?? DockProgressView()
            self.view = view
            view.fraction = Double(percent) / 100
            if tile.contentView !== view { tile.contentView = view }
        } else {
            tile.contentView = nil
            view = nil
        }
        tile.display()
    }
}

final class DockProgressView: NSView {
    var fraction = 0.0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let inset = bounds.width * 0.12
        let height = max(8, bounds.height * 0.1)
        let track = NSRect(x: inset, y: bounds.height * 0.1, width: bounds.width - inset * 2, height: height)
        let radius = height / 2
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        let inner = track.insetBy(dx: 1.5, dy: 1.5)
        let filled = NSRect(x: inner.minX, y: inner.minY, width: max(inner.height, inner.width * fraction), height: inner.height)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: filled, xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
    }
}
