import FluxCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Downloads") {
                LabeledContent("Save downloads to") {
                    FolderPickerButton(url: model.settings.downloadDirectory) { url in
                        model.updateSettings { $0.downloadDirectory = url }
                    }
                }
                Toggle("Resume unfinished downloads at launch", isOn: Binding(
                    get: { model.settings.resumeOnLaunch },
                    set: { value in model.updateSettings { $0.resumeOnLaunch = value } }
                ))
            }
            Section("Connections") {
                Stepper(
                    "Simultaneous downloads: \(model.settings.maxConcurrentDownloads)",
                    value: Binding(
                        get: { model.settings.maxConcurrentDownloads },
                        set: { value in model.updateSettings { $0.maxConcurrentDownloads = value } }
                    ),
                    in: FluxSettings.concurrentRange)
                Picker("Connections per download", selection: Binding(
                    get: { model.settings.connectionsPerDownload },
                    set: { value in model.updateSettings { $0.connectionsPerDownload = value } }
                )) {
                    ForEach(FluxSettings.connectionChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                Text("More connections help on fast links to servers that allow them. Flux lowers the count automatically when a server refuses extra connections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(model.manager == nil)
    }
}
