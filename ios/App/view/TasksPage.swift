import SwiftUI

enum TaskFilter: Hashable {
    case all
    case unfinished
    case finished
    case category(String)

    var title: String {
        switch self {
        case .all: return String(localized: "All Downloads")
        case .unfinished: return String(localized: "Unfinished")
        case .finished: return String(localized: "Finished")
        case .category(let id): return Category.byId(id).localizedName
        }
    }

    var symbol: String {
        switch self {
        case .all: return "list.bullet"
        case .unfinished: return "arrow.down.circle"
        case .finished: return "checkmark.circle"
        case .category(let id): return Category.byId(id).symbol
        }
    }
}

struct TasksPage: View {
    let service: TaskService
    @Binding var incomingDraft: TorrentDraft?

    @State private var filter: TaskFilter = .all
    @State private var searchText = ""
    @State private var isAddPresented = false
    @State private var isSettingsPresented = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var visibleTasks: [TaskRecord] {
        service.tasks.filter { record in
            let matches: Bool
            switch filter {
            case .all: matches = true
            case .unfinished: matches = record.status != .completed
            case .finished: matches = record.status == .completed
            case .category(let id): matches = record.categoryId == id
            }
            guard matches else { return false }
            guard !searchText.isEmpty else { return true }
            return record.name.localizedCaseInsensitiveContains(searchText)
                || record.url.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
                } detail: {
                    detail
                }
            } else {
                NavigationStack {
                    detail
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                filterMenu
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $isAddPresented) {
            AddSheet(service: service)
        }
        .sheet(item: $incomingDraft) { draft in
            AddSheet(service: service, initialDraft: draft)
        }
        .sheet(isPresented: $isSettingsPresented) {
            NavigationStack { SettingsPage(service: service) }
        }
    }

    // MARK: - Sidebar

    /// Optional List selection binding: gives the native sidebar selection style on iOS and Mac.
    private var sidebarSelection: Binding<TaskFilter?> {
        Binding(
            get: { filter },
            set: { newValue in
                if let newValue {
                    filter = newValue
                }
            }
        )
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section {
                ForEach([TaskFilter.all, .unfinished, .finished], id: \.self) { item in
                    Label(item.title, systemImage: item.symbol)
                        .tag(item)
                }
            }
            Section("Categories") {
                ForEach(Category.all) { category in
                    Label(category.localizedName, systemImage: category.symbol)
                        .tag(TaskFilter.category(category.id))
                }
            }
            Section {
                DiskSpaceView()
            }
        }
        .listStyle(.sidebar)
    }

    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: $filter) {
                ForEach([TaskFilter.all, .unfinished, .finished], id: \.self) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
                Section("Categories") {
                    ForEach(Category.all) { category in
                        let item = TaskFilter.category(category.id)
                        Label(category.localizedName, systemImage: category.symbol).tag(item)
                    }
                }
            }
        } label: {
            Label(filter.title, systemImage: filter.symbol)
        }
    }

    // MARK: - Content

    private var detail: some View {
        TaskListView(service: service, tasks: visibleTasks, isFilterEmpty: visibleTasks.isEmpty)
            .searchable(text: $searchText, prompt: Text("Search in the List"))
            .navigationTitle(filter.title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    statusMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAddPresented = true
                    } label: {
                        Label("Add Download", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    overflowMenu
                }
            }
    }

    /// Live download speed and free disk space, replacing the old footer bar.
    private var statusMenu: some View {
        Menu {
            LabeledContent("Download Speed", value: toDockSpeed(service.totalSpeed))
            if let capacity = Paths.volumeCapacity() {
                LabeledContent("Free Space", value: toReadableSize(capacity.free))
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                Text(toDockSpeed(service.totalSpeed))
                    .monospacedDigit()
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(service.totalSpeed > 0 ? Color.accentColor : Color.secondary)
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button("Resume All", systemImage: "play.circle") {
                service.resumeAll()
            }
            Button("Pause All", systemImage: "pause.circle") {
                service.pauseAll()
            }
            Divider()
            Button("Clear Finished", systemImage: "checkmark.circle.badge.xmark") {
                service.clearFinished(deleteFiles: false)
            }
            Button("Settings", systemImage: "gearshape") {
                isSettingsPresented = true
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}

/// Disk space indicator at the bottom of the sidebar.
struct DiskSpaceView: View {
    @State private var capacity: (free: Int64, total: Int64)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let capacity {
                let usedFraction = capacity.total > 0
                    ? Double(capacity.total - capacity.free) / Double(capacity.total)
                    : 0
                Text("Disk Space")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: usedFraction)
                    .tint(Gradient(colors: [Color(red: 0.24, green: 0.78, blue: 0.74), Color(red: 0.56, green: 0.4, blue: 0.96)]))
                Text("\(toReadableSize(capacity.free)) free")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .onAppear { capacity = Paths.volumeCapacity() }
    }
}
