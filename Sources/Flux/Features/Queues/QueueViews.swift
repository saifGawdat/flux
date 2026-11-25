import FluxCore
import SwiftUI

/// Sidebar row for a named queue: its state as the icon, unfinished downloads as the badge.
struct QueueSidebarRow: View {
    @Environment(AppModel.self) private var model
    let queue: DownloadQueue

    var body: some View {
        let pending = model.current.lazy.filter { $0.record.queueID == queue.id && $0.record.status != .completed }.count
        Label(queue.name, systemImage: queue.isRunning ? "play.circle" : (queue.schedule != nil ? "clock" : "pause.circle"))
            .badge(pending)
            .help(QueueStatusText(queue: queue).text)
            .contextMenu {
                if queue.isRunning {
                    Button("Stop Queue") { model.stopQueue(queue.id) }
                } else {
                    Button("Start Queue") { model.startQueue(queue.id) }
                }
                Button("Edit Queue…") { model.queueEditor = QueueEditorRequest(queue: queue) }
                Divider()
                Button("Delete Queue", role: .destructive) { model.deleteQueue(queue.id) }
            }
    }
}

/// "Stopped · Every day 02:00–06:00 · starts tomorrow at 02:00".
struct QueueStatusText {
    let queue: DownloadQueue

    var text: String {
        var parts = [queue.isRunning ? "Started" : "Stopped"]
        if let schedule = queue.schedule {
            parts.append(schedule.summary)
            if let next = schedule.next(after: Date()) {
                if next.change == .start, !queue.isRunning {
                    parts.append("starts \(Format.when(next.date))")
                } else if next.change == .stop, queue.isRunning {
                    parts.append("stops \(Format.when(next.date))")
                }
            }
        } else if !queue.isRunning {
            parts.append("downloads wait until you start it")
        }
        return parts.joined(separator: " · ")
    }
}

/// Above a queue's downloads: what it's doing, and Start/Stop.
struct QueueHeaderBar: View {
    @Environment(AppModel.self) private var model
    let queue: DownloadQueue

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: queue.isRunning ? "play.circle.fill" : "pause.circle.fill")
                .foregroundStyle(queue.isRunning ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(queue.name).font(.callout.weight(.semibold))
                Text(QueueStatusText(queue: queue).text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit…") { model.queueEditor = QueueEditorRequest(queue: queue) }
            if queue.isRunning {
                Button("Stop") { model.stopQueue(queue.id) }
                    .help("Running downloads stop and wait here until the queue starts again")
            } else {
                Button("Start") { model.startQueue(queue.id) }
                    .buttonStyle(.borderedProminent)
                    .help("Start this queue's downloads now")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Context-menu submenu: move downloads to the main queue or a named one.
struct MoveToQueueMenu: View {
    @Environment(AppModel.self) private var model
    let ids: Set<UUID>

    var body: some View {
        if !model.settings.queues.isEmpty {
            let current = Set(model.downloads.filter { ids.contains($0.id) }.map(\.record.queueID))
            Menu("Queue") {
                Toggle("Main", isOn: Binding(get: { current == [nil] }, set: { _ in model.move(ids, toQueue: nil) }))
                Divider()
                ForEach(model.settings.queues) { queue in
                    Toggle(queue.name, isOn: Binding(
                        get: { current == [queue.id] },
                        set: { _ in model.move(ids, toQueue: queue.id) }))
                }
            }
        }
    }
}

/// Queue choice for the add and import sheets; hidden until a named queue exists.
struct QueuePicker: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: UUID?

    var body: some View {
        if !model.settings.queues.isEmpty {
            Picker("Queue", selection: $selection) {
                Text("Main").tag(UUID?.none)
                ForEach(model.settings.queues) { queue in
                    Text(queue.isRunning ? queue.name : "\(queue.name) (stopped)").tag(Optional(queue.id))
                }
            }
        }
    }
}

/// Creates or edits a named queue.
struct QueueEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let existing: DownloadQueue?
    @State private var draft: DownloadQueue
    @State private var useSchedule: Bool
    @State private var useStop: Bool
    @State private var confirmDelete = false

    init(queue: DownloadQueue?) {
        existing = queue
        let draft = queue ?? DownloadQueue(name: "")
        _draft = State(initialValue: draft)
        _useSchedule = State(initialValue: draft.schedule != nil)
        _useStop = State(initialValue: draft.schedule?.stop != nil)
    }

    private var schedule: QueueSchedule { draft.schedule ?? QueueSchedule(start: 2 * 60, stop: 7 * 60) }

    private var result: DownloadQueue {
        var queue = draft
        queue.name = queue.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if useSchedule {
            var schedule = schedule
            if useStop { schedule.stop = schedule.stop ?? (schedule.start + 5 * 60) % (24 * 60) } else { schedule.stop = nil }
            queue.schedule = schedule
        } else {
            queue.schedule = nil
        }
        return queue
    }

    private var nameTaken: Bool {
        model.settings.queues.contains { $0.id != draft.id && $0.name.localizedCaseInsensitiveCompare(result.name) == .orderedSame }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("Night"))
                    Picker("Downloads at a time", selection: $draft.maxConcurrent) {
                        Text("Up to the overall limit (\(model.settings.maxConcurrentDownloads))").tag(Int?.none)
                        ForEach(DownloadQueue.concurrencyChoices, id: \.self) { Text("\($0)").tag(Optional($0)) }
                    }
                } footer: {
                    if nameTaken { Text("Another queue has this name.").foregroundStyle(.red) }
                }
                Section {
                    Toggle("Start on a schedule", isOn: $useSchedule.animation())
                    if useSchedule {
                        DayToggles(days: Binding(get: { schedule.days }, set: { var s = schedule; s.days = $0; draft.schedule = s }))
                        TimeOfDayPicker(title: "Start at", minute: Binding(
                            get: { schedule.start }, set: { var s = schedule; s.start = $0; draft.schedule = s }))
                        Toggle("Stop at a set time", isOn: $useStop.animation())
                        if useStop {
                            TimeOfDayPicker(title: "Stop at", minute: Binding(
                                get: { schedule.stop ?? (schedule.start + 5 * 60) % (24 * 60) },
                                set: { var s = schedule; s.stop = $0; draft.schedule = s }))
                        }
                    }
                } footer: {
                    Text(scheduleHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            HStack {
                if let existing {
                    Button("Delete Queue…", role: .destructive) { confirmDelete = true }
                        .confirmationDialog("Delete “\(existing.name)”?", isPresented: $confirmDelete) {
                            Button("Delete Queue", role: .destructive) {
                                model.deleteQueue(existing.id)
                                dismiss()
                            }
                        } message: {
                            Text("Its downloads move to the main queue. Nothing is deleted from disk.")
                        }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Create Queue" : "Save") {
                    model.saveQueue(result)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(result.name.isEmpty || nameTaken || (useSchedule && schedule.days.isEmpty))
            }
            .padding(16)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .fluxBackground()
    }

    private var scheduleHelp: String {
        guard useSchedule else {
            return "Downloads added to this queue wait until you press Start. Stopping it pauses its downloads; they continue when it starts again."
        }
        let stop = useStop
            ? "At the stop time, running downloads pause and wait for the next start."
            : "Without a stop time it runs until everything in it has finished."
        return "\(stop) Flux has to be open (closing the window is fine; quitting isn’t)."
    }
}

/// Seven small toggles, in the order of the user's week.
private struct DayToggles: View {
    @Binding var days: Set<Int>

    var body: some View {
        let calendar = Calendar.current
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        LabeledContent("Days") {
            HStack(spacing: 4) {
                ForEach(order, id: \.self) { day in
                    let on = days.contains(day)
                    Button {
                        if on { days.remove(day) } else { days.insert(day) }
                    } label: {
                        Text(calendar.veryShortStandaloneWeekdaySymbols[day - 1])
                            .font(.caption.weight(.semibold))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(on ? FluxTheme.accent : Color.secondary.opacity(0.15)))
                            .foregroundStyle(on ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(calendar.weekdaySymbols[day - 1])
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }
}

private struct TimeOfDayPicker: View {
    let title: String
    @Binding var minute: Int

    var body: some View {
        DatePicker(title, selection: Binding(
            get: { Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date() },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
    }
}
