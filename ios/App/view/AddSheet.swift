import SwiftUI
import UniformTypeIdentifiers
import SwiftTorrent

struct AddSheet: View {
    @Environment(\.dismiss) private var dismiss
    let service: TaskService
    /// Set when a magnet/.torrent was handed over from outside the app.
    var initialDraft: TorrentDraft?

    private enum Stage: Equatable {
        case input
        case resolving
        case ready(TorrentDraft)

        /// Draft identity is enough for change detection.
        static func == (lhs: Stage, rhs: Stage) -> Bool {
            switch (lhs, rhs) {
            case (.input, .input), (.resolving, .resolving): return true
            case (.ready(let a), .ready(let b)): return a.taskId == b.taskId
            default: return false
            }
        }
    }

    @State private var stage: Stage = .input
    @State private var urlText = ""
    @State private var errorMessage = ""
    @State private var isFilePickerPresented = false
    @State private var selectedFiles: Set<Int> = []
    @State private var isSequential = false
    @State private var resolvingDraft: TorrentDraft?
    @State private var resolveStartedAt = Date()
    @State private var sheetDetent: PresentationDetent = .medium
    @FocusState private var isURLFocused: Bool

    private var staticTorrentType: UTType {
        UTType(filenameExtension: "torrent", conformingTo: .data) ?? .data
    }

    var body: some View {
        NavigationStack {
            Form {
                switch stage {
                case .input:
                    inputSection
                case .resolving:
                    resolvingSection
                case .ready(let draft):
                    readySections(draft)
                }
            }
            .navigationTitle("Add Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if case .input = stage {
                        addButton
                    }
                }
            }
            .fileImporter(isPresented: $isFilePickerPresented,
                          allowedContentTypes: [staticTorrentType, .data],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    pickTorrentFile(url)
                }
            }
            .onAppear {
                if let initialDraft {
                    // Handed over from Safari/Files: jump straight to the metadata.
                    if let info = initialDraft.info {
                        selectedFiles = Set(info.files.indices)
                    }
                    stage = .ready(initialDraft)
                    // The detent selection only sticks once presentation settled.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        sheetDetent = .large
                    }
                } else {
                    isURLFocused = true
                }
            }
            .onChange(of: stage) { _, new in
                if case .ready = new { sheetDetent = .large }
            }
        }
        .presentationDetents([.medium, .large], selection: $sheetDetent)
    }

    // MARK: - Stages

    private var inputSection: some View {
        Section {
            TextField("URL", text: $urlText, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($isURLFocused)
                .onSubmit(addFromText)
            Button {
                isFilePickerPresented = true
            } label: {
                Label("Open a .torrent File", systemImage: "doc.badge.plus")
            }
        } footer: {
            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundStyle(.red)
            } else {
                Text("Supports HTTP(S) links, magnets and .torrent files. Torrents show their file list before downloading.")
            }
        }
    }

    private var resolvingSection: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fetching torrent details")
                        .font(.callout.weight(.medium))
                    Text(elapsedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 4)
            Button("Add Without Details") {
                if let draft = resolvingDraft {
                    addDraft(draft)
                }
            }
        } footer: {
            Text("The file list arrives with the metadata from the swarm. You can also add the magnet without waiting.")
        }
    }

    @ViewBuilder
    private func readySections(_ draft: TorrentDraft) -> some View {
        Section {
            LabeledContent("Name", value: draft.displayName)
            if draft.totalSize > 0 {
                LabeledContent("Size", value: toReadableSize(draft.totalSize))
            }
        }
        if let info = draft.info, info.files.count > 1 {
            Section {
                ForEach(Array(info.files.enumerated()), id: \.offset) { index, file in
                    Toggle(isOn: fileBinding(index)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fileName(of: file.path, in: info.name))
                                .font(.callout)
                                .lineLimit(2)
                            Text(toReadableSize(file.length))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Files")
            } footer: {
                Text("\(selectedFiles.count) of \(info.files.count) files · \(toReadableSize(selectedSize(info))) selected")
            }
        } else if draft.info == nil {
            Section {
                Label("Metadata is not available yet — every file will be downloaded.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        Section {
            Toggle("Sequential Download", isOn: $isSequential)
        } header: {
            Text("Options")
        } footer: {
            Text("Sequential fetches pieces in order, so the first files complete first. Turn it off to download everything in parallel.")
        }
        Section {
            Button(draft.info != nil ? "Start Download" : "Start Download Anyway") {
                addDraft(draft)
            }
        }
    }

    // MARK: - Actions

    private var addButton: some View {
        Button("Add", action: confirmAdd)
            .disabled(!canAdd)
    }

    private var canAdd: Bool {
        switch stage {
        case .input: return !urlText.trimmingCharacters(in: .whitespaces).isEmpty
        case .resolving: return false
        case .ready(let draft):
            if let info = draft.info, info.files.count > 1 {
                return !selectedFiles.isEmpty
            }
            return true
        }
    }

    private func addFromText() {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isTorrent = text.hasPrefix("magnet:") || text.hasSuffix(".torrent")
        if isTorrent {
            resolveTorrent(text: urlText, fileURL: nil)
        } else {
            Task {
                if let error = await service.add(urlText) {
                    errorMessage = error
                } else {
                    dismiss()
                }
            }
        }
    }

    private func pickTorrentFile(_ url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        resolveTorrent(text: nil, fileURL: url)
    }

    private func resolveTorrent(text: String?, fileURL: URL?) {
        errorMessage = ""
        stage = .resolving
        resolveStartedAt = Date()
        Task {
            let (draft, error) = await service.prepareTorrent(text: text, fileURL: fileURL)
            if let error {
                errorMessage = error
                stage = .input
                return
            }
            guard var draft else { return }
            resolvingDraft = draft
            if draft.info == nil, draft.url.hasPrefix("magnet:") {
                _ = await service.fetchMetadata(for: &draft)
                resolvingDraft = draft
            }
            if let info = draft.info {
                selectedFiles = Set(info.files.indices)
            }
            if draft.info != nil || draft.url.hasPrefix("magnet:") {
                stage = .ready(draft)
            } else {
                errorMessage = String(localized: "Could not fetch the torrent details. Check the link and try again.")
                stage = .input
            }
        }
    }

    private func confirmAdd() {
        switch stage {
        case .input:
            addFromText()
        case .resolving, .ready:
            break
        }
    }

    /// Confirmation in the ready stage lives on the row: the toolbar Add only
    /// fires for the input stage, so the ready stage exposes its own action.
    private func addDraft(_ draft: TorrentDraft) {
        let error = service.addTorrent(draft, selection: selectedFiles, sequential: isSequential)
        if let error {
            errorMessage = error
            stage = .input
        } else {
            dismiss()
        }
    }

    private func cancel() {
        if case .ready(let draft) = stage {
            service.discardTorrentDraft(draft)
        } else if let draft = resolvingDraft {
            service.discardTorrentDraft(draft)
        }
        dismiss()
    }

    // MARK: - Helpers

    private func fileBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { selectedFiles.contains(index) },
            set: { on in
                if on { selectedFiles.insert(index) } else { selectedFiles.remove(index) }
            }
        )
    }

    private func fileName(of path: String, in torrentName: String) -> String {
        let prefix = torrentName + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private func selectedSize(_ info: TorrentInfo) -> Int64 {
        info.files.enumerated().reduce(Int64(0)) { total, entry in
            selectedFiles.contains(entry.offset) ? total + entry.element.length : total
        }
    }

    private var elapsedText: String {
        let elapsed = Int(Date().timeIntervalSince(resolveStartedAt))
        return String(localized: "\(elapsed)s elapsed")
    }
}

