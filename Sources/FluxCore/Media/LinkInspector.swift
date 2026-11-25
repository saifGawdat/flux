import Foundation

/// Everything Flux could find behind one link, for the add sheet to offer.
public struct LinkInspection: Sendable, Equatable {
    /// A video (with per-format sizes) and/or a playlist.
    public var media: MediaInspection?
    /// Pictures: a gallery-dl gallery or the images on the page.
    public var images: ImageCollection?
    /// Why nothing was found, when nothing was. nil with nothing found means the link
    /// is an ordinary file: add it as is.
    public var problem: String?

    public init(media: MediaInspection? = nil, images: ImageCollection? = nil, problem: String? = nil) {
        self.media = media
        self.images = images
        self.problem = problem
    }

    public var foundAnything: Bool { media != nil || !(images?.items.isEmpty ?? true) }
}

/// Decides how to look at a link and runs the right probes side by side:
/// video sites → yt-dlp only; picture sites and ordinary pages → yt-dlp and gallery-dl,
/// falling back to Flux's own page scan for sites gallery-dl doesn't know.
public enum LinkInspector {
    /// Sites that are only about video/audio: no point looking for galleries there.
    static let videoOnlyHosts: [String] = [
        "youtube.com", "youtu.be", "youtube-nocookie.com", "vimeo.com", "dailymotion.com", "twitch.tv",
        "soundcloud.com", "bandcamp.com", "bilibili.com", "streamable.com", "rumble.com", "mixcloud.com",
    ]

    /// True when the add sheet should inspect this link before adding it.
    public static func shouldInspect(_ url: URL) -> Bool {
        LinkExtractor.isDownloadable(url) && !MediaRouting.isDirectFile(url)
    }

    public static func inspect(_ url: URL, tools: MediaTools, session: URLSession = .shared) async -> LinkInspection {
        guard shouldInspect(url) else { return LinkInspection() }
        let host = url.host()?.lowercased() ?? ""
        let videoOnly = videoOnlyHosts.contains { host == $0 || host.hasSuffix("." + $0) }

        async let media: Result<MediaInspection, Error>? = tools.ytdlp == nil ? nil : capture {
            try await MediaProbe.inspect(url, tools: tools)
        }
        async let images: Result<ImageCollection, Error>? = videoOnly ? nil : findImages(url, tools: tools, session: session)

        let mediaResult = await media
        let imageResult = await images
        try? Task.checkCancellation()

        var inspection = LinkInspection()
        if case .success(let found) = mediaResult { inspection.media = found }
        if case .success(let found) = imageResult, !found.items.isEmpty { inspection.images = found }
        if !inspection.foundAnything {
            inspection.problem = problem(media: mediaResult, images: imageResult, videoOnly: videoOnly, tools: tools)
        }
        return inspection
    }

    /// gallery-dl first; the page scan when gallery-dl is missing or doesn't know the site.
    /// Big sites that gallery-dl knows but refuses (login walls) aren't scanned: their
    /// HTML only has logos and the login page.
    private static func findImages(_ url: URL, tools: MediaTools, session: URLSession) async -> Result<ImageCollection, Error> {
        if tools.galleryDL != nil {
            let gallery = await capture { try await GalleryProbe.inspect(url, tools: tools) }
            switch gallery {
            case .success(let found) where !found.items.isEmpty:
                return gallery
            case .failure(GalleryProbe.ProbeError.unsupported), .success:
                break
            case .failure:
                return gallery
            }
        }
        if MediaRouting.prefersMedia(url) {
            return .failure(PageImageScanner.ScanError.noImages)
        }
        return await capture { try await PageImageScanner.scan(url, session: session) }
    }

    private static func problem(
        media: Result<MediaInspection, Error>?, images: Result<ImageCollection, Error>?,
        videoOnly: Bool, tools: MediaTools
    ) -> String? {
        // The link serves a file, not a page (e.g. `download.php?id=5`).
        if case .failure(PageImageScanner.ScanError.notAPage) = images { return nil }
        if case .failure(let error) = images, let gallery = error as? GalleryProbe.ProbeError, case .failed = gallery {
            return gallery.localizedDescription
        }
        if case .failure(let error) = media {
            let message = error.localizedDescription
            // yt-dlp's verdict on a page it can't read says little when images were the point.
            if videoOnly || message != "No downloadable media found on this page." { return message }
        }
        if case .failure(let error) = images, error is URLError { return error.localizedDescription }
        if tools.ytdlp == nil && videoOnly { return MediaProbeError.toolMissing.localizedDescription }
        return "No video or images found on this page."
    }

    private static func capture<T>(_ body: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}
