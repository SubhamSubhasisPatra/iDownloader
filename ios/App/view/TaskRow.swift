import SwiftUI

/// One task row: a table-style multi-column layout on wide screens, a compact card row on narrow ones.
struct TaskRow: View {
    let record: TaskRecord
    let isRegular: Bool

    var body: some View {
        if isRegular {
            regularRow
        } else {
            compactRow
        }
    }

    // MARK: - Wide screens (iPad / Mac)

    private var regularRow: some View {
        HStack(spacing: 12) {
            Image(systemName: record.category.symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if record.status == .failed, !record.errorMessage.isEmpty {
                    Text(record.errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if record.status == .running, record.kind == "torrent", record.peers > 0 {
                    Text("\(record.category.localizedName) · \(String(localized: "Peers: \(record.peers)"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(record.category.localizedName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(displaySize)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 138, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            StatusCell(record: record)
                .frame(width: 150, alignment: .leading)

            Text(timeLeftText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            Text(dateText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)

            Image(systemName: "ellipsis")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 24)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: - Narrow screens (iPhone)

    private var compactRow: some View {
        HStack(spacing: 12) {
            Image(systemName: record.category.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 6) {
                Text(record.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(compactStatusLine)
                    .font(.caption)
                    .foregroundStyle(record.status == .failed ? Color.red : Color.secondary)
                    .lineLimit(1)
                if record.status == .running || record.status == .paused {
                    GradientProgressbar(value: record.progress)
                        .frame(height: 5)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "ellipsis")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var compactStatusLine: String {
        var parts: [String] = []
        switch record.status {
        case .waiting: parts.append(String(localized: "Queued"))
        case .running:
            parts.append(record.fileSize > 0 ? "\(Int(record.progress * 100))%" : String(localized: "Running"))
        case .paused: parts.append(String(localized: "Paused"))
        case .completed: parts.append(String(localized: "Completed"))
        case .failed:
            parts.append(record.errorMessage.isEmpty ? String(localized: "Failed") : record.errorMessage)
        }
        parts.append(displaySize)
        if record.speed > 0 {
            parts.append(toDockSpeed(record.speed))
        }
        if record.status == .running, record.kind == "torrent", record.peers > 0 {
            parts.append(String(localized: "Peers: \(record.peers)"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Cell contents

    private var displaySize: String {
        if record.fileSize > 0 {
            return "\(toReadableSize(record.receivedBytes)) / \(toReadableSize(record.fileSize))"
        }
        return toReadableSize(record.receivedBytes)
    }

    private var timeLeftText: String {
        guard let seconds = record.timeLeft else { return "—" }
        return toReadableTime(seconds)
    }

    private var dateText: String {
        let timestamp = record.completedAt > 0 ? record.completedAt : record.createdAt
        guard timestamp > 0 else { return "—" }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
            .formatted(date: .abbreviated, time: .omitted)
    }
}
