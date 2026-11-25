import Darwin
import Foundation

/// "When a download matches all these conditions, save it to this folder."
/// Rules are checked in order when a download finishes; the first match wins.
public struct DownloadRule: Codable, Sendable, Equatable, Identifiable {
    public enum Condition: Codable, Sendable, Equatable, Hashable {
        /// One of these extensions (without dots, any case).
        case fileExtension([String])
        /// File name matches a glob pattern such as `*invoice*.pdf` (any case).
        case namePattern(String)
        /// Link's host is this domain or one of its subdomains.
        case domain(String)
        /// The link (or the page it was found on) contains this text.
        case linkContains(String)
        case largerThan(Int64)
        case smallerThan(Int64)
        case category(FileCategory)

        public enum Kind: String, CaseIterable, Identifiable, Sendable {
            case fileExtension, namePattern, domain, linkContains, largerThan, smallerThan, category
            public var id: String { rawValue }
            public var title: String {
                switch self {
                case .fileExtension: "Extension is"
                case .namePattern: "Name matches"
                case .domain: "Site is"
                case .linkContains: "Link contains"
                case .largerThan: "Larger than"
                case .smallerThan: "Smaller than"
                case .category: "Kind is"
                }
            }
        }

        public var kind: Kind {
            switch self {
            case .fileExtension: .fileExtension
            case .namePattern: .namePattern
            case .domain: .domain
            case .linkContains: .linkContains
            case .largerThan: .largerThan
            case .smallerThan: .smallerThan
            case .category: .category
            }
        }

        /// A sensible starting value when the user picks a condition kind.
        public static func starting(_ kind: Kind) -> Condition {
            switch kind {
            case .fileExtension: .fileExtension([])
            case .namePattern: .namePattern("")
            case .domain: .domain("")
            case .linkContains: .linkContains("")
            case .largerThan: .largerThan(100_000_000)
            case .smallerThan: .smallerThan(1_000_000)
            case .category: .category(.documents)
            }
        }

        func matches(_ subject: RuleSubject) -> Bool {
            switch self {
            case .fileExtension(let list):
                let wanted = Set(list.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }.filter { !$0.isEmpty })
                let name = subject.fileName.lowercased()
                // "tar.gz" style entries match the end of the name; plain ones the last extension.
                return wanted.contains { name.hasSuffix("." + $0) }
            case .namePattern(let pattern):
                let trimmed = pattern.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return false }
                return fnmatch(trimmed.lowercased(), subject.fileName.lowercased(), 0) == 0
            case .domain(let domain):
                let wanted = domain.trimmingCharacters(in: .whitespaces).lowercased()
                    .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
                    .split(separator: "/").first.map(String.init) ?? ""
                guard !wanted.isEmpty else { return false }
                return subject.hosts.contains { $0 == wanted || $0.hasSuffix("." + wanted) }
            case .linkContains(let text):
                let needle = text.trimmingCharacters(in: .whitespaces)
                guard !needle.isEmpty else { return false }
                return subject.links.contains { $0.localizedCaseInsensitiveContains(needle) }
            case .largerThan(let bytes):
                return (subject.size ?? 0) > bytes
            case .smallerThan(let bytes):
                return subject.size.map { $0 < bytes } ?? false
            case .category(let category):
                return subject.category == category
            }
        }
    }

    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    /// All must match. A rule without conditions never matches.
    public var conditions: [Condition]
    public var folder: URL

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, conditions: [Condition], folder: URL) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.conditions = conditions
        self.folder = folder
    }

    public func matches(_ record: DownloadRecord) -> Bool {
        guard isEnabled, !conditions.isEmpty else { return false }
        let subject = RuleSubject(record)
        return conditions.allSatisfy { $0.matches(subject) }
    }
}

/// The facts rules look at, gathered once per download.
struct RuleSubject {
    let fileName: String
    let hosts: [String]
    let links: [String]
    let size: Int64?
    let category: FileCategory

    init(_ record: DownloadRecord) {
        fileName = record.finalPath?.lastPathComponent ?? record.fileName
        let pages = [record.url] + (record.referer.map { [$0] } ?? [])
        hosts = pages.compactMap { $0.host()?.lowercased() }
        links = pages.map(\.absoluteString)
        size = record.totalBytes ?? (record.receivedBytes > 0 ? record.receivedBytes : nil)
        category = record.category
    }
}

/// Where a finished download belongs, by the user's rules and category folders.
public enum Filing {
    public struct Destination: Equatable, Sendable {
        public var folder: URL
        /// "rule “Invoices”" or "Videos", for display.
        public var reason: String
    }

    /// nil when the download should stay where it is.
    public static func destination(for record: DownloadRecord, settings: FluxSettings) -> Destination? {
        if let rule = settings.rules.first(where: { $0.matches(record) }) {
            return Destination(folder: rule.folder, reason: "rule “\(rule.name)”")
        }
        guard settings.sortIntoCategoryFolders else { return nil }
        let category = record.category
        guard category != .other else { return nil }
        return Destination(
            folder: settings.downloadDirectory.appendingPathComponent(category.folderName, isDirectory: true),
            reason: category.title)
    }
}
