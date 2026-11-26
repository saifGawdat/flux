import CryptoKit
import Darwin
import Foundation

/// What a rule does to a matching download after it finishes, besides choosing its
/// folder. Steps always run in the same order: rename, move, duplicate check, extract,
/// SHA-256, command, then notify / show in Finder / open.
public struct RuleActions: Codable, Sendable, Equatable, Hashable {
    /// New file name from a pattern such as `{date} {name}`; the extension is kept.
    public var rename: String?
    /// Extract archives even when extraction is off in Settings.
    public var extract: Bool
    /// Calculate the file's SHA-256 (shown in the Info window and exports).
    public var computeChecksum: Bool
    /// An approved command to run with the file.
    public var command: UUID?
    /// A notification for this download, even when "finished" notifications are off.
    public var notify: Bool
    public var reveal: Bool
    public var open: Bool

    public init(rename: String? = nil, extract: Bool = false, computeChecksum: Bool = false,
                command: UUID? = nil, notify: Bool = false, reveal: Bool = false, open: Bool = false) {
        self.rename = rename
        self.extract = extract
        self.computeChecksum = computeChecksum
        self.command = command
        self.notify = notify
        self.reveal = reveal
        self.open = open
    }

    public static let none = RuleActions()

    public var isEmpty: Bool {
        renamePattern == nil && !extract && !computeChecksum && command == nil && !notify && !reveal && !open
    }

    /// The rename pattern, if it says anything.
    public var renamePattern: String? {
        rename.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rename = try c.decodeIfPresent(String.self, forKey: .rename)
        extract = try c.decodeIfPresent(Bool.self, forKey: .extract) ?? false
        computeChecksum = try c.decodeIfPresent(Bool.self, forKey: .computeChecksum) ?? false
        command = try c.decodeIfPresent(UUID.self, forKey: .command)
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? false
        reveal = try c.decodeIfPresent(Bool.self, forKey: .reveal) ?? false
        open = try c.decodeIfPresent(Bool.self, forKey: .open) ?? false
    }

    /// "rename, extract, run “Upload”, notify" for rule summaries.
    public func summary(commandName: (UUID) -> String?) -> [String] {
        var parts: [String] = []
        if let pattern = renamePattern { parts.append("rename to “\(pattern)”") }
        if extract { parts.append("extract") }
        if computeChecksum { parts.append("SHA-256") }
        if let command { parts.append("run “\(commandName(command) ?? "missing command")”") }
        if notify { parts.append("notify") }
        if reveal { parts.append("show in Finder") }
        if open { parts.append("open") }
        return parts
    }
}

/// File names from patterns: `{name}`, `{title}`, `{site}`, `{date}`, `{year}`, `{month}`,
/// `{day}`, `{time}`, `{kind}`, `{playlist}`, `{index}`, `{id}`. Unknown tokens stay as typed.
public enum NamePattern {
    public static let tokens = ["name", "title", "site", "date", "year", "month", "day", "time", "kind", "playlist", "index", "id"]

    /// The new file name for `fileName`, keeping its extension; nil if the pattern yields
    /// nothing usable or the same name.
    public static func apply(_ pattern: String, to fileName: String, record: DownloadRecord,
                             date: Date = Date(), calendar: Calendar = .current) -> String? {
        let ns = fileName as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        func pad(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        let values: [String: String] = [
            "name": base,
            "title": record.title.map { FileNaming.sanitize($0) } ?? base,
            "site": ((record.referer ?? record.url).host() ?? "").replacingOccurrences(of: "www.", with: ""),
            "date": "\(parts.year ?? 0)-\(pad(parts.month))-\(pad(parts.day))",
            "year": "\(parts.year ?? 0)",
            "month": pad(parts.month),
            "day": pad(parts.day),
            "time": "\(pad(parts.hour))-\(pad(parts.minute))",
            "kind": record.category.title,
            "playlist": record.group?.title ?? "",
            "index": record.group == nil ? "" : pad(record.groupIndex + 1),
            "id": String(record.id.uuidString.prefix(8)).lowercased(),
        ]
        var output = ""
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{") {
            output += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            let token = rest[rest.index(after: open)..<close].lowercased()
            output += values[token] ?? String(rest[open...close])
            rest = rest[rest.index(after: close)...]
        }
        output += rest
        // Collapse what empty tokens leave behind ("  ", " - " at the ends).
        let collapsed = output.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_."))
        guard !collapsed.isEmpty else { return nil }
        let name = FileNaming.sanitize(ext.isEmpty ? collapsed : "\(collapsed).\(ext)")
        return name == fileName ? nil : name
    }
}

/// A shell command the user wrote and approved, run with a finished file. Flux runs a
/// command only while its text is exactly what the user approved, so nothing that
/// changes settings behind the app's back can slip a different command in.
public struct AutomationCommand: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    /// zsh script; the file is `$1` (and `$FLUX_FILE`).
    public var script: String
    /// SHA-256 of the script the user approved.
    public var approvedDigest: String?

    public init(id: UUID = UUID(), name: String, script: String, approvedDigest: String? = nil) {
        self.id = id
        self.name = name
        self.script = script
        self.approvedDigest = approvedDigest
    }

    public var isApproved: Bool { approvedDigest == Self.digest(script) }

    public mutating func approve() { approvedDigest = Self.digest(script) }

    public static func digest(_ script: String) -> String {
        SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Runs approved commands. The file is passed as an argument, never pasted into the
/// script, so names with quotes or `$(…)` can't run anything.
public enum CommandRunner {
    public static let timeout: Duration = .seconds(300)
    /// Output kept for the message shown in Flux.
    static let outputLimit = 64 * 1024

    public enum Failure: LocalizedError, Equatable {
        case notApproved(String)
        case failed(String, status: Int32, output: String)
        case timedOut(String)

        public var errorDescription: String? {
            switch self {
            case .notApproved(let name): "“\(name)” changed since you approved it, so it didn't run. Approve it again in Settings › Automation."
            case .failed(let name, let status, let output):
                "“\(name)” failed (exit \(status))" + (output.isEmpty ? "." : ": \(output)")
            case .timedOut(let name): "“\(name)” was stopped after 5 minutes."
            }
        }
    }

    /// Runs the command and returns the last line it printed.
    public static func run(
        _ command: AutomationCommand, file: URL, record: DownloadRecord,
        shell: URL = URL(fileURLWithPath: "/bin/zsh"), timeout: Duration = CommandRunner.timeout
    ) async throws -> String {
        guard command.isApproved else { throw Failure.notApproved(command.name) }
        let process = Process()
        process.executableURL = shell
        // -f: no startup files. `$0` is "flux", `$1` the file.
        process.arguments = ["-f", "-c", command.script, "flux", file.path]
        process.currentDirectoryURL = file.deletingLastPathComponent()
        process.environment = environment(file: file, record: record)
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        // Exit is reported by Foundation itself; no thread waits on the process.
        let exited = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in
                continuation.yield()
                continuation.finish()
            }
        }
        let reader = OutputCollector(output.fileHandleForReading, limit: outputLimit)
        try process.run()

        let pid = process.processIdentifier
        let timer = Task { () -> Bool in
            do { try await Task.sleep(for: timeout) } catch { return false }
            kill(pid, SIGTERM)
            return true
        }
        // Wait for the command itself, not for end-of-output: a background program it
        // started (`open …`, `cmd &`) keeps the pipe open long after the command is done.
        for await _ in exited { break }
        timer.cancel()
        let data = reader.finish()
        let timedOut = await timer.value
        let text = String(decoding: data, as: UTF8.self)
        let lastLine = text.split(whereSeparator: \.isNewline).last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if timedOut { throw Failure.timedOut(command.name) }
        guard process.terminationStatus == 0 else {
            throw Failure.failed(command.name, status: process.terminationStatus, output: String(lastLine.prefix(200)))
        }
        return String(lastLine.prefix(200))
    }

    /// Collects a pipe's output while a process runs, keeping only the last `limit` bytes.
    final class OutputCollector: @unchecked Sendable {
        private let handle: FileHandle
        private let limit: Int
        private let lock = NSLock()
        private var data = Data()

        init(_ handle: FileHandle, limit: Int) {
            self.handle = handle
            self.limit = limit
            handle.readabilityHandler = { [weak self] handle in self?.append(handle.availableData) }
        }

        private func append(_ chunk: Data) {
            lock.withLock {
                data.append(chunk)
                if data.count > limit { data.removeFirst(data.count - limit) }
            }
        }

        /// Stops reading and returns what arrived, plus whatever is still buffered in
        /// the pipe, without waiting for other holders of the pipe to close it.
        func finish() -> Data {
            handle.readabilityHandler = nil
            let fd = handle.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                append(Data(buffer[0..<count]))
            }
            return lock.withLock { data }
        }
    }

    static func environment(file: URL, record: DownloadRecord) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": inherited["HOME"] ?? NSHomeDirectory(),
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "FLUX_FILE": file.path,
            "FLUX_NAME": file.lastPathComponent,
            "FLUX_URL": record.url.absoluteString,
            "FLUX_SITE": (record.referer ?? record.url).host() ?? "",
            "FLUX_KIND": record.category.rawValue,
            "FLUX_ID": record.id.uuidString.lowercased(),
        ]
        if let user = inherited["USER"] { env["USER"] = user }
        if let hash = record.contentHash { env["FLUX_SHA256"] = hash }
        return env
    }
}
