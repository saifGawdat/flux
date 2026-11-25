import Darwin
import Foundation

/// Moves a finished file into another folder without ever overwriting anything.
public enum FileMover {
    public static func move(_ file: URL, into folder: URL) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for _ in 0..<5 {
                let target = FileNaming.uniqueURL(for: file.lastPathComponent, in: folder)
                if renamex_np(file.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
                switch errno {
                case EEXIST: continue // someone took the name meanwhile
                case EXDEV: // another volume: copy, then remove the original
                    try FileManager.default.copyItem(at: file, to: target)
                    try FileManager.default.removeItem(at: file)
                    return target
                default:
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            throw POSIXError(.EEXIST)
        }.value
    }
}

/// Finds an existing file identical to a new download: same size first (cheap), then
/// the same SHA-256.
public enum DuplicateFinder {
    public struct Match: Sendable, Equatable {
        public var existing: URL
        /// SHA-256 of the new file (worth keeping).
        public var sha256: String
    }

    /// `known` are files Flux downloaded before (with their SHA-256 when already known);
    /// files in the new file's own folder are checked too.
    public static func findDuplicate(of file: URL, known: [(url: URL, sha256: String?)]) async throws -> Match? {
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let size = try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber, size.int64Value > 0
            else { return nil }
            let path = file.standardizedFileURL.path
            var candidates: [(url: URL, sha256: String?)] = []
            var seen: Set<String> = [path]
            func consider(_ url: URL, _ hash: String?) {
                let standardized = url.standardizedFileURL
                guard seen.insert(standardized.path).inserted,
                      let values = try? standardized.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true, Int64(values.fileSize ?? -1) == size.int64Value
                else { return }
                candidates.append((standardized, hash))
            }
            for entry in known { consider(entry.url, entry.sha256) }
            let siblings = (try? fm.contentsOfDirectory(
                at: file.deletingLastPathComponent(), includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])) ?? []
            for sibling in siblings { consider(sibling, nil) }
            guard !candidates.isEmpty else { return nil }

            let hash = try await Checksum.digest(of: file, algorithm: .sha256)
            for candidate in candidates.prefix(20) {
                try Task.checkCancellation()
                let other: String
                if let known = candidate.sha256 {
                    other = known
                } else {
                    other = try await Checksum.digest(of: candidate.url, algorithm: .sha256)
                }
                if other == hash { return Match(existing: candidate.url, sha256: hash) }
            }
            return nil
        }.value
    }
}

/// Unpacks downloaded archives with the system's `bsdtar`, which reads zip, tar (gz,
/// bz2, xz, zstd), 7z and most rar files and, by default, refuses entries with `..`
/// or absolute paths and won't write through symlinks.
public enum ArchiveExtractor {
    public enum ExtractError: LocalizedError, Equatable {
        case failed(String)
        case empty

        public var errorDescription: String? {
            switch self {
            case .failed(let message): message
            case .empty: "The archive is empty."
            }
        }
    }

    static let suffixes = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tgz", ".tbz", ".tbz2", ".txz",
                           ".zip", ".tar", ".7z", ".rar"]

    public static func canExtract(_ file: URL) -> Bool {
        let name = file.lastPathComponent.lowercased()
        return suffixes.contains { name.hasSuffix($0) && name.count > $0.count }
    }

    /// "photos.tar.gz" → "photos"
    static func baseName(of file: URL) -> String {
        let name = file.lastPathComponent
        let lower = name.lowercased()
        guard let suffix = suffixes.first(where: { lower.hasSuffix($0) }) else {
            return (name as NSString).deletingPathExtension
        }
        return String(name.dropLast(suffix.count))
    }

    /// Extracts next to the archive. A single top-level item is placed as is; several
    /// items go into a folder named after the archive. Nothing existing is overwritten.
    /// Extracted files are quarantined like the archive. Returns the new item.
    public static func extract(_ archive: URL, source: URL, tool: URL = URL(fileURLWithPath: "/usr/bin/tar")) async throws -> URL {
        let folder = archive.deletingLastPathComponent()
        let work = folder.appendingPathComponent(".flux-extract-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            // __MACOSX holds Finder's resource-fork copies ("._name"). macOS bsdtar tries to
            // merge those into the real files (even excluded ones) and fails on damaged ones.
            try await run(tool, ["-x", "--no-mac-metadata", "--exclude", "__MACOSX", "-f", archive.path, "-C", work.path])
            let result = try await Task.detached(priority: .utility) {
                try place(work, archive: archive, source: source)
            }.value
            return result
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    private static func place(_ work: URL, archive: URL, source: URL) throws -> URL {
        let fm = FileManager.default
        removeUnsafeLinks(in: work)
        try? fm.removeItem(at: work.appendingPathComponent("__MACOSX"))
        let items = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != ".DS_Store" }
        guard !items.isEmpty else { throw ExtractError.empty }
        quarantine(work, source: source)
        let folder = archive.deletingLastPathComponent()
        if items.count == 1, let only = items.first {
            let target = FileNaming.uniqueURL(for: only.lastPathComponent, in: folder)
            try fm.moveItem(at: only, to: target)
            try? fm.removeItem(at: work)
            return target
        }
        let target = FileNaming.uniqueURL(for: FileNaming.sanitize(baseName(of: archive)), in: folder)
        try fm.moveItem(at: work, to: target)
        return target
    }

    /// Symlinks that point outside the extracted folder would let later writes escape it.
    private static func removeUnsafeLinks(in root: URL) {
        let base = root.resolvingSymlinksInPath().path + "/"
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true,
                  let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            else { continue }
            let resolved = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : url.deletingLastPathComponent().appendingPathComponent(destination)
            if !resolved.standardizedFileURL.path.hasPrefix(base) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func quarantine(_ root: URL, source: URL) {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker { DownloadMetadata.apply(to: url, source: source) }
    }

    private static func run(_ tool: URL, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        // Drain stderr while it runs (a full pipe would block the tool); EOF means it exited.
        let output = await Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExtractError.failed(friendly(String(decoding: output, as: UTF8.self)))
        }
    }

    static func friendly(_ stderr: String) -> String {
        let lower = stderr.lowercased()
        if lower.contains("passphrase") || lower.contains("encrypt") || lower.contains("password") {
            return "The archive is password-protected. Open it in Finder to enter the password."
        }
        if lower.contains("unrecognized archive format") || lower.contains("not an archive") {
            return "This isn't a valid archive, or its format can't be extracted automatically."
        }
        let line = stderr.split(separator: "\n").first.map(String.init) ?? "Extraction failed."
        return line.replacingOccurrences(of: "tar: ", with: "")
    }
}
