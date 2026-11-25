import AppKit
import SwiftUI

/// Flux brand: a halftone blue sky with white cumulus clouds (see docs/BRAND.md).
enum FluxTheme {
    /// Halftone ink — the dominant blue of the sky image.
    static let inkHex = 0x2D57D5
    /// Paper — the white of the clouds.
    static let cloudHex = 0xECF9FE
    /// The blended look of ink and paper at viewing distance.
    static let skyHex = 0x5D80D8

    static let ink = Color(hex: inkHex)
    static let cloud = Color(hex: cloudHex)
    static let sky = Color(hex: skyHex)

    /// Accent for controls and progress: ink in light mode, lifted toward sky in dark
    /// mode so it keeps contrast against dark backgrounds.
    static let accent = Color(nsColor: NSColor(name: "FluxAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(hex: 0x6F92F2)
            : NSColor(hex: inkHex)
    })

    /// Background image opacity: subtle enough that text stays easy to read.
    static func backgroundOpacity(for scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.22 : 0.16
    }

    /// The sky image. In the app bundle it lives in Contents/Resources; during
    /// development (`swift run`) it is read from the repository.
    static let skyImage: NSImage? = {
        if let url = Bundle.main.url(forResource: "sky-halftone", withExtension: "jpg") {
            return NSImage(contentsOf: url)
        }
        let repoCopy = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Brand/sky-halftone.jpg")
        return NSImage(contentsOf: repoCopy)
    }()
}

/// The faded halftone sky behind Flux's content.
struct SkyBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Color fills exactly the offered space; the image fills it via an overlay so its
        // aspect-fill overflow never changes the layout size.
        Color(nsColor: .windowBackgroundColor)
            .overlay {
                if let image = FluxTheme.skyImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .opacity(FluxTheme.backgroundOpacity(for: colorScheme))
                }
            }
            .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Puts the sky behind a scrolling container (List/Form) and lets it show through.
    func fluxBackground() -> some View {
        scrollContentBackground(.hidden)
            .background { SkyBackground() }
    }
}

extension Color {
    init(hex: Int) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}
