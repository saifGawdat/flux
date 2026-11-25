import Darwin
import Foundation

/// Listens on a Unix domain socket and answers `ControlRequest`s. The socket file is
/// readable and writable only by its owner, and every connection is checked to come
/// from the same user (`getpeereid`), so other accounts on the Mac can't drive Flux.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    public let socketURL: URL
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    /// Connections waiting this long without sending a full request are closed.
    private let idleTimeout: TimeInterval

    public init(socketURL: URL = ControlProtocol.defaultSocketURL, idleTimeout: TimeInterval = 60) {
        self.socketURL = socketURL
        self.idleTimeout = idleTimeout
    }

    deinit { stop() }

    public func start(handler: @escaping Handler) throws {
        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw ControlError.pathTooLong(path) }
        let folder = socketURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try removeStaleSocket(at: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.errno("socket") }
        var address = Self.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let error = ControlError.errno("bind \(path)")
            close(fd)
            throw error
        }
        // Owner only. Connections are also checked by user ID, which covers the moment
        // between bind and chmod.
        guard chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let error = ControlError.errno("listen \(path)")
            close(fd)
            unlink(path)
            throw error
        }
        lock.withLock { listenFD = fd }
        let thread = Thread { [idleTimeout] in Self.acceptLoop(fd, idleTimeout: idleTimeout, handler: handler) }
        thread.name = "app.flux.control"
        thread.start()
        Log.manager.info("Accepting commands at \(path, privacy: .public)")
    }

    public func stop() {
        let fd = lock.withLock { () -> Int32 in
            let fd = listenFD
            listenFD = -1
            return fd
        }
        guard fd >= 0 else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(socketURL.path)
    }

    /// A socket left behind by a crash is removed; a live one means another Flux is
    /// running; anything that isn't a socket is left alone.
    private func removeStaleSocket(at path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw ControlError.pathInUse(path) }
        if let fd = try? ControlClient.connect(path) {
            close(fd)
            throw ControlError.alreadyRunning
        }
        unlink(path)
    }

    /// Connections served at once; more are closed straight away, so a misbehaving client
    /// can't tie up threads.
    static let maxConnections = 16

    private static func acceptLoop(_ listener: Int32, idleTimeout: TimeInterval, handler: @escaping Handler) {
        let slots = DispatchSemaphore(value: maxConnections)
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return // closed by stop()
            }
            guard slots.wait(timeout: .now()) == .success else {
                close(client)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async {
                defer { slots.signal() }
                Self.serve(client, idleTimeout: idleTimeout, handler: handler)
            }
        }
    }

    private static func serve(_ fd: Int32, idleTimeout: TimeInterval, handler: @escaping Handler) {
        defer { close(fd) }
        var uid = uid_t(), gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
            Log.manager.error("Refused a control connection from user \(uid)")
            return
        }
        ControlClient.configure(fd, timeout: idleTimeout)
        var buffer = Data()
        while true {
            guard let line = try? ControlClient.readLine(fd, buffer: &buffer) else { return }
            let response: ControlResponse
            if let request = try? JSONDecoder().decode(ControlRequest.self, from: line) {
                if let version = request.version, version > ControlProtocol.version {
                    response = .failure("This version of Flux is older than the flux tool. Update Flux.")
                } else {
                    response = Self.run(request, handler)
                }
            } else {
                response = .failure("Flux didn’t understand the request.")
            }
            guard (try? ControlClient.writeLine(fd, response)) != nil else { return }
        }
    }

    /// Runs the async handler from this blocking connection thread (not a Swift
    /// concurrency thread, so waiting here doesn't starve the cooperative pool).
    private static func run(_ request: ControlRequest, _ handler: @escaping Handler) -> ControlResponse {
        final class Box: @unchecked Sendable { var value: ControlResponse? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.value = await handler(request)
            done.signal()
        }
        done.wait()
        return box.value ?? .failure("No response.")
    }

    static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }
}

/// Sends requests to a running Flux.
public enum ControlClient {
    /// One request, one response. Throws `ControlError.notRunning` when nobody listens.
    public static func send(_ request: ControlRequest, socketURL: URL = ControlProtocol.defaultSocketURL,
                            timeout: TimeInterval = 120) throws -> ControlResponse {
        let fd = try connect(socketURL.path)
        defer { close(fd) }
        configure(fd, timeout: timeout)
        try writeLine(fd, request)
        var buffer = Data()
        let line = try readLine(fd, buffer: &buffer)
        guard let response = try? JSONDecoder().decode(ControlResponse.self, from: line) else { throw ControlError.badResponse }
        return response
    }

    /// True when a Flux is listening at the socket.
    public static func isServing(_ socketURL: URL = ControlProtocol.defaultSocketURL) -> Bool {
        guard let fd = try? connect(socketURL.path) else { return false }
        close(fd)
        return true
    }

    static func connect(_ path: String) throws -> Int32 {
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw ControlError.pathTooLong(path) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.errno("socket") }
        var address = ControlServer.address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            if code == ENOENT || code == ECONNREFUSED { throw ControlError.notRunning }
            throw ControlError.system("connect: \(String(cString: strerror(code)))")
        }
        return fd
    }

    static func configure(_ fd: Int32, timeout: TimeInterval) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func writeLine(_ fd: Int32, _ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        var data = try encoder.encode(value)
        guard data.count < ControlProtocol.maxMessageSize else { throw ControlError.tooLarge }
        data.append(UInt8(ascii: "\n"))
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ControlError.errno("write")
                }
                offset += written
            }
        }
    }

    /// Reads up to the next newline. Bytes after it stay in `buffer` for the next call.
    static func readLine(_ fd: Int32, buffer: inout Data) throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                return Data(line)
            }
            guard buffer.count < ControlProtocol.maxMessageSize else { throw ControlError.tooLarge }
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw ControlError.errno("read")
            }
            if count == 0 { throw ControlError.system("Connection closed.") }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
