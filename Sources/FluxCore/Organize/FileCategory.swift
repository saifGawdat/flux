import Foundation

/// What kind of file a download is, from its name (and media format).
public enum FileCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case documents, images, videos, music, archives, apps, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .documents: "Documents"
        case .images: "Images"
        case .videos: "Videos"
        case .music: "Music"
        case .archives: "Archives"
        case .apps: "Apps"
        case .other: "Other"
        }
    }

    /// SF Symbol for sidebars and badges.
    public var systemImage: String {
        switch self {
        case .documents: "doc.text"
        case .images: "photo"
        case .videos: "film"
        case .music: "music.note"
        case .archives: "archivebox"
        case .apps: "app.badge"
        case .other: "doc"
        }
    }

    /// Folder name inside the download folder when "Sort into category folders" is on.
    public var folderName: String { title }

    static let extensions: [FileCategory: Set<String>] = [
        .documents: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "txt", "md",
                     "csv", "pages", "numbers", "key", "epub", "mobi", "azw3", "djvu", "tex", "json", "xml"],
        .images: ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff", "svg", "ico",
                  "raw", "cr2", "nef", "arw", "dng", "psd"],
        .videos: ["mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "3gp", "ts", "m2ts"],
        .music: ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "wma", "alac"],
        .archives: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "lz", "lzma",
                    "cab", "iso"],
        .apps: ["dmg", "pkg", "mpkg", "app", "exe", "msi", "deb", "rpm", "apk", "ipa", "appimage"],
    ]

    /// Category for a file name ("report.PDF" → documents; "a.tar.gz" → archives).
    public static func of(fileName: String) -> FileCategory {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        return allCases.first { extensions[$0]?.contains(ext) == true } ?? .other
    }

    /// Category for a download: media downloads follow their format before a name exists.
    public static func of(_ record: DownloadRecord) -> FileCategory {
        let byName = of(fileName: record.finalPath?.lastPathComponent ?? record.fileName)
        if byName != .other || record.kind != .media { return byName }
        return record.mediaFormat?.isAudioOnly == true ? .music : .videos
    }
}

extension DownloadRecord {
    public var category: FileCategory { FileCategory.of(self) }
}
