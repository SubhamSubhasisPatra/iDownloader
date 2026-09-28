import Foundation

func toReadableSize(_ size: Int64) -> String {
    var value = Double(size)
    for unit in ["B", "KB", "MB", "GB"] {
        if value < 1024 {
            return String(format: "%.2f %@", value, unit)
        }
        value /= 1024
    }
    return String(format: "%.2f TB", value)
}

func toDockSpeed(_ bytesPerSec: Int64) -> String {
    if bytesPerSec < 1024 {
        return "\(bytesPerSec) B/s"
    }
    var value = Double(bytesPerSec) / 1024
    if value < 1024 {
        return String(format: "%.1f K/s", value)
    }
    value /= 1024
    if value < 1024 {
        return String(format: "%.1f M/s", value)
    }
    value /= 1024
    return String(format: "%.1f G/s", value)
}

func toSafeFilename(_ name: String, fallback: String = "download") -> String {
    let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
    let trimSet = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "."))
    var candidate = name.components(separatedBy: invalid).joined(separator: "_")
        .trimmingCharacters(in: trimSet)

    if candidate.isEmpty || candidate == "." || candidate == ".." {
        return fallback
    }

    let reserved = ["CON", "PRN", "AUX", "NUL",
                    "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
                    "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"]
    let root = candidate.prefix { $0 != "." }.uppercased()
    if reserved.contains(root) {
        candidate = "_" + candidate
    }

    let maxLength = 200
    if candidate.count > maxLength {
        let (stem, ext) = splitStemExt(candidate)
        if !ext.isEmpty, stem.count < maxLength {
            candidate = String(stem.prefix(maxLength - ext.count)) + ext
        } else {
            candidate = String(candidate.prefix(maxLength))
        }
    }
    return candidate
}

func splitStemExt(_ name: String) -> (stem: String, ext: String) {
    if let range = name.range(of: #"\.[A-Za-z0-9]{1,4}\.(?:bz2?|gz|lzma|lzo|xz|z|zst)$"#, options: .regularExpression) {
        return (String(name[..<range.lowerBound]), String(name[range.lowerBound...]))
    }
    guard let dot = name.lastIndex(of: "."), dot > name.startIndex else {
        return (name, "")
    }
    return (String(name[..<dot]), String(name[dot...]))
}

func uniqueName(_ name: String, in folder: URL) -> String {
    var candidate = name
    var index = 1
    while FileManager.default.fileExists(atPath: folder.appending(path: candidate).path) {
        let (stem, ext) = splitStemExt(name)
        candidate = "\(stem)(\(index))\(ext)"
        index += 1
    }
    return candidate
}

func toName(from url: URL) -> String {
    let segments = url.pathComponents.filter { $0 != "/" }
    let last = segments.last ?? ""
    let decoded = last.removingPercentEncoding ?? last
    return toSafeFilename(decoded)
}
