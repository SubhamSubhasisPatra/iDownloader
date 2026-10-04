import SwiftUI
import QuickLook
import SwiftTorrent

/// Detailed task information (Properties).
struct TaskPropertiesView: View {
    let record: TaskRecord
    let service: TaskService
    @State private var torrentFiles: (files: [TorrentInfo.FileEntry], progress: [Double])?

    var body: some View {
        Form {
            Section("File") {
                LabeledContent("Name", value: record.name)
                LabeledContent("Category", value: record.category.localizedName)
                LabeledContent("Size", value: sizeText)
                LabeledContent("Folder", value: record.outputURL.deletingLastPathComponent().path)
            }
            Section("Download") {
                LabeledContent("Type", value: record.kind == "torrent" ? "BitTorrent" : "HTTP")
                LabeledContent("URL", value: record.url)
                LabeledContent("Status", value: statusText)
                if record.kind == "torrent" && record.sequential {
                    LabeledContent("Order", value: String(localized: "Sequential"))
                }
                if !record.errorMessage.isEmpty {
                    Text(record.errorMessage)
                        .foregroundStyle(.red)
                }
                if record.kind == "http" {
                    LabeledContent("Connections", value: "\(max(1, record.segmentCount))")
                } else if record.status == .running {
                    LabeledContent("Peers", value: "\(record.peers)")
                }
                if record.speed > 0 {
                    LabeledContent("Speed", value: toDockSpeed(record.speed))
                }
                if let seconds = record.timeLeft {
                    LabeledContent("Time Left", value: toReadableTime(seconds))
                }
            }
            if let torrentFiles {
                Section("Contents") {
                    ForEach(Array(torrentFiles.files.enumerated()), id: \.offset) { index, file in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(fileName(of: file.path))
                                .font(.callout)
                                .lineLimit(2)
                            HStack {
                                Text(toReadableSize(file.length))
                                if torrentFiles.progress.indices.contains(index) {
                                    Text("\(Int(torrentFiles.progress[index] * 100))%")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if torrentFiles.progress.indices.contains(index),
                               torrentFiles.progress[index] > 0, torrentFiles.progress[index] < 1 {
                                ProgressView(value: torrentFiles.progress[index])
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
            Section("Dates") {
                LabeledContent("Added", value: dateText(record.createdAt))
                if record.completedAt > 0 {
                    LabeledContent("Completed", value: dateText(record.completedAt))
                }
            }
        }
        .navigationTitle("Properties")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            torrentFiles = await service.torrentFileStatus(record)
        }
    }

    private func fileName(of path: String) -> String {
        var parts = path.split(separator: "/").map(String.init)
        if parts.count > 1 { parts.removeFirst() }  // drop the torrent name folder
        return parts.joined(separator: "/")
    }

    private var sizeText: String {
        if record.fileSize > 0 {
            return "\(toReadableSize(record.receivedBytes)) / \(toReadableSize(record.fileSize))"
        }
        return toReadableSize(record.receivedBytes)
    }

    private var statusText: String {
        switch record.status {
        case .waiting: return String(localized: "Queued")
        case .running: return String(localized: "Running")
        case .paused: return String(localized: "Paused")
        case .completed: return String(localized: "Completed")
        case .failed: return String(localized: "Failed")
        }
    }

    private func dateText(_ timestamp: Int) -> String {
        guard timestamp > 0 else { return "—" }
        return Date(timeIntervalSince1970: TimeInterval(timestamp)).formatted(date: .long, time: .shortened)
    }
}

/// QuickLook preview (opens finished files).
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
