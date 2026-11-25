import Charts
import FluxCore
import SwiftUI

/// Sidebar › Statistics: what Flux downloaded, when, and from where.
struct StatisticsView: View {
    @Environment(AppModel.self) private var model
    @State private var period: Statistics.Period = .week
    @State private var stats: Statistics?

    static let refreshInterval: Duration = .seconds(10)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Period", selection: $period) {
                    ForEach(Statistics.Period.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)

                if let stats {
                    tiles(stats)
                    chartCard(stats)
                    HStack(alignment: .top, spacing: 16) {
                        sitesCard(stats)
                        kindsCard(stats)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(20)
        }
        .fluxBackground()
        .task(id: period) {
            while !Task.isCancelled {
                stats = await model.statistics(period)
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    private func tiles(_ stats: Statistics) -> some View {
        HStack(spacing: 12) {
            StatTile(title: "Downloaded", value: Format.bytes(stats.totalBytes), systemImage: "arrow.down.circle")
            StatTile(title: "Finished", value: stats.finished.formatted(), systemImage: "checkmark.circle")
            StatTile(title: "Failed", value: stats.failed.formatted(), systemImage: "exclamationmark.triangle",
                     note: stats.successRate.map { "\(Int(($0 * 100).rounded()))% succeeded" })
            StatTile(title: "Fastest minute", value: stats.peakSpeed > 0 ? Format.speed(stats.peakSpeed) : "–",
                     systemImage: "gauge.with.dots.needle.67percent")
        }
    }

    private func chartCard(_ stats: Statistics) -> some View {
        Card(title: period == .day ? "Downloaded per hour" : "Downloaded per day") {
            if stats.totalBytes == 0 {
                Text("Nothing downloaded in this period.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                Chart(stats.bars) { bar in
                    BarMark(x: .value("Time", bar.start, unit: period.bucket),
                            y: .value("Downloaded", bar.bytes))
                        .foregroundStyle(FluxTheme.accent.gradient)
                        .cornerRadius(3)
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let bytes = value.as(Int64.self) { Text(Format.bytes(bytes)) } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: period.bucket, count: period == .month ? 5 : (period == .day ? 4 : 1))) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: period == .day ? .dateTime.hour() : .dateTime.day().month(.abbreviated))
                    }
                }
                .frame(height: 220)
            }
        }
    }

    private func sitesCard(_ stats: Statistics) -> some View {
        Card(title: "Top sites") {
            if stats.sites.isEmpty {
                Text("No sites yet.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Site")
                        Text("Received").gridColumnAlignment(.trailing)
                        Text("Files").gridColumnAlignment(.trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    ForEach(stats.sites.prefix(8)) { site in
                        GridRow {
                            Text(site.host).lineLimit(1).truncationMode(.middle)
                            Text(Format.bytes(site.bytes)).monospacedDigit()
                            HStack(spacing: 4) {
                                Text("\(site.finished)").monospacedDigit()
                                if site.failed > 0 {
                                    Text("· \(site.failed) failed").foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func kindsCard(_ stats: Statistics) -> some View {
        Card(title: "Finished by kind") {
            if stats.kinds.isEmpty {
                Text("No finished downloads yet.").foregroundStyle(.secondary)
            } else {
                Chart(stats.kinds) { kind in
                    BarMark(x: .value("Size", kind.bytes), y: .value("Kind", kind.category.title))
                        .foregroundStyle(FluxTheme.accent.opacity(0.8))
                        .annotation(position: .trailing) {
                            Text("\(kind.files) · \(Format.bytes(kind.bytes))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(stats.kinds.count) * 28 + 10)
            }
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(note ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
