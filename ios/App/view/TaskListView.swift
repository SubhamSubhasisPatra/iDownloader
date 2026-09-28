import SwiftUI

/// Task list: a multi-column table (Name / Size / Status / Time Left / Date) on wide screens, compact rows on narrow ones.
struct TaskListView: View {
    let service: TaskService
    let tasks: [TaskRecord]
    let isFilterEmpty: Bool

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var previewTask: TaskRecord?
    @State private var propertiesTask: TaskRecord?
    @State private var renamingTask: TaskRecord?
    @State private var renameText = ""

    private var isRegular: Bool { sizeClass == .regular }

    var body: some View {
        VStack(spacing: 0) {
            if tasks.isEmpty {
                emptyState
            } else {
                taskTable
            }
            footerBar
        }
        .background(Color(.systemBackground))
        .sheet(item: $previewTask) { record in
            QuickLookView(url: record.outputURL)
                .ignoresSafeArea()
        }
        .sheet(item: $propertiesTask) { record in
            NavigationStack {
                TaskPropertiesView(record: record)
            }
            .presentationDetents([.medium, .large])
        }
        .alert("Rename", isPresented: Binding(
            get: { renamingTask != nil },
            set: { if !$0 { renamingTask = nil } }
        )) {
            TextField("Name", text: $renameText)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("OK") {
                if let task = renamingTask {
                    service.rename(task.taskId, to: renameText)
                }
            }
        } message: {
            Text("Enter a new name for this file.")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView("No tasks yet", systemImage: "arrow.down.circle")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var taskTable: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if isRegular {
                    headerRow
                }
                ForEach(tasks) { record in
                    TaskRow(record: record, isRegular: isRegular)
                        .contextMenu { rowMenu(record) }
                        .onTapGesture { open(record) }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Size")
                .frame(width: 138, alignment: .trailing)
            Text("Status")
                .frame(width: 150, alignment: .leading)
            Text("Time Left")
                .frame(width: 80, alignment: .trailing)
            Text("Date")
                .frame(width: 96, alignment: .leading)
            Color.clear.frame(width: 24)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    private var footerBar: some View {
        HStack(spacing: 16) {
            Label(toDockSpeed(service.totalSpeed), systemImage: "arrow.down")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(service.totalSpeed > 0 ? Color.accentColor : Color.secondary)
            Spacer()
            if let capacity = Paths.volumeCapacity() {
                Label("\(toReadableSize(capacity.free)) free", systemImage: "internaldrive")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Row actions

    @ViewBuilder
    private func rowMenu(_ record: TaskRecord) -> some View {
        switch record.status {
        case .running:
            if record.canPause {
                Button("Pause", systemImage: "pause.fill") {
                    service.pause(record.taskId)
                }
            }
        case .waiting, .paused:
            Button("Start", systemImage: "play.fill") {
                service.start(record.taskId)
            }
        case .failed:
            Button("Retry", systemImage: "arrow.clockwise") {
                service.start(record.taskId)
            }
        case .completed:
            EmptyView()
        }

        if record.status == .completed {
            ShareLink(item: record.outputURL) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }

        Button("Redownload", systemImage: "arrow.clockwise") {
            service.redownload(record.taskId)
        }
        .disabled(record.status == .running)

        Button("Rename…", systemImage: "pencil") {
            renameText = record.name
            renamingTask = record
        }
        .disabled(record.status == .running)

        Button("Copy URL", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = record.url
        }

        Divider()
        Button("Properties", systemImage: "info.circle") {
            propertiesTask = record
        }
        Divider()
        Button("Remove Task", systemImage: "trash", role: .destructive) {
            service.remove(record.taskId, deleteFile: false)
        }
    }

    private func open(_ record: TaskRecord) {
        if record.status == .completed, FileManager.default.fileExists(atPath: record.outputURL.path) {
            previewTask = record
        } else {
            propertiesTask = record
        }
    }
}

/// Status cell: percentage with a gradient progress bar (matches the reference design).
struct StatusCell: View {
    let record: TaskRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusText)
                .font(.callout)
                .foregroundStyle(record.status == .failed ? Color.red : Color.primary)
            if showsBar {
                GradientProgressbar(value: record.progress)
                    .frame(height: 6)
            }
        }
    }

    private var showsBar: Bool {
        record.status == .running || record.status == .paused
    }

    private var statusText: String {
        switch record.status {
        case .waiting: return String(localized: "Queued")
        case .running:
            return record.fileSize > 0 ? "\(Int(record.progress * 100))%" : String(localized: "Running")
        case .paused: return String(localized: "Paused")
        case .completed: return String(localized: "Completed")
        case .failed: return String(localized: "Failed")
        }
    }
}

/// Gradient progress bar: teal to purple (reference palette).
struct GradientProgressbar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 0.24, green: 0.78, blue: 0.74),
                                                  Color(red: 0.56, green: 0.4, blue: 0.96)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, geo.size.width * min(1, max(0, value))))
            }
        }
    }
}
