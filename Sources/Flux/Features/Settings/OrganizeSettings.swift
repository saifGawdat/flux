import FluxCore
import SwiftUI

/// Settings › Organize: category folders, rules, duplicates and archives.
struct OrganizeSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: RuleDraft?

    private var settings: FluxSettings { model.settings }

    var body: some View {
        Form {
            Section {
                Toggle("Sort finished downloads into folders by kind", isOn: binding(\.sortIntoCategoryFolders))
            } header: {
                Text("Folders")
            } footer: {
                Text(categoryFooter).foregroundStyle(.secondary)
            }

            Section {
                if settings.rules.isEmpty {
                    Text("No rules yet. A rule can, for example, put every PDF from your bank's site into a Statements folder.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(settings.rules.enumerated()), id: \.element.id) { index, rule in
                        RuleRow(rule: rule, isFirst: index == 0, isLast: index == settings.rules.count - 1,
                                onToggle: { on in updateRule(rule.id) { $0.isEnabled = on } },
                                onEdit: { editing = RuleDraft(rule) },
                                onMove: { moveRule(rule.id, by: $0) },
                                onDelete: { model.updateSettings { $0.rules.removeAll { $0.id == rule.id } } })
                    }
                }
                HStack {
                    Spacer()
                    Button("Add Rule…") { editing = RuleDraft(nil, defaultFolder: settings.downloadDirectory) }
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("Checked from top to bottom when a download finishes; the first rule that matches decides the folder. Rules come before folders by kind. Downloads saved to a folder you picked yourself are left alone.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("When a download is identical to a file you have", selection: binding(\.duplicateAction)) {
                    Text("Keep both, and mark it").tag(FluxSettings.DuplicateAction.keepBoth)
                    Text("Move the new copy to the Trash").tag(FluxSettings.DuplicateAction.trashNew)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Duplicates")
            } footer: {
                Text("Flux compares files of the same size by their SHA-256: in the same folder and among earlier downloads.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Extract archives when they finish", isOn: binding(\.extractArchives))
                Toggle("Then move the archive to the Trash", isOn: binding(\.trashArchivesAfterExtracting))
                    .disabled(!settings.extractArchives)
            } header: {
                Text("Archives")
            } footer: {
                Text("zip, tar (.gz, .bz2, .xz), 7z and rar. Files are extracted next to the archive and never overwrite anything; entries that try to write outside that folder are refused. Password-protected archives are left as they are.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fluxBackground()
        .frame(minHeight: 560)
        .sheet(item: $editing) { draft in
            RuleEditor(draft: draft) { saved in
                model.updateSettings { settings in
                    if let index = settings.rules.firstIndex(where: { $0.id == saved.id }) {
                        settings.rules[index] = saved
                    } else {
                        settings.rules.append(saved)
                    }
                }
            }
        }
    }

    private var categoryFooter: String {
        let names = FileCategory.allCases.filter { $0 != .other }.map(\.folderName).joined(separator: ", ")
        return "\(names), inside your download folder (\(settings.downloadDirectory.lastPathComponent)). Other files stay where they are."
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<FluxSettings, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { value in model.updateSettings { $0[keyPath: keyPath] = value } })
    }

    private func updateRule(_ id: UUID, _ change: @escaping (inout DownloadRule) -> Void) {
        model.updateSettings { settings in
            if let index = settings.rules.firstIndex(where: { $0.id == id }) { change(&settings.rules[index]) }
        }
    }

    private func moveRule(_ id: UUID, by offset: Int) {
        model.updateSettings { settings in
            guard let index = settings.rules.firstIndex(where: { $0.id == id }) else { return }
            let target = index + offset
            guard settings.rules.indices.contains(target) else { return }
            settings.rules.swapAt(index, target)
        }
    }
}

private struct RuleRow: View {
    let rule: DownloadRule
    let isFirst: Bool
    let isLast: Bool
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onMove: (Int) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Enabled", isOn: Binding(get: { rule.isEnabled }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name.isEmpty ? "Untitled rule" : rule.name).fontWeight(.medium)
                Text(RuleText.summary(rule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help((rule.folder.path as NSString).abbreviatingWithTildeInPath)
            }
            .opacity(rule.isEnabled ? 1 : 0.5)
            Spacer()
            Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(isFirst).help("Check earlier")
            Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                .disabled(isLast).help("Check later")
            Button("Edit…", action: onEdit)
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .help("Delete rule")
        }
        .buttonStyle(.borderless)
    }
}

/// Plain-language descriptions of rules and conditions.
enum RuleText {
    static func summary(_ rule: DownloadRule) -> String {
        let when = rule.conditions.isEmpty ? "No conditions yet" : rule.conditions.map(describe).joined(separator: " and ")
        return "\(when) → \(rule.folder.lastPathComponent)"
    }

    static func describe(_ condition: DownloadRule.Condition) -> String {
        switch condition {
        case .fileExtension(let list): "extension is \(list.isEmpty ? "…" : list.joined(separator: ", "))"
        case .namePattern(let pattern): "name matches “\(pattern)”"
        case .domain(let domain): "from \(domain.isEmpty ? "…" : domain)"
        case .linkContains(let text): "link contains “\(text)”"
        case .largerThan(let bytes): "larger than \(Format.bytes(bytes))"
        case .smallerThan(let bytes): "smaller than \(Format.bytes(bytes))"
        case .category(let category): "kind is \(category.title)"
        }
    }
}

/// A rule being edited; `isNew` until it's saved for the first time.
struct RuleDraft: Identifiable {
    var rule: DownloadRule
    let isNew: Bool
    var id: UUID { rule.id }

    init(_ rule: DownloadRule?, defaultFolder: URL = FluxSettings.defaultDownloadDirectory) {
        self.rule = rule ?? DownloadRule(name: "", conditions: [.fileExtension([])], folder: defaultFolder)
        isNew = rule == nil
    }
}

private struct RuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: RuleDraft
    let onSave: (DownloadRule) -> Void

    private var isValid: Bool {
        !draft.rule.conditions.isEmpty && draft.rule.conditions.allSatisfy(Self.isFilledIn)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.rule.name, prompt: Text("e.g. Bank statements"))
                }
                Section {
                    ForEach(draft.rule.conditions.indices, id: \.self) { index in
                        ConditionEditor(condition: $draft.rule.conditions[index]) {
                            draft.rule.conditions.remove(at: index)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Add Condition") { draft.rule.conditions.append(.namePattern("")) }
                    }
                } header: {
                    Text("When a finished download matches all of these")
                }
                Section("Save it to") {
                    FolderPickerButton(url: draft.rule.folder) { draft.rule.folder = $0 }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Add Rule" : "Save") {
                    var rule = draft.rule
                    if rule.name.trimmingCharacters(in: .whitespaces).isEmpty {
                        rule.name = rule.conditions.first.map(RuleText.describe)?.capitalizedFirst ?? "Rule"
                    }
                    onSave(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background { SkyBackground() }
        .tint(FluxTheme.accent)
    }

    static func isFilledIn(_ condition: DownloadRule.Condition) -> Bool {
        switch condition {
        case .fileExtension(let list): !list.isEmpty
        case .namePattern(let text), .domain(let text), .linkContains(let text):
            !text.trimmingCharacters(in: .whitespaces).isEmpty
        case .largerThan(let n), .smallerThan(let n): n > 0
        case .category: true
        }
    }
}

/// One condition: what to look at, and the value to compare with.
private struct ConditionEditor: View {
    @Binding var condition: DownloadRule.Condition
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Condition", selection: Binding(
                get: { condition.kind },
                set: { if $0 != condition.kind { condition = .starting($0) } }
            )) {
                ForEach(DownloadRule.Condition.Kind.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            value
            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove condition")
        }
    }

    @ViewBuilder
    private var value: some View {
        switch condition {
        case .fileExtension(let list):
            TextField("Extensions", text: Binding(
                get: { list.joined(separator: ", ") },
                set: { text in
                    condition = .fileExtension(text.split(whereSeparator: { ", ".contains($0) }).map(String.init))
                }), prompt: Text("pdf, docx"))
                .labelsHidden()
        case .namePattern(let pattern):
            TextField("Pattern", text: Binding(get: { pattern }, set: { condition = .namePattern($0) }),
                      prompt: Text("*invoice*  (* = anything)"))
                .labelsHidden()
        case .domain(let domain):
            TextField("Site", text: Binding(get: { domain }, set: { condition = .domain($0) }), prompt: Text("github.com"))
                .labelsHidden()
        case .linkContains(let text):
            TextField("Text", text: Binding(get: { text }, set: { condition = .linkContains($0) }), prompt: Text("/releases/"))
                .labelsHidden()
        case .largerThan(let bytes):
            SizeField(bytes: Binding(get: { bytes }, set: { condition = .largerThan($0) }))
        case .smallerThan(let bytes):
            SizeField(bytes: Binding(get: { bytes }, set: { condition = .smallerThan($0) }))
        case .category(let category):
            Picker("Kind", selection: Binding(get: { category }, set: { condition = .category($0) })) {
                ForEach(FileCategory.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            .labelsHidden()
        }
    }
}

/// A size in MB or GB (decimal, like the sizes Flux shows).
private struct SizeField: View {
    @Binding var bytes: Int64
    @State private var number: Double = 0
    @State private var unit: Int64 = 1_000_000

    var body: some View {
        HStack(spacing: 6) {
            TextField("Size", value: $number, format: .number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Picker("Unit", selection: $unit) {
                Text("KB").tag(Int64(1_000))
                Text("MB").tag(Int64(1_000_000))
                Text("GB").tag(Int64(1_000_000_000))
            }
            .labelsHidden()
            .fixedSize()
        }
        .onAppear {
            unit = bytes >= 1_000_000_000 ? 1_000_000_000 : (bytes >= 1_000_000 ? 1_000_000 : 1_000)
            number = Double(bytes) / Double(unit)
        }
        .onChange(of: number) { bytes = Int64(number * Double(unit)) }
        .onChange(of: unit) { bytes = Int64(number * Double(unit)) }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
