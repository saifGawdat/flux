import Foundation
import UniformTypeIdentifiers

public enum FileNaming {
    /// Extracts a file name from a Content-Disposition header (RFC 6266 / RFC 5987).
    public static func fileName(fromContentDisposition header: String) -> String? {
        if let ext = firstCapture(#"filename\*\s*=\s*([^;]+)"#, in: header) {
            var value = ext.trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if let sep = value.range(of: "''") {
                let charset = value[..<sep.lowerBound].lowercased()
                let encoding: String.Encoding = charset == "iso-8859-1" ? .isoLatin1 : .utf8
                if let decoded = percentDecode(String(value[sep.upperBound...]), encoding: encoding), !decoded.isEmpty {
                    return decoded
                }
            }
        }
        if let quoted = firstCapture(#"filename\s*=\s*"((?:[^"\\]|\\.)*)""#, in: header) {
            let unescaped = quoted.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
            if !unescaped.isEmpty { return unescaped }
        }
        if let token = firstCapture(#"filename\s*=\s*([^;\s]+)"#, in: header), !token.isEmpty {
            return token
        }
        return nil
    }

    /// Best-effort name from the last path component of a URL.
    public static func fileName(from url: URL) -> String {
        let last = url.lastPathComponent
        if last.isEmpty || last == "/" {
            return url.host().map { "\($0) download" } ?? "download"
        }
        return last
    }

    private static let scriptExtensions: Set<String> = ["", "php", "asp", "aspx", "jsp", "cgi", "pl", "do", "action"]

    /// Adds or fixes the extension when the URL-derived name lacks a real one (e.g. `download.php`).
    public static func ensureExtension(_ name: String, mimeType: String?) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension.lowercased()
        guard scriptExtensions.contains(ext),
              let mime = mimeType?.lowercased(),
              mime != "application/octet-stream", mime != "text/html",
              let preferred = UTType(mimeType: mime)?.preferredFilenameExtension
        else { return name }
        let base = ext.isEmpty ? name : ns.deletingPathExtension
        return "\(base).\(preferred)"
    }

    /// Makes a server- or user-supplied name safe to use as a single path component.
    public static func sanitize(_ name: String) -> String {
        var s = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "download" }
        if s.utf8.count > 240 {
            let ns = s as NSString
            let ext = ns.pathExtension
            var base = ns.deletingPathExtension
            while base.utf8.count + ext.utf8.count + 1 > 240, !base.isEmpty { base.removeLast() }
            s = ext.isEmpty ? base : "\(base).\(ext)"
        }
        return s
    }

    /// `name.ext`, then `name (1).ext`, `name (2).ext`… until `exists` returns false.
    public static func uniqueURL(
        for name: String,
        in directory: URL,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let first = directory.appendingPathComponent(name)
        guard exists(first) else { return first }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        var i = 1
        while true {
            let candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)")
            if !exists(candidate) { return candidate }
            i += 1
        }
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func percentDecode(_ s: String, encoding: String.Encoding) -> String? {
        var bytes: [UInt8] = []
        var it = s.utf8.makeIterator()
        while let c = it.next() {
            if c == UInt8(ascii: "%") {
                guard let h = it.next(), let l = it.next(),
                      let v = UInt8(String(decoding: [h, l], as: UTF8.self), radix: 16)
                else { return nil }
                bytes.append(v)
            } else {
                bytes.append(c)
            }
        }
        return String(data: Data(bytes), encoding: encoding)
    }
}
