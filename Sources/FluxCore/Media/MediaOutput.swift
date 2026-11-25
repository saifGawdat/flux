import Foundation

/// Parses the lines Flux asks yt-dlp to print (see `MediaJob.arguments`).
enum MediaOutput {
    /// Machine-readable progress, one line per update. Unknown values print as "NA".
    static let progressTemplate =
        "download:FLUXPROG|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(info.format_id)s"
    static let titleTemplate = "before_dl:FLUXTITLE|%(title)s"
    static let thumbnailTemplate = "before_dl:FLUXTHUMB|%(thumbnail)s"
    static let fileTemplate = "after_move:FLUXFILE|%(filepath)s"

    struct Progress: Equatable {
        var status: String
        var downloaded: Int64?
        var total: Int64?
        var estimate: Int64?
        var speed: Double?
        var formatID: String?
    }

    enum Line: Equatable {
        case progress(Progress)
        case title(String)
        case thumbnail(URL)
        case finalFile(String)
        case postProcessing(String)
        case error(String)
        case other
    }

    static func parse(_ raw: String) -> Line {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("FLUXPROG|") {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7 else { return .other }
            return .progress(Progress(
                status: f[1], downloaded: int(f[2]), total: int(f[3]), estimate: int(f[4]),
                speed: Double(f[5]), formatID: f[6] == "NA" ? nil : f[6]))
        }
        if let title = line.dropPrefix("FLUXTITLE|") { return .title(title) }
        if let thumb = line.dropPrefix("FLUXTHUMB|") { return Thumbnails.remote(thumb).map(Line.thumbnail) ?? .other }
        if let path = line.dropPrefix("FLUXFILE|") { return .finalFile(path) }
        if let message = line.dropPrefix("ERROR: ") { return .error(message) }
        if line.hasPrefix("[Merger]") { return .postProcessing("Merging video and audio…") }
        if line.hasPrefix("[ExtractAudio]") { return .postProcessing("Converting audio…") }
        if line.hasPrefix("[VideoConvertor]") || line.hasPrefix("[VideoRemuxer]") { return .postProcessing("Converting video…") }
        if line.hasPrefix("[Fixup") { return .postProcessing("Finishing…") }
        return .other
    }

    private static func int(_ s: String) -> Int64? { Double(s).map { Int64($0) } }
}

/// Splits a byte stream into lines (yt-dlp may use \r or \n).
struct LineBuffer {
    private var pending = Data()

    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let i = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = pending[pending.startIndex..<i]
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
            pending.removeSubrange(pending.startIndex...i)
        }
        return lines
    }

    mutating func flush() -> [String] {
        defer { pending.removeAll() }
        return pending.isEmpty ? [] : [String(decoding: pending, as: UTF8.self)]
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
