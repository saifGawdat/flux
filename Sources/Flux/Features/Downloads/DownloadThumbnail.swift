import AppKit
import FluxCore
import ImageIO
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// What a download looks like: the real content when we can get it (a finished file's
/// QuickLook preview, or the video's thumbnail while it downloads), else its file-type icon.
struct DownloadThumbnail: View {
    static let size = CGSize(width: 64, height: 40)

    let item: DownloadItemModel
    @State private var preview: NSImage?

    private var record: DownloadRecord { item.record }

    private var localFile: URL? { record.status == .completed && item.fileExists ? record.finalPath : nil }

    /// Re-run loading only when something that changes the picture changes.
    private var key: String {
        (localFile?.path ?? "") + "|" + record.previewImageURLs.map(\.absoluteString).joined(separator: " ")
    }

    /// Cached image shows on the first frame (no flicker when rows scroll back into view).
    private var shown: NSImage? {
        preview ?? ThumbnailLoader.shared.cachedImage(localFile: localFile, remote: record.previewImageURLs)
    }

    var body: some View {
        ZStack {
            if let preview = shown {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.size.width, height: Self.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                    }
                    .overlay(alignment: .bottomTrailing) { mediaBadge }
                    .transition(.opacity)
            } else {
                Image(nsImage: typeIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 34, height: 34)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(.easeOut(duration: 0.2), value: preview != nil)
        .task(id: key) {
            let image = await ThumbnailLoader.shared.image(localFile: localFile, remote: record.previewImageURLs, size: Self.size)
            if !Task.isCancelled { preview = image }
        }
        .accessibilityHidden(true)
    }

    /// Small play / note mark so a media preview reads as media, not a picture download.
    @ViewBuilder
    private var mediaBadge: some View {
        if record.kind == .media {
            Image(systemName: record.mediaFormat?.isAudioOnly == true ? "music.note" : "play.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(.black.opacity(0.55), in: Circle())
                .padding(3)
        }
    }

    private var typeIcon: NSImage {
        if record.status == .completed, let path = record.finalPath, item.fileExists {
            return NSWorkspace.shared.icon(forFile: path.path)
        }
        let ext = (record.fileName as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}

/// Loads and caches download previews. Remote images go through a dedicated URL cache on
/// disk, so thumbnails survive relaunches without being fetched again.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let memory = NSCache<NSString, NSImage>()
    /// Keys that had no preview, so scrolling doesn't retry them over and over.
    private var misses: Set<String> = []
    /// Full pixel size of remote images, known once they have loaded.
    private var pixelSizes: [URL: CGSize] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flux/Thumbnails", isDirectory: true)
        config.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 100 << 20, directory: directory)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    private init() { memory.countLimit = 300 }

    /// The best preview already in memory, without loading anything.
    func cachedImage(localFile: URL?, remote: [URL]) -> NSImage? {
        let keys = (localFile.map { ["file:" + $0.path] } ?? []) + remote.map(\.absoluteString)
        return keys.lazy.compactMap { self.memory.object(forKey: $0 as NSString) }.first
    }

    /// Tries the finished file first (shows what you actually got), then remote previews.
    func image(localFile: URL?, remote: [URL], size: CGSize) async -> NSImage? {
        if let localFile, let image = await cached("file:" + localFile.path, { await self.quickLook(localFile, size: size) }) {
            return image
        }
        for url in remote {
            if let image = await cached(url.absoluteString, { await self.download(url, size: size) }) { return image }
        }
        return nil
    }

    /// The real pixel size of a remote image this loader has fetched.
    func pixelSize(of url: URL) -> CGSize? { pixelSizes[url] }

    private func cached(_ key: String, _ load: () async -> NSImage?) async -> NSImage? {
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if misses.contains(key) { return nil }
        guard let image = await load() else {
            if !Task.isCancelled { misses.insert(key) }
            return nil
        }
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    /// Real content only (`.thumbnail`): a generic icon is no better than the type icon.
    private func quickLook(_ file: URL, size: CGSize) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: file, size: CGSize(width: size.width * 2, height: size.height * 2),
            scale: scale, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }

    /// Decodes at display size: full-resolution photos would cost hundreds of MB in a grid.
    private func download(_ url: URL, size: CGSize) async -> NSImage? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count < 15 << 20 // a picture, not a payload
        else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return NSImage(data: data)
        }
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int {
            pixelSizes[url] = CGSize(width: width, height: height)
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height) * scale * 1.5),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(data: data) // SVG and other formats ImageIO doesn't decode
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
