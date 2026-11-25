import Foundation

/// Images (and the odd video) found behind one link: a gallery-dl gallery, or the
/// pictures on an ordinary web page. Each item is downloaded as its own file.
public struct ImageCollection: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// gallery-dl understood the site (Instagram, Reddit, Flickr, …).
        case gallery
        /// Flux read the page's HTML itself.
        case page
    }

    public struct Item: Sendable, Equatable, Identifiable {
        public var id: Int
        public var url: URL
        /// Name the site gives the file (gallery-dl); nil = derive from the URL.
        public var fileName: String?
        public var width: Int?
        public var height: Int?
        public var bytes: Int64?
        public var isVideo: Bool
        /// gallery-dl hands some videos to yt-dlp (`ytdl:` links): download as media.
        public var needsMediaExtractor: Bool

        public init(
            id: Int, url: URL, fileName: String? = nil, width: Int? = nil, height: Int? = nil,
            bytes: Int64? = nil, isVideo: Bool = false, needsMediaExtractor: Bool = false
        ) {
            self.id = id
            self.url = url
            self.fileName = fileName
            self.width = width
            self.height = height
            self.bytes = bytes
            self.isVideo = isVideo
            self.needsMediaExtractor = needsMediaExtractor
        }

        /// Known to be tiny (icons, spacers, tracking pixels).
        public var isSmall: Bool {
            guard let width, let height else { return false }
            return min(width, height) < ImageCollection.smallImageLimit
        }
    }

    /// Images narrower or shorter than this are treated as icons.
    public static let smallImageLimit = 100

    public var title: String
    public var pageURL: URL
    public var items: [Item]
    public var source: Source
    /// Only the first `GalleryProbe.itemLimit` items were read.
    public var isTruncated: Bool

    public init(title: String, pageURL: URL, items: [Item], source: Source, isTruncated: Bool = false) {
        self.title = title
        self.pageURL = pageURL
        self.items = items
        self.source = source
        self.isTruncated = isTruncated
    }

    public var imageCount: Int { items.lazy.filter { !$0.isVideo }.count }
    public var videoCount: Int { items.lazy.filter(\.isVideo).count }
}

enum MediaExtensions {
    static let image: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "heif", "bmp", "tif", "tiff", "jxl"]
    static let video: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv"]
}
