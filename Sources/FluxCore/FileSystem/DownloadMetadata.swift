import CoreServices
import Darwin
import Foundation

enum DownloadMetadata {
    /// Marks a finished file as downloaded from `source`: sets the quarantine attribute
    /// (so Gatekeeper checks downloaded apps) and Finder's “Where from”.
    static func apply(to file: URL, source: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Flux",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineDataURLKey as String: source,
        ]
        var target = file
        do {
            try target.setResourceValues(values)
        } catch {
            Log.engine.error("Couldn't set quarantine on \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        guard let plist = try? PropertyListSerialization.data(
            fromPropertyList: [source.absoluteString], format: .binary, options: 0)
        else { return }
        _ = plist.withUnsafeBytes { buffer in
            setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", buffer.baseAddress, buffer.count, 0, 0)
        }
    }
}
