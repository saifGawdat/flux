import Foundation

/// Lists a gallery's files with gallery-dl (`-j`: metadata only, nothing is downloaded).
/// gallery-dl reads the user's own config (`~/.config/gallery-dl/config.json`), so sites
/// that need a login work once the user has set up cookies there.
public enum GalleryProbe {
    /// Most files read from one link.
    static let itemLimit = 500

    public enum ProbeError: LocalizedError, Equatable {
        case toolMissing
        case unsupported
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .toolMissing: "gallery-dl isn't installed."
            case .unsupported: "gallery-dl doesn't support this site."
            case .failed(let message): message
            }
        }
    }

    public static func inspect(_ url: URL, tools: MediaTools) async throws -> ImageCollection {
        guard let galleryDL = tools.galleryDL else { throw ProbeError.toolMissing }
        let result = try await ProcessRunner.run(
            galleryDL, ["-j", "--range", "1-\(itemLimit)", "--", url.absoluteString],
            environment: tools.processEnvironment())
        let stderr = result.stderrLines
        if stderr.contains(where: { $0.contains("Unsupported URL") }) { throw ProbeError.unsupported }
        guard let collection = try? parse(result.stdout, pageURL: url) else {
            let message = stderr.last { $0.contains("[error]") }
                .map { $0.replacingOccurrences(of: #"^\[[^\]]+\]\[error\] "#, with: "", options: .regularExpression) }
            throw ProbeError.failed(message ?? "Couldn't read this gallery.")
        }
        if collection.items.isEmpty, let error = collection.error { throw ProbeError.failed(friendly(error)) }
        return collection.value
    }

    struct Parsed {
        var value: ImageCollection
        var error: String?
        var items: [ImageCollection.Item] { value.items }
    }

    /// Parses gallery-dl's `-j` output: `[[2, {directory}], [3, "url", {file}], [-1, {error}], …]`.
    static func parse(_ data: Data, pageURL: URL) throws -> Parsed {
        guard let messages = try JSONSerialization.jsonObject(with: data) as? [[Any]] else {
            throw ProbeError.failed("gallery-dl returned unreadable data.")
        }
        var directories: [[String: Any]] = []
        var items: [ImageCollection.Item] = []
        var seen = Set<URL>()
        var error: String?
        for message in messages {
            guard let type = (message.first as? NSNumber)?.intValue else { continue }
            switch type {
            case 2:
                if let meta = message.dropFirst().first as? [String: Any] { directories.append(meta) }
            case 3:
                guard message.count >= 2, var text = message[1] as? String else { continue }
                let meta = message.count >= 3 ? message[2] as? [String: Any] ?? [:] : [:]
                let viaYTDLP = text.hasPrefix("ytdl:")
                if viaYTDLP { text.removeFirst("ytdl:".count) }
                guard let url = URL(string: text), LinkExtractor.isDownloadable(url), seen.insert(url).inserted else { continue }
                let ext = ((meta["extension"] as? String) ?? url.pathExtension).lowercased()
                var fileName: String?
                if let name = meta["filename"] as? String, !name.isEmpty, !ext.isEmpty {
                    fileName = FileNaming.sanitize("\(name).\(ext)")
                }
                items.append(ImageCollection.Item(
                    id: items.count,
                    url: url,
                    fileName: viaYTDLP ? nil : fileName,
                    width: int(meta["width"]),
                    height: int(meta["height"]),
                    bytes: int(meta["size"]).map(Int64.init) ?? int(meta["filesize"]).map(Int64.init),
                    isVideo: viaYTDLP || MediaExtensions.video.contains(ext),
                    needsMediaExtractor: viaYTDLP))
            case -1:
                let info = message.dropFirst().first as? [String: Any]
                error = info?["message"] as? String ?? info?["error"] as? String
            default:
                break
            }
        }
        let collection = ImageCollection(
            title: title(from: directories, pageURL: pageURL),
            pageURL: pageURL,
            items: items,
            source: .gallery,
            isTruncated: items.count >= itemLimit)
        return Parsed(value: collection, error: error)
    }

    /// The gallery's name: the first metadata key every directory agrees on.
    static func title(from directories: [[String: Any]], pageURL: URL) -> String {
        let keys = ["album", "gallery_title", "title", "page", "subreddit", "username", "user", "author", "uploader", "blog_name", "category"]
        func value(_ meta: [String: Any], _ key: String) -> String? {
            if let s = meta[key] as? String, !s.isEmpty { return s }
            if let nested = meta[key] as? [String: Any] { return nested["name"] as? String ?? nested["title"] as? String }
            return nil
        }
        for key in keys {
            guard let first = directories.first.flatMap({ value($0, key) }),
                  directories.allSatisfy({ value($0, key) == first }) else { continue }
            let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(120)) }
        }
        return PageImageScanner.fallbackTitle(for: pageURL)
    }

    static func friendly(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("login") || lower.contains("log in") || lower.contains("authorization") || lower.contains("cookies") {
            return "This site needs you to be signed in. Set up cookies for gallery-dl to download from it."
        }
        if lower.contains("blocked") || lower.contains("429") || lower.contains("rate limit") {
            return "The site is refusing requests right now. Try again in a few minutes."
        }
        return message
    }

    private static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
}
