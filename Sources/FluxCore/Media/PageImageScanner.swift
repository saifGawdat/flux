import Foundation

/// Finds the pictures on an ordinary web page by reading its HTML: `<img>` (including
/// lazy-loading attributes and the largest `srcset` candidate), `<picture><source>`,
/// links that point straight at image files, and the page's share image (`og:image`).
/// Pages that draw their content with JavaScript show little here; gallery-dl covers
/// the big sites of that kind.
public enum PageImageScanner {
    public enum ScanError: LocalizedError, Equatable {
        case notAPage
        case noImages
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notAPage: "This link isn't a web page."
            case .noImages: "No images found on this page."
            case .failed(let message): message
            }
        }
    }

    /// Largest page read; anything bigger isn't an ordinary HTML page.
    static let maxPageBytes = 8 << 20

    /// Many sites serve a stripped page, or nothing, to clients that don't look like a browser.
    static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    public static func scan(_ url: URL, session: URLSession = .shared) async throws -> ImageCollection {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ScanError.notAPage }
        guard (200..<300).contains(http.statusCode) else {
            throw ScanError.failed("The page answered with HTTP \(http.statusCode).")
        }
        guard let mime = http.mimeType?.lowercased(), mime.contains("html") else { throw ScanError.notAPage }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxPageBytes { break }
        }
        let html = String(decoding: data, as: UTF8.self)
        let page = parse(html, pageURL: http.url ?? url)
        guard !page.items.isEmpty else { throw ScanError.noImages }
        return page
    }

    /// Pure HTML → images, in page order (share image first), without duplicates.
    static func parse(_ html: String, pageURL: URL) -> ImageCollection {
        let base = tags("base", in: html).first.flatMap { $0["href"] }
            .flatMap { URL(string: $0, relativeTo: pageURL)?.absoluteURL } ?? pageURL

        var found: [(url: URL, width: Int?, height: Int?)] = []
        func add(_ raw: String?, width: Int? = nil, height: Int? = nil) {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
                  !raw.lowercased().hasPrefix("data:"),
                  let url = URL(string: raw, relativeTo: base)?.absoluteURL,
                  LinkExtractor.isDownloadable(url) else { return }
            let ext = url.pathExtension.lowercased()
            guard !["svg", "ico"].contains(ext) else { return } // icons and logos
            found.append((url, width, height))
        }

        for meta in tags("meta", in: html) {
            let name = (meta["property"] ?? meta["name"] ?? "").lowercased()
            if ["og:image", "og:image:url", "og:image:secure_url", "twitter:image"].contains(name) { add(meta["content"]) }
        }
        for link in tags("link", in: html) where (link["rel"] ?? "").lowercased() == "image_src" {
            add(link["href"])
        }
        for img in tags("img", in: html) {
            let width = img["width"].flatMap { Int($0) }
            let height = img["height"].flatMap { Int($0) }
            let srcset = img["data-srcset"] ?? img["srcset"]
            let best = srcset.flatMap(largestCandidate)
                ?? img["data-src"] ?? img["data-original"] ?? img["data-lazy-src"] ?? img["data-full"] ?? img["src"]
            // A srcset's largest candidate is bigger than the declared display size.
            let fromSrcset = srcset.flatMap(largestCandidate) != nil
            add(best, width: fromSrcset ? nil : width, height: fromSrcset ? nil : height)
        }
        for source in tags("source", in: html) {
            if let type = source["type"]?.lowercased(), !type.hasPrefix("image/") { continue }
            add((source["data-srcset"] ?? source["srcset"]).flatMap(largestCandidate))
        }
        for anchor in tags("a", in: html) {
            guard let href = anchor["href"],
                  let url = URL(string: href, relativeTo: base),
                  MediaExtensions.image.contains(url.pathExtension.lowercased()) else { continue }
            add(href)
        }

        var seen = Set<String>()
        var items: [ImageCollection.Item] = []
        for candidate in found {
            var key = candidate.url
            if var parts = URLComponents(url: key, resolvingAgainstBaseURL: false) {
                parts.fragment = nil
                key = parts.url ?? key
            }
            guard seen.insert(key.absoluteString).inserted else { continue }
            items.append(ImageCollection.Item(
                id: items.count, url: key, width: candidate.width, height: candidate.height,
                isVideo: MediaExtensions.video.contains(key.pathExtension.lowercased())))
        }
        let ogTitle = tags("meta", in: html).first { ($0["property"] ?? "").lowercased() == "og:title" }?["content"]
        let title = (ogTitle ?? documentTitle(html)).map(decodeEntities)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ImageCollection(
            title: title.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) } ?? fallbackTitle(for: pageURL),
            pageURL: pageURL,
            items: items,
            source: .page)
    }

    /// "example.com · gallery" when a page has no usable title.
    static func fallbackTitle(for url: URL) -> String {
        let host = (url.host() ?? "Images").replacingOccurrences(of: "www.", with: "")
        let last = url.deletingPathExtension().lastPathComponent
        return last.isEmpty || last == "/" ? host : "\(host) · \(last)"
    }

    /// The URL with the largest width (`800w`) or density (`2x`) descriptor.
    static func largestCandidate(_ srcset: String) -> String? {
        var best: (url: String, score: Double)?
        for part in srcset.components(separatedBy: ",") {
            let fields = part.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
            guard let first = fields.first else { continue }
            var score = 1.0
            if let descriptor = fields.dropFirst().first?.lowercased() {
                if descriptor.hasSuffix("w") { score = Double(descriptor.dropLast()) ?? 1 }
                if descriptor.hasSuffix("x") { score = (Double(descriptor.dropLast()) ?? 1) * 1000 }
            }
            if best == nil || score > best!.score { best = (String(first), score) }
        }
        return best?.url
    }

    // MARK: - Minimal HTML reading

    private static let attributePattern = try! NSRegularExpression(
        pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"#)

    /// Attributes (lower-cased names, entity-decoded values) of every `<name …>` tag.
    static func tags(_ name: String, in html: String) -> [[String: String]] {
        guard let tagPattern = try? NSRegularExpression(
            pattern: "<\(name)\\b([^>]*)>", options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        return tagPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { match in
            let body = ns.substring(with: match.range(at: 1))
            let bodyNS = body as NSString
            var attributes: [String: String] = [:]
            for attr in attributePattern.matches(in: body, range: NSRange(location: 0, length: bodyNS.length)) {
                let key = bodyNS.substring(with: attr.range(at: 1)).lowercased()
                guard attributes[key] == nil else { continue }
                let value = (2...4).lazy.map { attr.range(at: $0) }.first { $0.location != NSNotFound }
                    .map { bodyNS.substring(with: $0) } ?? ""
                attributes[key] = decodeEntities(value)
            }
            return attributes
        }
    }

    private static func documentTitle(_ html: String) -> String? {
        guard let range = html.range(of: #"<title[^>]*>([^<]*)</title>"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        return String(html[range])
            .replacingOccurrences(of: #"</?title[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var s = text
        for (entity, value) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: entity, with: value)
        }
        if let numeric = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") {
            let ns = s as NSString
            var result = ""
            var last = 0
            for m in numeric.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                let digits = ns.substring(with: m.range(at: 2))
                if let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    result.unicodeScalars.append(scalar)
                } else {
                    result += ns.substring(with: m.range)
                }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            s = result
        }
        return s.replacingOccurrences(of: "&amp;", with: "&")
    }
}
