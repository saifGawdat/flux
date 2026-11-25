import AppKit
import FluxCore
import SwiftUI

/// Settings row for the `flux` command-line tool: whether it's installed, and installing it.
struct CommandLineToolRow: View {
    @Environment(AppModel.self) private var model
    @State private var installed: URL? = CommandLineTool.installedLink()
    @State private var message: String?

    var body: some View {
        LabeledContent {
            if let helper = CommandLineTool.helper {
                if installed != nil {
                    Text("Installed").foregroundStyle(.secondary)
                } else {
                    Button("Install") { install(helper) }
                }
            } else {
                Text("Part of Flux.app").foregroundStyle(.secondary)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("flux command")
                Text(installed.map { "Type flux help in Terminal. Linked at \($0.path)." }
                     ?? "Add, pause and list downloads from Terminal and scripts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        if model.controlSocket == nil {
            Text("Flux isn’t accepting commands right now (another copy of Flux may be running).")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func install(_ helper: URL) {
        switch CommandLineTool.install(helper) {
        case .success(let link):
            installed = link
            message = nil
        case .failure:
            let command = "sudo ln -sf '\(helper.path)' /usr/local/bin/flux"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            model.clipboard.ignoreCurrentContents()
            message = "No folder on your PATH is writable without your password. This command is on your clipboard; paste it in Terminal:\n\(command)"
        }
    }
}

enum CommandLineTool {
    /// The tool inside the app bundle (absent when running from `swift run`).
    static var helper: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/flux")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static let candidateFolders = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// An existing `flux` link pointing into a Flux.app.
    static func installedLink() -> URL? {
        for folder in candidateFolders {
            let link = URL(fileURLWithPath: folder).appendingPathComponent("flux")
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
               target.hasSuffix("/Contents/Helpers/flux") {
                return link
            }
        }
        return nil
    }

    struct NotWritable: Error {}

    /// Links `flux` into the first writable folder on the usual PATH. Never replaces a
    /// `flux` that isn't Flux's own link.
    static func install(_ helper: URL) -> Result<URL, NotWritable> {
        let fm = FileManager.default
        for folder in candidateFolders where fm.isWritableFile(atPath: folder) {
            let link = URL(fileURLWithPath: folder).appendingPathComponent("flux")
            if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                guard existing.hasSuffix("/Contents/Helpers/flux") else { continue }
                try? fm.removeItem(at: link)
            } else if fm.fileExists(atPath: link.path) {
                continue
            }
            if (try? fm.createSymbolicLink(at: link, withDestinationURL: helper)) != nil { return .success(link) }
        }
        return .failure(NotWritable())
    }
}
