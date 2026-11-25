// Renders the Flux app icon from code (see docs/BRAND.md → Logo).
//
//   swift scripts/make-icon.swift            → Resources/Brand/AppIcon-1024.png + Flux.icns
//
// The mark: an "F" assembled from download chunks on the halftone sky. Each chunk is a
// piece of the file arriving over its own connection; the last chunk (bottom of the stem)
// is still filling, top to bottom: a download in progress, moving down.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let brand = root.appendingPathComponent("Resources/Brand")

// MARK: Palette (mirrors Sources/Flux/Theme/FluxTheme.swift)

func rgb(_ hex: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let ink = 0x2D57D5, cloud = 0xECF9FE, sky = 0x5D80D8, deepInk = 0x1C3A9E

// MARK: Geometry (in a 1024 × 1024 canvas, y pointing down)

/// macOS icon grid: the body is 824 pt inside a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

/// The F on a 3 × 5 grid of chunks. `fill` = how much of the chunk has arrived.
struct Chunk { let col: Int, row: Int, fill: CGFloat }
let chunks: [Chunk] = [
    .init(col: 0, row: 0, fill: 1), .init(col: 1, row: 0, fill: 1), .init(col: 2, row: 0, fill: 1),
    .init(col: 0, row: 1, fill: 1),
    .init(col: 0, row: 2, fill: 1), .init(col: 1, row: 2, fill: 1),
    .init(col: 0, row: 3, fill: 1),
    .init(col: 0, row: 4, fill: 0.55),
]

// MARK: Rendering

func loadSky() -> CGImage {
    let url = brand.appendingPathComponent("sky-halftone.jpg")
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("missing \(url.path)") }
    return img
}

/// `detailed` = halftone sky + gapped chunks; small sizes get a flat gradient instead,
/// because halftone dots turn to mush below ~64 px (BRAND.md, requirement 3).
func render(px: Int, detailed: Bool, sky skyImage: CGImage) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(px) / 1024
    ctx.scaleBy(x: k, y: -k)                 // work in 1024 units, y down
    ctx.translateBy(x: 0, y: -1024)
    ctx.interpolationQuality = .high

    // macOS Big Sur+ icon corner radius ≈ 22.4 % of the body.
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Body drop shadow (macOS template: soft, slightly below).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 28 * k, color: rgb(0x000000, 0.30))
    ctx.addPath(shape); ctx.setFillColor(rgb(ink)); ctx.fillPath()
    ctx.restoreGState()

    // Background.
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    if detailed {
        // 1:1 crop (no resampling, so the halftone dots stay crisp, no moiré): open blue
        // sky behind the F, cumulus tops rising along the bottom. Image coords: y down.
        let crop = skyImage.cropping(to: CGRect(x: 0, y: 0, width: 1024, height: 1024))!
        ctx.saveGState()
        ctx.translateBy(x: 0, y: 1024)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        ctx.restoreGState()
        // Deepen the centre (multiply keeps the dot texture, just tints the clouds blue)
        // so the white F reads clearly; the corners keep the full sky.
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        let veil = CGGradient(colorsSpace: space, colors: [rgb(ink, 0.80), rgb(ink, 0.45), rgb(ink, 0)] as CFArray,
                              locations: [0, 0.55, 1])!
        ctx.drawRadialGradient(veil, startCenter: CGPoint(x: 500, y: 512), startRadius: 0,
                               endCenter: CGPoint(x: 500, y: 512), endRadius: 560, options: [])
        ctx.restoreGState()
    } else {
        let g = CGGradient(colorsSpace: space, colors: [rgb(sky), rgb(ink)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: body.minY), end: CGPoint(x: 512, y: body.maxY), options: [])
    }
    // Gentle top highlight, like light on glass.
    let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: body.minY), end: CGPoint(x: 512, y: 470), options: [])
    ctx.restoreGState()

    // The F.
    let cell: CGFloat = detailed ? 104 : 112
    let gap: CGFloat = detailed ? 18 : max(10, 1.2 / k)       // keep ≥ ~1 px of gap
    let radius: CGFloat = detailed ? 22 : 10
    let w = 3 * cell + 2 * gap, h = 5 * cell + 4 * gap
    let origin = CGPoint(x: 512 - w / 2 + 14, y: 512 - h / 2)  // nudged right: optical centre
    func rect(_ c: Chunk) -> CGRect {
        CGRect(x: origin.x + CGFloat(c.col) * (cell + gap), y: origin.y + CGFloat(c.row) * (cell + gap),
               width: cell, height: cell)
    }

    // Shadow layer under all chunks, so the mark lifts off the busy halftone.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * k), blur: 34 * k, color: rgb(0x0A1C5C, 0.55))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    for c in chunks {
        let r = rect(c)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(rgb(cloud, c.fill < 1 ? 0.28 : 1)); ctx.fillPath()   // track for the live chunk
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // The chunk still arriving: filled from the top down, with a bright leading edge.
    for c in chunks where c.fill < 1 {
        let r = rect(c)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.setFillColor(rgb(cloud)); ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * c.fill))
        if detailed {
            // Track outline so the empty part still reads as part of the F.
            ctx.restoreGState(); ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 3, dy: 3), cornerWidth: radius - 3, cornerHeight: radius - 3, transform: nil))
            ctx.setStrokeColor(rgb(cloud, 0.85)); ctx.setLineWidth(6); ctx.strokePath()
        }
        ctx.restoreGState()
    }

    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

// MARK: Output

let skyImage = loadSky()
writePNG(render(px: 1024, detailed: true, sky: skyImage), brand.appendingPathComponent("AppIcon-1024.png"))

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Flux.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = pt * scale
        let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        writePNG(render(px: px, detailed: px >= 64, sky: skyImage), iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", brand.appendingPathComponent("Flux.icns").path]
try iconutil.run(); iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
// Small-size preview for checking legibility.
writePNG(render(px: 32, detailed: false, sky: skyImage), brand.appendingPathComponent("AppIcon-32.png"))
print("Wrote Resources/Brand/AppIcon-1024.png, AppIcon-32.png, Flux.icns")
