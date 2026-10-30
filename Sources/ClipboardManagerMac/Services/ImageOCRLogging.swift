import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// 图片落盘：原图 + 缩略图（列表只加载缩略图）。
final class ImageStore {
    struct Saved {
        let imagePath: String
        let thumbnailPath: String
        let pixelSize: String
    }

    private let calendarFolder: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMM"
        return formatter
    }()

    func save(pngData: Data, hash: String, generateThumbnail: Bool = true) throws -> Saved {
        let folder = calendarFolder.string(from: Date())
        let imageDir = AppPaths.images.appendingPathComponent(folder, isDirectory: true)
        let thumbDir = AppPaths.thumbnails.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)

        let name = String(hash.prefix(24))
        let imageURL = imageDir.appendingPathComponent("\(name).png")
        let thumbURL = thumbDir.appendingPathComponent("\(name).png")
        try pngData.write(to: imageURL, options: .atomic)

        let sizeText = Self.pixelSize(of: pngData)
        if generateThumbnail {
            Self.writeThumbnail(from: pngData, to: thumbURL, maxPixelSize: 512)
        }
        let thumbnail = FileManager.default.fileExists(atPath: thumbURL.path) ? thumbURL.path : imageURL.path
        return Saved(imagePath: imageURL.path, thumbnailPath: thumbnail, pixelSize: sizeText)
    }

    static func pixelSize(of data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return "图片"
        }
        return "\(width) × \(height)"
    }

    static func writeThumbnail(from data: Data, to url: URL, maxPixelSize: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        CGImageDestinationFinalize(destination)
    }
}

/// 本地图片文字识别（Vision，无网络请求）。
final class OCRService {
    static let shared = OCRService()

    func recognize(imagePath: String, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let text = Self.recognizeSync(imagePath: imagePath)
            DispatchQueue.main.async { completion(text) }
        }
    }

    static func recognizeSync(imagePath: String) -> String {
        guard FileManager.default.fileExists(atPath: imagePath),
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            AppLog.warning("OCR failed: \(error.localizedDescription)")
            return ""
        }
        let observations = request.results ?? []
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

/// 内容指纹（SHA-256）。
enum HashService {
    static func hash(data: ClipboardData) -> String {
        switch data.type {
        case .image:
            return "img:" + sha256(data.imageData ?? Data())
        case .file:
            let joined = (data.filePaths ?? []).joined(separator: "|")
            return "file:" + sha256(Data(joined.utf8))
        default:
            let joined = "\(data.type.rawValue)|\(data.text ?? "")|\(data.html ?? "")|\(data.rtf ?? "")"
            return "txt:" + sha256(Data(joined.utf8))
        }
    }

    static func hash(text: String, type: ClipboardType = .text) -> String {
        "txt:" + sha256(Data("\(type.rawValue)|\(text)".utf8))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 轻量日志：只记录类型、大小、来源与错误，不记录剪贴板内容。
enum AppLog {
    private static let queue = DispatchQueue(label: "ClipboardManager.Log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func info(_ message: String) { write("INFO", message) }
    static func warning(_ message: String) { write("WARN", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] [\(level)] \(message)\n"
        queue.async {
            let file = AppPaths.logs.appendingPathComponent("app.log")
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) { handle.write(data) }
                try? handle.close()
            } else {
                try? line.data(using: .utf8)?.write(to: file)
            }
        }
    }
}
