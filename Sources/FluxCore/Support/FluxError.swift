import Foundation
import OSLog

public enum FluxError: LocalizedError, Equatable {
    case unsupportedURL(String)
    case unknownDownload(UUID)
    case databaseFromNewerVersion(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedURL(let url):
            "“\(url)” isn’t a valid http or https link."
        case .unknownDownload(let id):
            "No download with ID \(id.uuidString)."
        case .databaseFromNewerVersion(let found, let supported):
            "The Flux database was created by a newer version of Flux (schema \(found), this version supports \(supported))."
        }
    }
}

enum Log {
    static let engine = Logger(subsystem: "app.flux", category: "engine")
    static let manager = Logger(subsystem: "app.flux", category: "manager")
    static let persistence = Logger(subsystem: "app.flux", category: "persistence")
}
