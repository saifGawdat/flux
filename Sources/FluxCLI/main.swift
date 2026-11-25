import Foundation
import FluxCore

// `flux`: control the Flux app from Terminal. Every command goes to the running app over
// its control socket, so the window and the command line always show the same downloads.

let usage = """
flux: control the Flux download manager

Usage:
  flux add <link>... [-o FOLDER] [-n NAME] [-q QUEUE] [--paused] [--wait]
  flux add -                     read links from standard input
  flux import <file>             add links from a .txt, .csv or .json file [-q QUEUE] [--paused]
  flux export [file] [--all]     save the list as .txt, .csv or .json (stdout when no file)
  flux list [--all]              downloads (--all includes History)
  flux status <id>...            details of downloads
  flux pause|resume|cancel <id>... | all
  flux remove <id>... [--trash]  remove from the list (--trash also trashes finished files)
  flux limit [<speed> | off]     overall speed limit, e.g. 2M, 500K
  flux queues                    named queues and what's waiting in them
  flux queue start|stop <name>
  flux ping                      check that Flux is running

IDs are the first characters shown by flux list. Add --json to any command for
machine-readable output. If Flux isn't running, flux opens it.
"""

struct Usage: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Splits arguments into words, flags and flag values.
struct Arguments {
    var words: [String] = []
    var flags: Set<String> = []
    var values: [String: String] = [:]

    static let valued: Set<String> = ["-o", "--output", "--dir", "-n", "--name", "-q", "--queue", "--format"]

    init(_ raw: [String]) throws {
        var index = 0
        while index < raw.count {
            let arg = raw[index]
            if Self.valued.contains(arg) {
                guard index + 1 < raw.count else { throw Usage("\(arg) needs a value.") }
                values[Self.canonical(arg)] = raw[index + 1]
                index += 2
                continue
            }
            if arg.hasPrefix("-"), arg != "-", Double(arg) == nil {
                flags.insert(arg)
            } else {
                words.append(arg)
            }
            index += 1
        }
    }

    static func canonical(_ flag: String) -> String {
        switch flag {
        case "-o", "--output", "--dir": "folder"
        case "-n", "--name": "name"
        case "-q", "--queue": "queue"
        default: String(flag.drop { $0 == "-" })
        }
    }

    func has(_ names: String...) -> Bool { names.contains { flags.contains($0) } }
}

// MARK: Talking to the app

let socketURL = ControlProtocol.defaultSocketURL

func send(_ request: ControlRequest) throws -> ControlResponse {
    do {
        return try ControlClient.send(request, socketURL: socketURL)
    } catch ControlError.notRunning {
        try launchFlux()
        return try ControlClient.send(request, socketURL: socketURL)
    }
}

/// Opens Flux in the background and waits for it to accept commands.
func launchFlux() throws {
    FileHandle.standardError.write(Data("Opening Flux…\n".utf8))
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "-b", "app.flux.Flux"]
    open.standardError = FileHandle.nullDevice
    try open.run()
    open.waitUntilExit()
    guard open.terminationStatus == 0 else {
        throw Failure("Flux isn’t running, and it couldn’t be opened. Is Flux.app installed?")
    }
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        if ControlClient.isServing(socketURL) { return }
        Thread.sleep(forTimeInterval: 0.25)
    }
    throw Failure("Flux opened but isn’t accepting commands yet. Try again in a moment.")
}

// MARK: Formatting

func bytes(_ n: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    return formatter.string(fromByteCount: n)
}

/// Progress lines redraw in place, so they only go to a terminal.
let stderrIsTerminal = isatty(STDERR_FILENO) == 1

func speed(_ bytesPerSecond: Double) -> String {
    bytesPerSecond < 1 ? "" : ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .decimal) + "/s"
}

func progress(_ d: DownloadSummary) -> String {
    if d.status == "completed" { return d.totalBytes.map(bytes) ?? "done" }
    guard let total = d.totalBytes, total > 0 else { return d.receivedBytes > 0 ? bytes(d.receivedBytes) : "" }
    let percent = Int(Double(d.receivedBytes) / Double(total) * 100)
    return "\(percent)% of \(bytes(total))"
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? String(text.prefix(width)) : text + String(repeating: " ", count: width - text.count)
}

func printTable(_ downloads: [DownloadSummary]) {
    guard !downloads.isEmpty else {
        print("No downloads.")
        return
    }
    print(pad("ID", 10) + pad("STATUS", 13) + pad("PROGRESS", 20) + pad("SPEED", 12) + "NAME")
    for d in downloads {
        var status = d.status
        if let queue = d.queue, d.status == "queued" { status = "queued·\(queue)" }
        print(pad(d.shortID, 10) + pad(status, 13) + pad(progress(d), 20) + pad(speed(d.bytesPerSecond), 12) + d.name)
    }
}

func printDetails(_ d: DownloadSummary) {
    print(d.name)
    print("  ID:       \(d.id)")
    print("  Status:   \(d.status)\(d.detail.map { " (\($0))" } ?? "")")
    if !progress(d).isEmpty { print("  Progress: \(progress(d))\(d.bytesPerSecond >= 1 ? " at \(speed(d.bytesPerSecond))" : "")") }
    print("  Link:     \(d.url)")
    if let path = d.path { print("  File:     \(path)") }
    if let queue = d.queue { print("  Queue:    \(queue)") }
    if let error = d.error { print("  Error:    \(error)") }
}

func emit(_ response: ControlResponse, json: Bool) throws {
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(response), as: UTF8.self))
    } else if let message = response.message {
        print(message)
    }
    if !response.ok { throw Failure(response.error ?? "Flux couldn’t do that.") }
}

/// "2M", "500k", "1.5MB", "750KB/s" → bytes per second (decimal units, like Flux shows).
func parseSpeed(_ text: String) -> Int64? {
    var t = text.lowercased().replacingOccurrences(of: "/s", with: "").replacingOccurrences(of: "b", with: "")
    var multiplier: Double = 1
    if let last = t.last, "kmg".contains(last) {
        multiplier = ["k": 1e3, "m": 1e6, "g": 1e9][String(last)]!
        t.removeLast()
    }
    guard let value = Double(t.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
    return Int64(value * multiplier)
}

func absoluteFolder(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return expanded }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded).standardizedFileURL.path
}

/// Polls until every download has finished, showing one progress line.
func wait(for ids: [String], json: Bool) throws -> Int32 {
    var last = ""
    while true {
        let response = try send(ControlRequest(.status, targets: ids))
        guard response.ok, let downloads = response.downloads else { throw Failure(response.error ?? "Lost track of the downloads.") }
        let done = downloads.filter(\.isFinished)
        if done.count == downloads.count {
            if !json && !last.isEmpty && stderrIsTerminal { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
            for d in downloads {
                if json { continue }
                switch d.status {
                case "completed": print("✓ \(d.name)\(d.path.map { " → \($0)" } ?? "")")
                default: print("✗ \(d.name): \(d.error ?? d.status)")
                }
            }
            if json { try emit(ControlResponse(downloads: downloads), json: true) }
            return downloads.allSatisfy { $0.status == "completed" } ? 0 : 1
        }
        if !json && stderrIsTerminal {
            let received = downloads.reduce(Int64(0)) { $0 + $1.receivedBytes }
            let total = downloads.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
            let rate = downloads.reduce(0) { $0 + $1.bytesPerSecond }
            let size = total > 0 ? "\(bytes(received)) of \(bytes(total))" : bytes(received)
            let line = ["\(done.count)/\(downloads.count) done", size, speed(rate)].filter { !$0.isEmpty }.joined(separator: " · ")
            if line != last {
                FileHandle.standardError.write(Data("\r\u{1B}[K\(line)".utf8))
                last = line
            }
        }
        Thread.sleep(forTimeInterval: 1)
    }
}

// MARK: Commands

func run(_ raw: [String]) throws -> Int32 {
    let args = try Arguments(raw)
    let json = args.has("--json")
    guard let command = args.words.first else {
        print(usage)
        return args.has("-h", "--help") ? 0 : 2
    }
    if args.has("-h", "--help") || command == "help" {
        print(usage)
        return 0
    }
    let rest = Array(args.words.dropFirst())

    switch command {
    case "add", "import":
        var entries: [LinkListEntry]
        if command == "import" {
            guard let file = rest.first else { throw Usage("Name the file to import.") }
            entries = try LinkList.read(URL(fileURLWithPath: absoluteFolder(file)))
        } else if rest == ["-"] {
            entries = try LinkList.parse(FileHandle.standardInput.readDataToEndOfFile())
        } else {
            guard !rest.isEmpty else { throw Usage("Give at least one link.") }
            entries = try rest.map { text in
                guard let url = URL(string: text), url.scheme == "http" || url.scheme == "https", url.host() != nil else {
                    throw Failure("“\(text)” isn’t an http or https link.")
                }
                return LinkListEntry(url: url)
            }
        }
        if let name = args.values["name"] {
            guard entries.count == 1 else { throw Usage("--name works with one link at a time.") }
            entries[0].fileName = name
        }
        if let folder = args.values["folder"] {
            let path = absoluteFolder(folder)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw Failure("No folder at \(path).")
            }
            for index in entries.indices { entries[index].directory = URL(fileURLWithPath: path, isDirectory: true) }
        }
        let response = try send(ControlRequest(.add, entries: entries, queue: args.values["queue"], paused: args.has("--paused")))
        if args.has("--wait") {
            guard response.ok else { try emit(response, json: json); return 1 }
            if !json, let message = response.message { print(message) }
            fflush(stdout)
            return try wait(for: response.ids ?? [], json: json)
        }
        try emit(response, json: json)
        if !json, let downloads = response.downloads, downloads.count <= 10 {
            for d in downloads { print("  \(d.shortID)  \(d.name)") }
        }

    case "list", "ls":
        let response = try send(ControlRequest(.list, includeHistory: args.has("--all", "-a")))
        if json { try emit(response, json: true) } else {
            guard response.ok else { throw Failure(response.error ?? "") }
            printTable(response.downloads ?? [])
        }

    case "status", "info":
        guard !rest.isEmpty else { throw Usage("Name a download: flux status <id>.") }
        let response = try send(ControlRequest(.status, targets: rest))
        if json { try emit(response, json: true) } else {
            guard response.ok else { throw Failure(response.error ?? "") }
            for (index, d) in (response.downloads ?? []).enumerated() {
                if index > 0 { print("") }
                printDetails(d)
            }
        }

    case "pause", "resume", "cancel", "remove", "rm":
        guard !rest.isEmpty else { throw Usage("Name downloads by ID, or use all.") }
        let kind: ControlRequest.Command = switch command {
        case "pause": .pause
        case "resume": .resume
        case "cancel": .cancel
        default: .remove
        }
        try emit(try send(ControlRequest(kind, targets: rest, trash: args.has("--trash"))), json: json)

    case "limit":
        var limit: Int64? = nil
        if let value = rest.first {
            if ["off", "none", "0", "unlimited"].contains(value.lowercased()) {
                limit = 0
            } else {
                guard let parsed = parseSpeed(value) else { throw Usage("Speeds look like 2M or 500K (bytes per second).") }
                limit = parsed
            }
        }
        try emit(try send(ControlRequest(.limit, speedLimit: limit)), json: json)

    case "queues":
        let response = try send(ControlRequest(.queues))
        if json { try emit(response, json: true) } else {
            guard response.ok else { throw Failure(response.error ?? "") }
            for q in response.queues ?? [] {
                let state = q.isMain ? "always on" : (q.isRunning ? "started" : "stopped")
                var line = pad(q.name, 18) + pad(state, 11) + "\(q.active) running, \(q.waiting) waiting"
                if let schedule = q.schedule { line += " · \(schedule)" }
                print(line)
            }
        }

    case "queue":
        guard rest.count >= 2, ["start", "stop"].contains(rest[0]) else { throw Usage("Use flux queue start <name> or flux queue stop <name>.") }
        let name = rest.dropFirst().joined(separator: " ")
        try emit(try send(ControlRequest(rest[0] == "start" ? .startQueue : .stopQueue, targets: [name])), json: json)

    case "export":
        let file = rest.first
        let format = args.values["format"].flatMap { LinkListFormat(rawValue: $0) ?? LinkListFormat(fileExtension: $0) }
            ?? file.flatMap { LinkListFormat(fileExtension: ($0 as NSString).pathExtension) } ?? .text
        let response = try send(ControlRequest(.export, includeHistory: args.has("--all", "-a"), format: format))
        guard response.ok, let text = response.text else { throw Failure(response.error ?? "Nothing to export.") }
        if let file {
            let url = URL(fileURLWithPath: absoluteFolder(file))
            try Data(text.utf8).write(to: url, options: .atomic)
            if !json { print("\(response.message ?? "Exported.") Saved \(url.path)") }
        } else {
            print(text, terminator: "")
        }

    case "ping":
        // Doesn't open Flux: only reports whether it's running.
        let response = try ControlClient.send(ControlRequest(.ping), socketURL: socketURL)
        try emit(response, json: json)

    default:
        throw Usage("Unknown command “\(command)”. Run flux help.")
    }
    return 0
}

do {
    exit(try run(Array(CommandLine.arguments.dropFirst())))
} catch let error as Usage {
    FileHandle.standardError.write(Data("flux: \(error.description)\n".utf8))
    exit(2)
} catch let error as Failure {
    FileHandle.standardError.write(Data("flux: \(error.description)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("flux: \(error.localizedDescription)\n".utf8))
    exit(1)
}
