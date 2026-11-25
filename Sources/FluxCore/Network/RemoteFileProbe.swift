import Foundation

/// What a link serves, from its response headers alone (no body is downloaded).
public struct RemoteFileInfo: Sendable, Equatable {
    /// Total size, when the server states it.
    public var totalBytes: Int64?
    public var supportsRanges: Bool
    /// The link opens an HTML page rather than a file.
    public var isWebPage: Bool
    public var statusCode: Int

    public init(totalBytes: Int64?, supportsRanges: Bool, isWebPage: Bool, statusCode: Int) {
        self.totalBytes = totalBytes
        self.supportsRanges = supportsRanges
        self.isWebPage = isWebPage
        self.statusCode = statusCode
    }

    /// Whether a partly downloaded file of `expectedBytes` can continue from this link.
    public func canContinue(expectedBytes: Int64?) -> Bool {
        guard let expectedBytes, let totalBytes else { return false }
        return supportsRanges && totalBytes == expectedBytes
    }
}

public enum RemoteFileProbe {
    public enum ProbeError: LocalizedError, Equatable {
        case http(Int)
        public var errorDescription: String? {
            switch self {
            case .http(let status):
                status == 401 || status == 403
                    ? "This link refuses access too (HTTP \(status))."
                    : "The server answered HTTP \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))."
            }
        }
    }

    /// Asks for the first byte (`Range: bytes=0-0`) and reads only the headers, the same
    /// way the download engine starts, so the answer matches what a download would see.
    public static func probe(_ url: URL, referer: URL? = nil, session: URLSession = .shared) async throws -> RemoteFileInfo {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("Flux/1.0", forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        let (bytes, response) = try await session.bytes(for: request)
        bytes.task.cancel() // headers are all we need
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw ProbeError.http(http.statusCode) }
        let range = http.value(forHTTPHeaderField: "Content-Range").flatMap(ContentRange.parse)
        let isPartial = http.statusCode == 206 && range != nil
        let length = http.expectedContentLength
        return RemoteFileInfo(
            totalBytes: isPartial ? range?.total : (length >= 0 ? length : nil),
            supportsRanges: isPartial && range?.total != nil,
            isWebPage: http.mimeType?.lowercased() == "text/html",
            statusCode: http.statusCode)
    }
}
