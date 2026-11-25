import AppKit
import FluxCore
import SwiftUI

/// Settings › Automation: commands that rules can run on finished files.
struct AutomationSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: AutomationCommand?

    var body: some View {
        Form {
            Section {
                if model.settings.commands.isEmpty {
                    Text("No commands yet. A command can, for example, upload finished files, convert them, or add them to an app’s library.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.settings.commands) { command in
                    CommandRow(command: command, usedBy: rules(using: command.id),
                               onEdit: { editing = command },
                               onDelete: { delete(command.id) })
                }
                HStack {
                    Spacer()
                    Button("New Command…") { editing = AutomationCommand(name: "", script: "") }
                }
            } header: {
                Text("Commands")
            } footer: {
                Text("A rule (Settings › Organize) runs a command when a matching download finishes. Commands run as you, with the file as $1; Flux runs one only exactly as you approved it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fluxBackground()
        .frame(minHeight: 360)
        .sheet(item: $editing) { command in
            CommandEditor(command: command, isNew: !model.settings.commands.contains { $0.id == command.id }) { saved in
                model.updateSettings { settings in
                    if let index = settings.commands.firstIndex(where: { $0.id == saved.id }) {
                        settings.commands[index] = saved
                    } else {
                        settings.commands.append(saved)
                    }
                }
            }
        }
    }

    private func rules(using id: UUID) -> [String] {
        model.settings.rules.filter { $0.actions.command == id }.map(\.name)
    }

    private func delete(_ id: UUID) {
        model.updateSettings { settings in
            settings.commands.removeAll { $0.id == id }
            for index in settings.rules.indices where settings.rules[index].actions.command == id {
                settings.rules[index].actions.command = nil
            }
        }
    }
}

private struct CommandRow: View {
    let command: AutomationCommand
    let usedBy: [String]
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: command.isApproved ? "terminal" : "exclamationmark.triangle.fill")
                .foregroundStyle(command.isApproved ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            VStack(alignment: .leading, spacing: 2) {
                Text(command.name).fontWeight(.medium)
                Text(command.script.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(command.isApproved ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            }
            Spacer()
            Button(command.isApproved ? "Edit…" : "Review…", action: onEdit)
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .help("Delete command")
        }
        .buttonStyle(.borderless)
        .confirmationDialog("Delete “\(command.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text(usedBy.isEmpty ? "No rule uses it." : "Rules that run it (\(usedBy.joined(separator: ", "))) will stop running a command.")
        }
    }

    private var status: String {
        guard command.isApproved else { return "Not approved: it changed since you approved it, so it won’t run." }
        return usedBy.isEmpty ? "Approved · not used by a rule yet" : "Approved · used by \(usedBy.joined(separator: ", "))"
    }
}

/// Writing a command. Saving approves exactly the text shown, after a confirmation.
private struct CommandEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var command: AutomationCommand
    let isNew: Bool
    let onSave: (AutomationCommand) -> Void
    @State private var confirming = false
    @State private var testOutput: String?
    @State private var testing = false

    private var isValid: Bool {
        !command.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !command.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $command.name, prompt: Text("e.g. Copy to NAS"))
                }
                Section {
                    TextEditor(text: $command.script)
                        .font(.body.monospaced())
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                } header: {
                    Text("zsh script")
                } footer: {
                    Text("The file is $1. Also set: $FLUX_FILE, $FLUX_NAME, $FLUX_URL, $FLUX_SITE, $FLUX_KIND, $FLUX_ID and $FLUX_SHA256 (when known). Runs in the file’s folder, without your shell profile, for at most 5 minutes. Example: cp \"$1\" /Volumes/NAS/Inbox/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let testOutput {
                    Section("Test run") {
                        Text(testOutput).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Button("Test on a File…", action: test)
                    .disabled(!isValid || testing)
                    .help("Approves this text and runs it once on a file you choose")
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Approve and Add" : "Approve and Save") { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background { SkyBackground() }
        .tint(FluxTheme.accent)
        .confirmationDialog("Allow Flux to run “\(command.name)”?", isPresented: $confirming) {
            Button("Approve") {
                var approved = command
                approved.name = approved.name.trimmingCharacters(in: .whitespaces)
                approved.approve()
                onSave(approved)
                dismiss()
            }
        } message: {
            Text("It runs as you, with your files, whenever a rule that uses it matches:\n\n\(command.script)")
        }
    }

    private func test() {
        let panel = NSOpenPanel()
        panel.title = "Test “\(command.name)”"
        panel.message = "Choose a file to run the command on."
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        var approved = command
        approved.approve()
        testing = true
        testOutput = "Running…"
        Task {
            var record = DownloadRecord(url: file, directory: file.deletingLastPathComponent(), fileName: file.lastPathComponent)
            record.status = .completed
            record.finalPath = file
            do {
                let output = try await CommandRunner.run(approved, file: file, record: record)
                testOutput = "Finished" + (output.isEmpty ? "." : ": \(output)")
            } catch {
                testOutput = error.localizedDescription
            }
            testing = false
        }
    }
}
