import AppKit
import Foundation

/// 剪贴板读取器：读取 Text / HTML / RTF / URL / File / Image。
final class ClipboardReader {
    /// 内部写入标记，避免把自身复制行为再次记入历史。
    static let internalMarkerType = NSPasteboard.PasteboardType("com.clipboardmanager.mac.internal-write")

    struct ReadResult {
        var data: ClipboardData?
        var changeCount: Int
    }

    func read() -> ReadResult {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount

        guard let marker = pasteboard.string(forType: Self.internalMarkerType) else {
            return ReadResult(data: readFormats(from: pasteboard), changeCount: changeCount)
        }

        var data = ClipboardData()
        data.internalWriteMarker = marker
        return ReadResult(data: data, changeCount: changeCount)
    }

    private func readFormats(from pasteboard: NSPasteboard) -> ClipboardData? {
        // 文件 > 图片 > HTML > RTF > URL > 代码 > 文本
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let text = pasteboard.string(forType: .string)
        let html = pasteboard.data(forType: .html).flatMap { String(data: $0, encoding: .utf8) }
        let rtf = pasteboard.data(forType: .rtf).flatMap { String(data: $0, encoding: .utf8) }
        let imageData = readImageData(from: pasteboard)

        let type: ClipboardType
        if !fileURLs.isEmpty {
            type = .file
        } else if imageData != nil {
            type = .image
        } else if let html, !html.isEmpty {
            type = .html
        } else if let rtf, !rtf.isEmpty {
            type = .rtf
        } else if let text, !text.isEmpty, Self.isURL(text) {
            type = .url
        } else if let text, !text.isEmpty, Self.looksLikeCode(text) {
            type = .code
        } else if let text, !text.isEmpty {
            type = .text
        } else {
            return nil
        }

        let app = NSWorkspace.shared.frontmostApplication
        var data = ClipboardData()
        data.type = type
        data.text = text.flatMap { $0.isEmpty ? nil : $0 }
        data.html = html.flatMap { $0.isEmpty ? nil : $0 }
        data.rtf = rtf.flatMap { $0.isEmpty ? nil : $0 }
        data.filePaths = fileURLs.isEmpty ? nil : fileURLs.map { $0.path }
        data.imageData = imageData
        data.imageExtension = imageData == nil ? nil : "png"
        data.sourceApplication = app?.localizedName
        data.sourceBundleID = app?.bundleIdentifier
        data.size = Self.computeSize(type: type, text: text, html: html, rtf: rtf, files: fileURLs, image: imageData)
        return data
    }

    private func readImageData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png), !png.isEmpty {
            return png
        }
        if let tiff = pasteboard.data(forType: .tiff), !tiff.isEmpty {
            return Self.convertToPNG(tiff)
        }
        return nil
    }

    static func convertToPNG(_ data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func isURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8, !trimmed.contains("\n"), !trimmed.contains(" ") else { return false }
        let lower = trimmed.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("ftp://")
    }

    /// 简单代码特征识别：多行且包含常见代码符号/关键字。
    static func looksLikeCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12, trimmed.contains("\n") else { return false }

        let signals = ["{", "}", ";", "=>", "function ", "class ", "import ", "def ", "const ", "let ", "var ",
                       "public ", "private ", "return ", "</", "#!/", "SELECT ", "CREATE ", "#include"]
        let hits = signals.filter { trimmed.contains($0) }.count
        guard hits >= 2 else { return false }

        let lines = trimmed.split(separator: "\n")
        let indented = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }.count
        return Double(indented) / Double(max(1, lines.count)) > 0.15 || hits >= 3
    }

    static func computeSize(type: ClipboardType, text: String?, html: String?, rtf: String?, files: [URL], image: Data?) -> Int64 {
        if type == .image { return Int64(image?.count ?? 0) }
        var total = 0
        total += text?.utf8.count ?? 0
        total += html?.utf8.count ?? 0
        total += rtf?.utf8.count ?? 0
        total += files.reduce(0) { $0 + $1.path.utf8.count }
        return Int64(total)
    }
}

/// 剪贴板写入器：复制历史条目，并写入内部标记。
final class ClipboardWriter {
    enum WriterError: LocalizedError {
        case empty
        case imageMissing

        var errorDescription: String? {
            switch self {
            case .empty: return "内容为空，无法复制。"
            case .imageMissing: return "图片文件不存在，无法复制。"
            }
        }
    }

    func write(_ item: ClipboardItem, operationID: String = UUID().uuidString) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.type {
        case .text, .url, .code, .unknown:
            guard let text = item.text, !text.isEmpty else { throw WriterError.empty }
            pasteboard.declareTypes([Self.markerType, .string], owner: nil)
            pasteboard.setString(text, forType: .string)

        case .html:
            guard let text = item.text else { throw WriterError.empty }
            pasteboard.declareTypes([Self.markerType, .string, .html], owner: nil)
            pasteboard.setString(text, forType: .string)
            if let html = item.html { pasteboard.setString(html, forType: .html) }

        case .rtf:
            guard let text = item.text else { throw WriterError.empty }
            pasteboard.declareTypes([Self.markerType, .string, .rtf], owner: nil)
            pasteboard.setString(text, forType: .string)
            if let rtf = item.rtf { pasteboard.setString(rtf, forType: .rtf) }

        case .image:
            guard let path = item.imagePath, FileManager.default.fileExists(atPath: path),
                  let image = NSImage(contentsOfFile: path) else { throw WriterError.imageMissing }
            let png = image.tiffRepresentation
                .flatMap { NSBitmapImageRep(data: $0) }
                .flatMap { $0.representation(using: .png, properties: [:]) }
            pasteboard.declareTypes([Self.markerType, .png, .tiff], owner: nil)
            if let png { pasteboard.setData(png, forType: .png) }
            if let tiff = image.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }

        case .file:
            let paths = item.filePathList
            guard !paths.isEmpty else { throw WriterError.empty }
            pasteboard.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
        }

        pasteboard.setString(operationID, forType: Self.markerType)
    }

    private static let markerType = ClipboardReader.internalMarkerType
}

/// 内存中的自身写入保护（与剪贴板标记共同作用）。
final class InternalClipboardGuard {
    private var expiresAt: Date?
    private let lock = NSLock()

    func begin(seconds: TimeInterval = 1.5) {
        lock.lock()
        expiresAt = Date().addingTimeInterval(seconds)
        lock.unlock()
    }

    func isGuarding() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let expiresAt else { return false }
        if Date() > expiresAt {
            self.expiresAt = nil
            return false
        }
        return true
    }
}
