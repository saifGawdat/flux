import Foundation

/// One link read from (or written to) a list file, with whatever details the file had.
public struct LinkListEntry: Codable, Sendable, Equatable {
    public var url: URL
    public var fileName: String?
    /// Folder to save into; nil = Flux decides (and may organize the file).
    public var directory: URL?
    public var checksum: Checksum?
    public var mirrors: [URL]
    public var referer: URL?

    public init(url: URL, fileName: String? = nil, directory: URL? = nil, checksum: Checksum? = nil,
                mirrors: [URL] = [], referer: URL? = nil) {
        self.url = url
        self.fileName = fileName
        self.directory = directory
        self.checksum = checksum
        self.mirrors = mirrors
        self.referer = referer
    }

    private enum CodingKeys: String, CodingKey {
        case url, fileName, name, directory, folder, checksum, mirrors, referer
    }

    /// Lenient: accepts `name` or `fileName`, `folder` or `directory`, and ignores details
    /// it can't read (a bad checksum doesn't lose the link).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let url = URL(string: try c.decode(String.self, forKey: .url)), LinkExtractor.isDownloadable(url) else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "Not an http(s) link")
        }
        self.url = url
        func text(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
        fileName = LinkList.cleanName(text(.fileName) ?? text(.name))
        directory = LinkList.folder(text(.directory) ?? text(.folder))
        checksum = text(.checksum).flatMap(Checksum.parse)
        mirrors = (((try? c.decodeIfPresent([String].self, forKey: .mirrors)) ?? nil) ?? [])
            .compactMap(URL.init(string:)).filter(LinkExtractor.isDownloadable)
        referer = text(.referer).flatMap(URL.init(string:)).flatMap { LinkExtractor.isDownloadable($0) ? $0 : nil }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url.absoluteString, forKey: .url)
        try c.encodeIfPresent(fileName, forKey: .fileName)
        try c.encodeIfPresent(directory?.path, forKey: .directory)
        try c.encodeIfPresent(checksum?.description, forKey: .checksum)
        if !mirrors.isEmpty { try c.encode(mirrors.map(\.absoluteString), forKey: .mirrors) }
        try c.encodeIfPresent(referer?.absoluteString, forKey: .referer)
    }
}

public enum LinkListFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    /// One link per line. Reads aria2-style option lines (`  out=name`, `  dir=folder`,
    /// `  checksum=sha-256=…`) and tab-separated mirrors.
    case text
    case csv
    case json

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .text: "Text (one link per line)"
        case .csv: "CSV (spreadsheet)"
        case .json: "JSON (everything)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .text: "txt"
        case .csv: "csv"
        case .json: "json"
        }
    }

    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "txt", "text", "list", "lst", "": self = .text
        case "csv", "tsv": self = .csv
        case "json": self = .json
        default: return nil
        }
    }
}

public enum LinkListError: LocalizedError, Equatable {
    case tooLarge
    case unreadable(String)
    case noLinks

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "The file is too large to be a list of links (over 20 MB)."
        case .unreadable(let why): "Flux couldn’t read the file: \(why)"
        case .noLinks: "The file doesn’t contain any http or https links."
        }
    }
}

/// Reads and writes lists of links: plain text, CSV and JSON.
public enum LinkList {
    public static let maxFileSize = 20 * 1024 * 1024
    public static let maxEntries = 10_000

    // MARK: Reading

    /// Reads a list file. Without a format, it's guessed from the content.
    public static func read(_ url: URL) throws -> [LinkListEntry] {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileSize else { throw LinkListError.tooLarge }
        let data = try Data(contentsOf: url)
        return try parse(data, format: LinkListFormat(fileExtension: url.pathExtension))
    }

    public static func parse(_ data: Data, format: LinkListFormat? = nil) throws -> [LinkListEntry] {
        guard data.count <= maxFileSize else { throw LinkListError.tooLarge }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // ".txt" (or no extension) says little: a file that is really JSON or CSV is read as such.
        let format = format == nil || format == .text ? guess(text) : format!
        var entries: [LinkListEntry]
        switch format {
        case .json: entries = try parseJSON(data)
        case .csv: entries = parseCSV(text)
        case .text: entries = parseText(text)
        }
        var seen = Set<URL>()
        entries = entries.filter { seen.insert($0.url).inserted }
        guard !entries.isEmpty else { throw LinkListError.noLinks }
        return Array(entries.prefix(maxEntries))
    }

    static func guess(_ text: String) -> LinkListFormat {
        let start = text.drop { $0.isWhitespace }.first
        if start == "[" || start == "{" { return .json }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init)?.lowercased() ?? ""
        let header = splitCSVLine(firstLine, separator: separator(for: firstLine)).map { $0.trimmingCharacters(in: .whitespaces) }
        return header.contains { Column(header: $0) == .url } ? .csv : .text
    }

    private static func parseText(_ text: String) -> [LinkListEntry] {
        var entries: [LinkListEntry] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // aria2 input files: indented "key=value" lines belong to the link above.
            if line.first?.isWhitespace == true, let eq = trimmed.firstIndex(of: "="), !entries.isEmpty,
               !trimmed.lowercased().hasPrefix("http") {
                let key = trimmed[..<eq].lowercased()
                let value = String(trimmed[trimmed.index(after: eq)...])
                switch key {
                case "out": entries[entries.count - 1].fileName = cleanName(value)
                case "dir": entries[entries.count - 1].directory = folder(value)
                case "checksum": entries[entries.count - 1].checksum = Checksum.parse(value)
                case "referer": entries[entries.count - 1].referer = URL(string: value).flatMap { LinkExtractor.isDownloadable($0) ? $0 : nil }
                default: break
                }
                continue
            }
            // A line of tab-separated links is one file with mirrors (aria2); otherwise
            // every link on the line is its own download.
            if line.contains("\t") {
                let urls = line.split(separator: "\t").compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
                    .filter(LinkExtractor.isDownloadable)
                if let first = urls.first {
                    entries.append(LinkListEntry(url: first, mirrors: Array(urls.dropFirst())))
                    continue
                }
            }
            entries += LinkExtractor.urls(in: line).map { LinkListEntry(url: $0) }
        }
        return entries
    }

    private struct JSONList: Decodable {
        var downloads: [Lenient]
    }

    /// Skips entries it can't read instead of rejecting the whole file.
    private struct Lenient: Decodable {
        var entry: LinkListEntry?
        init(from decoder: Decoder) throws {
            if let entry = try? LinkListEntry(from: decoder) {
                self.entry = entry
            } else if let text = try? decoder.singleValueContainer().decode(String.self),
                      let url = URL(string: text), LinkExtractor.isDownloadable(url) {
                self.entry = LinkListEntry(url: url)
            }
        }
    }

    private static func parseJSON(_ data: Data) throws -> [LinkListEntry] {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode(JSONList.self, from: data) { return list.downloads.compactMap(\.entry) }
        do {
            return try decoder.decode([Lenient].self, from: data).compactMap(\.entry)
        } catch {
            throw LinkListError.unreadable("it isn’t valid JSON.")
        }
    }

    enum Column: Equatable {
        case url, name, folder, checksum, mirrors, referer

        init?(header: String) {
            switch header.lowercased().filter({ $0.isLetter || $0.isNumber }) {
            case "url", "link", "href", "address", "downloadurl", "source": self = .url
            case "name", "filename", "file", "title": self = .name
            case "folder", "directory", "dir", "path", "savedto", "saveto": self = .folder
            case "checksum", "hash", "sha256", "sha1", "md5", "sha512": self = .checksum
            case "mirrors", "mirror": self = .mirrors
            case "referer", "referrer", "page": self = .referer
            default: return nil
            }
        }
    }

    private static func separator(for line: String) -> Character {
        let counts: [(Character, Int)] = [",", ";", "\t"].map { sep in (sep, line.filter { $0 == sep }.count) }
        return counts.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil } ?? ","
    }

    private static func parseCSV(_ text: String) -> [LinkListEntry] {
        let lines = csvRecords(text)
        guard let header = lines.first else { return [] }
        let columns = header.map { Column(header: $0.trimmingCharacters(in: .whitespaces)) }
        // No header: the first column is the link.
        let hasHeader = columns.contains(.url)
        let rows = hasHeader ? Array(lines.dropFirst()) : lines
        return rows.compactMap { row in
            func value(_ column: Column) -> String? {
                let index = hasHeader ? columns.firstIndex(of: column) : (column == .url ? 0 : nil)
                guard let index, index < row.count else { return nil }
                let text = row[index].trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : text
            }
            guard let link = value(.url), let url = URL(string: link), LinkExtractor.isDownloadable(url) else { return nil }
            return LinkListEntry(
                url: url,
                fileName: cleanName(value(.name)),
                directory: folder(value(.folder)),
                checksum: value(.checksum).flatMap(Checksum.parse),
                mirrors: (value(.mirrors) ?? "").split(whereSeparator: { $0 == " " || $0 == "|" })
                    .compactMap { URL(string: String($0)) }.filter(LinkExtractor.isDownloadable),
                referer: value(.referer).flatMap(URL.init(string:)).flatMap { LinkExtractor.isDownloadable($0) ? $0 : nil })
        }
    }

    /// Splits CSV into records, honouring quoted fields (with "" escapes and line breaks).
    static func csvRecords(_ text: String) -> [[String]] {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let sep = separator(for: firstLine)
        var records: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        var iterator = Array(text).makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        while let ch = next() {
            if inQuotes {
                if ch == "\"" {
                    if let following = next() {
                        if following == "\"" { field.append("\"") } else { inQuotes = false; pending = following }
                    } else { inQuotes = false }
                } else {
                    field.append(ch)
                }
            } else if ch == "\"" && field.isEmpty {
                inQuotes = true
            } else if ch == sep {
                record.append(field); field = ""
            } else if ch == "\n" || ch == "\r" || ch == "\r\n" {
                record.append(field); field = ""
                if record.contains(where: { !$0.isEmpty }) { records.append(record) }
                record = []
            } else {
                field.append(ch)
            }
        }
        record.append(field)
        if record.contains(where: { !$0.isEmpty }) { records.append(record) }
        return records
    }

    static func splitCSVLine(_ line: String, separator: Character) -> [String] {
        csvRecords(line).first ?? []
    }

    static func cleanName(_ name: String?) -> String? {
        guard let name else { return nil }
        let clean = FileNaming.sanitize(name)
        return clean.isEmpty ? nil : clean
    }

    /// Absolute folders only (with ~ expanded); anything else is ignored.
    static func folder(_ path: String?) -> URL? {
        guard let path = path?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    // MARK: Writing

    public static func export(_ records: [DownloadRecord], format: LinkListFormat) -> Data {
        switch format {
        case .text:
            return Data(records.map { $0.url.absoluteString + "\n" }.joined().utf8)
        case .csv:
            var lines = ["url,name,folder,status,size,checksum,mirrors,referer,added,completed"]
            let dates = ISO8601DateFormatter()
            for r in records {
                let fields: [String] = [
                    r.url.absoluteString, r.displayName, (r.finalPath?.deletingLastPathComponent() ?? r.directory).path,
                    r.status.rawValue, r.totalBytes.map(String.init) ?? "",
                    r.checksum?.description ?? r.contentHash.map { "sha256:" + $0 } ?? "",
                    r.mirrors.map(\.absoluteString).joined(separator: " "), r.referer?.absoluteString ?? "",
                    dates.string(from: r.createdAt), r.completedAt.map(dates.string(from:)) ?? "",
                ]
                lines.append(fields.map(csvField).joined(separator: ","))
            }
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let file = ExportFile(downloads: records.map(ExportedDownload.init))
            return (try? encoder.encode(file)) ?? Data()
        }
    }

    private static func csvField(_ value: String) -> String {
        // Leading =, +, - or @ would run as a formula in spreadsheet apps.
        var value = value
        if let first = value.first, "=+-@".contains(first) { value = "'" + value }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) || value != value.trimmingCharacters(in: .whitespaces)
        else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private struct ExportFile: Encodable {
        let format = "flux-downloads"
        let version = 1
        let downloads: [ExportedDownload]
    }

    /// Everything useful about a download; `LinkListEntry` reads it back.
    private struct ExportedDownload: Encodable {
        let url: String
        let name: String
        let directory: String
        let path: String?
        let status: String
        let size: Int64?
        let checksum: String?
        let sha256: String?
        let mirrors: [String]?
        let referer: String?
        let added: Date
        let completed: Date?

        init(_ r: DownloadRecord) {
            url = r.url.absoluteString
            name = r.displayName
            directory = r.directory.path
            path = r.finalPath?.path
            status = r.status.rawValue
            size = r.totalBytes
            checksum = r.checksum?.description
            sha256 = r.contentHash
            mirrors = r.mirrors.isEmpty ? nil : r.mirrors.map(\.absoluteString)
            referer = r.referer?.absoluteString
            added = r.createdAt
            completed = r.completedAt
        }
    }
}
