import Foundation

/// 剪贴板内容类型（对齐原项目 ClipboardType）。
enum ClipboardType: Int, CaseIterable {
    case text = 0
    case image = 1
    case html = 2
    case rtf = 3
    case url = 4
    case file = 5
    case code = 6
    case unknown = 7

    var label: String {
        switch self {
        case .image: return "图片"
        case .url: return "链接"
        case .file: return "文件"
        case .code: return "代码"
        case .html: return "网页"
        case .rtf: return "富文本"
        default: return "文本"
        }
    }

    /// 卡片头部强调色，沿用原项目 Design Token。
    var headerHex: String {
        switch self {
        case .image: return "#FF4D68"
        case .url: return "#078BFA"
        case .file: return "#2BB77B"
        case .code: return "#9170D4"
        case .html, .rtf: return "#0E9AA7"
        default: return "#FFBE00"
        }
    }

    /// 文本卡使用暖色底 + 深色字，其余使用白字。
    var prefersDarkHeaderText: Bool { self == .text || self == .unknown }
}

struct ClipboardItem: Identifiable, Equatable {
    var id: Int64 = 0
    var title: String?
    var ocrText: String?
    var type: ClipboardType = .text
    var text: String?
    var html: String?
    var rtf: String?
    var imagePath: String?
    var thumbnailPath: String?
    var filePaths: String?
    var sourceApplication: String?
    var sourceTitle: String?
    var sourceBundleID: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var hash: String = ""
    var size: Int64 = 0
    var isFavorite: Bool = false
    var groupName: String?
    var isDeleted: Bool = false

    var filePathList: [String] {
        guard let filePaths, let data = filePaths.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    var fileSummary: String {
        let paths = filePathList
        switch paths.count {
        case 0: return "文件"
        case 1: return (paths[0] as NSString).lastPathComponent
        default: return "\((paths[0] as NSString).lastPathComponent) 等 \(paths.count) 项"
        }
    }

    var previewText: String? {
        if let text, !text.isEmpty { return text }
        if type == .image { return "[图片]" }
        if type == .file { return fileSummary }
        return nil
    }

    var characterCount: Int {
        (text ?? "").count
    }

    /// 列表主标题：自定义标题 > 链接主机名 > 文件摘要 > 类型名。
    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        if type == .url, let text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           let host = url.host {
            return sourceTitle ?? host
        }
        if type == .file { return fileSummary }
        if let text, !text.isEmpty {
            return String(text.prefix(40))
        }
        return type.label
    }
}

/// 剪贴板读取结果（尚未归一化）。
struct ClipboardData {
    var type: ClipboardType = .text
    var text: String?
    var html: String?
    var rtf: String?
    var filePaths: [String]?
    var imageData: Data?
    var imageExtension: String?
    var size: Int64 = 0
    var sourceApplication: String?
    var sourceTitle: String?
    var sourceBundleID: String?
    var internalWriteMarker: String?
}

/// 组合过滤条件，全部下推到 SQLite 执行。
struct ClipboardQuery {
    var text: String = ""
    var type: ClipboardType?
    var source: String?
    var since: Date?
    var group: String?
    var favoritesOnly: Bool = false
}

struct Pinboard: Identifiable, Hashable {
    var name: String
    var color: String = "#9170D4"
    var position: Int = 0
    var id: String { name }
}

enum ThemeMode: String, Codable, CaseIterable {
    case system
    case light
    case dark
}

/// 应用设置（对齐原项目 AppSettings）。
struct AppSettings: Codable, Equatable {
    var hotkeyKeyCode: UInt32 = 9                 // kVK_ANSI_V
    var hotkeyModifiers: UInt32 = 0x0100 | 0x0200 // cmd + shift
    var autoStart: Bool = false
    var theme: ThemeMode = .system
    var retentionDays: Int = 30                   // 0 = 永久
    var enableDeduplication: Bool = true
    var maxHistoryItems: Int = 50000
    var imageCompression: Bool = true
    var excludedApplications: [String] = []
    var pauseMonitoring: Bool = false
    var pauseUntil: Date?
    var alwaysPastePlainText: Bool = false
    var hotkeyDescription: String = "⌘ ⇧ V"

    var isPaused: Bool {
        guard pauseMonitoring else { return false }
        if let pauseUntil { return Date() < pauseUntil }
        return true
    }
}
