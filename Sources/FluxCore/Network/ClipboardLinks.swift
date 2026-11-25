import Foundation

/// Decides which copied links are worth offering to download. Flux only asks about links
/// that name a file (by extension) or open a page on a known video or audio site, so
/// copying an ordinary web address doesn't interrupt anyone.
public enum ClipboardLinks {
    /// Longer clipboard text is ignored: it's a document, not a link someone wants fetched.
    public static let maxTextLength = 20_000
    public static let maxLinks = 50

    public static func downloadCandidates(in text: String) -> [URL] {
        guard text.count <= maxTextLength else { return [] }
        return Array(LinkExtractor.urls(in: text).filter(looksLikeDownload).prefix(maxLinks))
    }

    public static func looksLikeDownload(_ url: URL) -> Bool {
        guard LinkExtractor.isDownloadable(url) else { return false }
        if MediaRouting.prefersMedia(url) {
            // A channel or home page isn't a download; a video, playlist or track is.
            return url.path.count > 1 || url.query != nil
        }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/" else { return false }
        let ext = url.pathExtension.lowercased()
        guard !textExtensions.contains(ext) else { return false }
        return FileCategory.of(fileName: name) != .other || binaryExtensions.contains(ext)
    }

    /// Text formats people copy links to for reading (API responses, READMEs), not saving.
    static let textExtensions: Set<String> = ["json", "xml", "md", "txt"]
    /// Downloads not covered by the file categories.
    static let binaryExtensions: Set<String> = ["bin", "img", "torrent", "jar", "whl", "vsix", "crx", "xpi", "srt", "vtt", "ttf", "otf", "woff2"]
}
