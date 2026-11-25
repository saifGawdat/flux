import Foundation

/// Parsed `Content-Range: bytes <start>-<end>/<total|*>` header.
public struct ContentRange: Equatable, Sendable {
    public var start: Int64
    public var end: Int64
    public var total: Int64?

    public init(start: Int64, end: Int64, total: Int64?) {
        self.start = start
        self.end = end
        self.total = total
    }

    /// True for `bytes */0`: the reply to a range request on an empty file (HTTP 416).
    public static func isEmptyResource(_ header: String?) -> Bool {
        header?.replacingOccurrences(of: " ", with: "").lowercased() == "bytes*/0"
    }

    public static func parse(_ header: String) -> ContentRange? {
        let s = header.trimmingCharacters(in: .whitespaces)
        guard s.lowercased().hasPrefix("bytes ") else { return nil }
        let parts = s.dropFirst("bytes ".count).split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let range = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard range.count == 2,
              let start = Int64(range[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(range[1].trimmingCharacters(in: .whitespaces)),
              start >= 0, end >= start
        else { return nil }
        let totalText = parts[1].trimmingCharacters(in: .whitespaces)
        if totalText == "*" { return ContentRange(start: start, end: end, total: nil) }
        guard let total = Int64(totalText), total > end else { return nil }
        return ContentRange(start: start, end: end, total: total)
    }
}

public enum LinkExtractor {
    /// All distinct http(s) links in free text, in order of appearance.
    public static func urls(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<URL>()
        var result: [URL] = []
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, isDownloadable(url), seen.insert(url).inserted else { continue }
            result.append(url)
        }
        return result
    }

    /// Flux only accepts absolute http(s) URLs with a host.
    public static func isDownloadable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(url.host() ?? "").isEmpty
    }
}
