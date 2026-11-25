import CryptoKit
import Foundation
import Testing
@testable import FluxCore

struct Timeout: Error, CustomStringConvertible {
    let what: String
    var description: String { "Timed out waiting for \(what)" }
}

func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flux-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

func sha256(of url: URL?) throws -> String { sha256(try Data(contentsOf: try #require(url))) }

/// Polls `condition` until it holds or the timeout expires.
func eventually(_ what: String, timeout: TimeInterval = 30, _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw Timeout(what: what)
}

/// Runs scripts/range_server.py on a random local port.
final class TestServer: Sendable {
    let root: URL
    let port: Int
    private let process: Process

    init(noRange: Bool = false, throttle: Double = 0) throws {
        root = try tempDir()
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/range_server.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = ["python3", "-I", script.path, "--root", root.path, "--port", "0"]
        if noRange { args.append("--no-range") }
        if throttle > 0 { args += ["--throttle", String(throttle)] }
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        var buffer = Data()
        while !buffer.contains(UInt8(ascii: "\n")) {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { throw Timeout(what: "test server start") }
            buffer.append(chunk)
        }
        guard let port = Int(String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Timeout(what: "test server port")
        }
        self.port = port
        self.process = process
    }

    deinit {
        process.terminate()
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func addFile(_ name: String, size: Int) throws -> Data {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try data.write(to: root.appendingPathComponent(name))
        return data
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(path)")! }
}

let fastOptions: DownloadJob.Options = {
    var o = DownloadJob.Options()
    o.minPieceSize = 64 * 1024
    o.progressInterval = .milliseconds(100)
    o.checkpointInterval = 0.2
    o.retryBaseDelay = 0.05
    return o
}()

/// Collects every snapshot a job emits.
final class SnapshotLog: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [DownloadJob.Snapshot] = []

    func append(_ s: DownloadJob.Snapshot) { lock.withLock { snapshots.append(s) } }
    var all: [DownloadJob.Snapshot] { lock.withLock { snapshots } }
    var last: DownloadJob.Snapshot? { lock.withLock { snapshots.last } }
}

func makeJob(_ record: DownloadRecord, options: DownloadJob.Options = fastOptions) -> (DownloadJob, SnapshotLog) {
    let log = SnapshotLog()
    return (DownloadJob(record: record, options: options) { log.append($0) }, log)
}

/// Waits until the job reports a terminal status and returns that record.
func finish(_ job: DownloadJob, _ log: SnapshotLog, timeout: TimeInterval = 30) async throws -> DownloadRecord {
    try await eventually("job to finish", timeout: timeout) {
        [.completed, .failed].contains(log.last?.record.status)
    }
    return try #require(log.last?.record)
}
