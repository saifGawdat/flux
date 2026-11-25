import CryptoKit
import Foundation

/// A checksum the user expects the finished file to have (from a download page,
/// a `SHA256SUMS` file, …). The algorithm is recognized from the hash length.
public struct Checksum: Codable, Sendable, Equatable, Hashable, CustomStringConvertible {
    public enum Algorithm: String, Codable, Sendable, CaseIterable {
        case md5, sha1, sha256, sha512

        public var title: String {
            switch self {
            case .md5: "MD5"
            case .sha1: "SHA-1"
            case .sha256: "SHA-256"
            case .sha512: "SHA-512"
            }
        }

        var hexLength: Int {
            switch self {
            case .md5: 32
            case .sha1: 40
            case .sha256: 64
            case .sha512: 128
            }
        }
    }

    public var algorithm: Algorithm
    /// Lowercase hex digest.
    public var hex: String

    public init(algorithm: Algorithm, hex: String) {
        self.algorithm = algorithm
        self.hex = hex.lowercased()
    }

    /// "sha256:9f86d0…", the stored form.
    public var description: String { "\(algorithm.rawValue):\(hex)" }

    /// Reads what people paste: a bare hex digest, `sha256:<hex>`, `SHA-256: <hex>`,
    /// or a line of `shasum` output (`<hex>  file.zip`). Returns nil for anything else.
    public static func parse(_ text: String) -> Checksum? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var named: Algorithm?
        let lower = trimmed.lowercased()
        for algorithm in Algorithm.allCases {
            let spellings = [algorithm.rawValue, algorithm.title.lowercased()]
            if spellings.contains(where: { lower.hasPrefix($0) }) { named = algorithm }
        }
        let hexDigits = Set("0123456789abcdef")
        let tokens = lower.split(whereSeparator: { " \t\n:=()*".contains($0) }).map(String.init)
        guard let digest = tokens.first(where: { token in
            token.count >= 32 && token.allSatisfy(hexDigits.contains)
                && Algorithm.allCases.contains { $0.hexLength == token.count }
        }) else { return nil }
        let byLength = Algorithm.allCases.first { $0.hexLength == digest.count }!
        if let named, named != byLength { return nil }
        return Checksum(algorithm: byLength, hex: digest)
    }

    /// Hashes a file in 1 MB chunks. Cancellable; run it off any latency-sensitive actor.
    public static func digest(of file: URL, algorithm: Algorithm) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = AnyHasher(algorithm)
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(chunk)
            }
            return hasher.finalize()
        }.value
    }

    /// True when `file` has this checksum.
    public func matches(_ file: URL) async throws -> Bool {
        try await Self.digest(of: file, algorithm: algorithm) == hex
    }
}

private struct AnyHasher {
    private var md5: Insecure.MD5?
    private var sha1: Insecure.SHA1?
    private var sha256: SHA256?
    private var sha512: SHA512?

    init(_ algorithm: Checksum.Algorithm) {
        switch algorithm {
        case .md5: md5 = Insecure.MD5()
        case .sha1: sha1 = Insecure.SHA1()
        case .sha256: sha256 = SHA256()
        case .sha512: sha512 = SHA512()
        }
    }

    mutating func update(_ data: Data) {
        md5?.update(data: data)
        sha1?.update(data: data)
        sha256?.update(data: data)
        sha512?.update(data: data)
    }

    func finalize() -> String {
        let bytes: [UInt8] = if let md5 { Array(md5.finalize()) }
            else if let sha1 { Array(sha1.finalize()) }
            else if let sha256 { Array(sha256.finalize()) }
            else { Array(sha512!.finalize()) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
