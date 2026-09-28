import Foundation

/// Download categories: maps file extensions to a category and target subfolder (mirrors the desktop Category concept).
struct Category: Identifiable, Hashable {
    let id: String
    let symbol: String
    let folder: String
    let extensions: Set<String>

    static let all: [Category] = [
        Category(id: "video", symbol: "film", folder: "Videos",
                 extensions: ["mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v", "mpg", "mpeg", "ts", "vob", "3gp"]),
        Category(id: "music", symbol: "music.note", folder: "Music",
                 extensions: ["mp3", "flac", "wav", "aac", "m4a", "ogg", "ape", "opus", "wma"]),
        Category(id: "documents", symbol: "doc.text", folder: "Documents",
                 extensions: ["pdf", "doc", "docx", "txt", "md", "epub", "mobi", "ppt", "pptx", "xls", "xlsx", "csv", "rtf", "key", "pages", "numbers"]),
        Category(id: "compressed", symbol: "doc.zipper", folder: "Compressed",
                 extensions: ["zip", "rar", "7z", "tar", "gz", "xz", "bz2", "zst", "tgz"]),
        Category(id: "programs", symbol: "app.badge", folder: "Programs",
                 extensions: ["exe", "dmg", "pkg", "deb", "rpm", "msi", "appimage", "iso", "bin"]),
        Category(id: "apks", symbol: "iphone.gen2.badge.play", folder: "APKs",
                 extensions: ["apk", "ipa", "hap"]),
        Category(id: "images", symbol: "photo", folder: "Images",
                 extensions: ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "heic", "tiff", "psd", "ai"]),
    ]

    static let other = Category(id: "other", symbol: "arrow.down.doc", folder: "", extensions: [])

    var localizedName: String {
        if id == Category.other.id {
            return String(localized: "Other")
        }
        return String(localized: String.LocalizationValue(folder))
    }

    static func match(_ name: String) -> Category {
        let ext = splitStemExt(name).ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return all.first { $0.extensions.contains(ext) } ?? other
    }

    static func byId(_ id: String) -> Category {
        all.first { $0.id == id } ?? other
    }
}
