import FluxCore
import SwiftUI

/// "Speed Limit" submenu for context menus: Unlimited or a preset, with a checkmark on
/// the current value when all chosen downloads share it.
struct SpeedLimitMenu: View {
    @Environment(AppModel.self) private var model
    let ids: Set<UUID>
    let current: Int64??

    var body: some View {
        Menu("Speed Limit") {
            option(nil)
            Divider()
            ForEach(FluxSettings.speedLimitPresets, id: \.self) { option($0) }
            Divider()
            if let id = ids.first, ids.count == 1 {
                Button("Custom…") { model.showInfo(id) }
            }
        }
    }

    private func option(_ value: Int64?) -> some View {
        Toggle(Format.limit(value), isOn: Binding(
            get: { current == .some(value) },
            set: { _ in model.setSpeedLimit(value, for: ids) }))
    }
}

/// A speed amount as a number plus a unit (KB/s or MB/s), in decimal units like the
/// speeds Flux shows.
struct SpeedAmountField: View {
    @Binding var bytesPerSecond: Int64
    @State private var number: Double = 1
    @State private var unit: Int64 = 1_000_000

    private static let units: [(String, Int64)] = [("KB/s", 1_000), ("MB/s", 1_000_000)]

    var body: some View {
        HStack(spacing: 6) {
            TextField("Amount", value: $number, format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .labelsHidden()
                .onSubmit(commit)
            Picker("Unit", selection: $unit) {
                ForEach(Self.units, id: \.1) { Text($0.0).tag($0.1) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .onAppear(perform: load)
        .onChange(of: bytesPerSecond) { load() }
        .onChange(of: number) { commit() }
        .onChange(of: unit) { commit() }
    }

    private func load() {
        let value = Double(bytesPerSecond)
        let newUnit: Int64 = bytesPerSecond >= 1_000_000 ? 1_000_000 : 1_000
        let newNumber = (value / Double(newUnit) * 100).rounded() / 100
        guard Int64(newNumber * Double(newUnit)) != Int64(number * Double(unit)) else { return }
        unit = newUnit
        number = newNumber
    }

    private func commit() {
        let value = max(FluxSettings.minimumSpeedLimit, Int64(number * Double(unit)))
        if value != bytesPerSecond { bytesPerSecond = value }
    }
}

/// Form control for one download's limit: Unlimited, a preset, or a custom amount.
struct SpeedLimitPicker: View {
    let title: String
    @Binding var limit: Int64?
    @State private var custom = false

    private var isPreset: Bool { limit.map(FluxSettings.speedLimitPresets.contains) ?? true }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Picker(title, selection: Binding<Int64>(
                    get: { custom || !isPreset ? -1 : (limit ?? 0) },
                    set: { value in
                        custom = value == -1
                        if value == -1 {
                            limit = limit ?? 1_000_000
                        } else {
                            limit = value == 0 ? nil : value
                        }
                    }
                )) {
                    Text("Unlimited").tag(Int64(0))
                    Divider()
                    ForEach(FluxSettings.speedLimitPresets, id: \.self) { Text(Format.limit($0)).tag($0) }
                    Divider()
                    Text("Custom").tag(Int64(-1))
                }
                .labelsHidden()
                .fixedSize()
                if custom || !isPreset {
                    SpeedAmountField(bytesPerSecond: Binding(get: { limit ?? 1_000_000 }, set: { limit = $0 }))
                }
            }
        }
    }
}
