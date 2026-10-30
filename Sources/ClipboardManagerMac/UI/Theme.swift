import AppKit
import SwiftUI

/// Design Tokens：所有颜色集中管理，支持深浅色。
enum Palette {
    static let cardSurface = dynamic(light: NSColor.white, dark: NSColor(srgbRed: 0.161, green: 0.165, blue: 0.184, alpha: 1))
    /// 卡片表面渐变（上：更亮；下：略沉），做出纸张般的层次；带轻微透明，与画板玻璃融为一体
    static let cardSurfaceTop = dynamic(light: NSColor.white.withAlphaComponent(0.96),
                                        dark: NSColor(srgbRed: 0.184, green: 0.188, blue: 0.208, alpha: 0.94))
    static let cardSurfaceBottom = dynamic(light: NSColor(srgbRed: 0.965, green: 0.969, blue: 0.980, alpha: 0.92),
                                           dark: NSColor(srgbRed: 0.145, green: 0.149, blue: 0.169, alpha: 0.90))
    /// 画板玻璃：整体色调层（压出“烟熏玻璃”的质感，避免材质发灰发脏）
    static let glassTint = dynamic(light: NSColor.black.withAlphaComponent(0.05),
                                   dark: NSColor.black.withAlphaComponent(0.16))
    /// 画板玻璃：顶部高光带
    static let glassSheen = dynamic(light: NSColor.white.withAlphaComponent(0.22),
                                    dark: NSColor.white.withAlphaComponent(0.06))
    /// 画板玻璃：顶部描边（与上方内容的分界）
    static let glassEdge = dynamic(light: NSColor.black.withAlphaComponent(0.13),
                                   dark: NSColor.white.withAlphaComponent(0.10))
    static let surfaceHover = dynamic(light: NSColor(srgbRed: 0.965, green: 0.967, blue: 0.973, alpha: 1),
                                      dark: NSColor(srgbRed: 0.196, green: 0.204, blue: 0.231, alpha: 1))
    static let textPrimary = dynamic(light: NSColor(srgbRed: 0.102, green: 0.118, blue: 0.157, alpha: 1),
                                     dark: NSColor(srgbRed: 0.949, green: 0.953, blue: 0.965, alpha: 1))
    static let textSecondary = dynamic(light: NSColor(srgbRed: 0.404, green: 0.435, blue: 0.494, alpha: 1),
                                       dark: NSColor(srgbRed: 0.643, green: 0.671, blue: 0.722, alpha: 1))
    static let textTertiary = dynamic(light: NSColor(srgbRed: 0.604, green: 0.631, blue: 0.678, alpha: 1),
                                      dark: NSColor(srgbRed: 0.478, green: 0.506, blue: 0.549, alpha: 1))
    static let control = dynamic(light: NSColor.white.withAlphaComponent(0.72),
                                 dark: NSColor(srgbRed: 0.208, green: 0.212, blue: 0.239, alpha: 1))
    static let controlHover = dynamic(light: NSColor.white.withAlphaComponent(0.95),
                                      dark: NSColor(srgbRed: 0.263, green: 0.271, blue: 0.306, alpha: 1))
    static let rim = dynamic(light: NSColor.black.withAlphaComponent(0.10),
                             dark: NSColor.white.withAlphaComponent(0.14))
    static let accent = dynamic(light: NSColor(srgbRed: 0.443, green: 0.400, blue: 0.847, alpha: 1),
                                dark: NSColor(srgbRed: 0.698, green: 0.659, blue: 1.0, alpha: 1))
    static let danger = dynamic(light: NSColor(srgbRed: 0.722, green: 0.255, blue: 0.314, alpha: 1),
                                dark: NSColor(srgbRed: 1.0, green: 0.627, blue: 0.671, alpha: 1))
    static let favorite = Color(hex: "#FF4D68")
    static let searchBackground = dynamic(light: NSColor(srgbRed: 0.949, green: 0.957, blue: 0.988, alpha: 1),
                                          dark: NSColor(srgbRed: 0.153, green: 0.169, blue: 0.220, alpha: 1))
    static let imagePlaceholder = dynamic(light: NSColor(srgbRed: 0.933, green: 0.941, blue: 0.957, alpha: 1),
                                          dark: NSColor(srgbRed: 0.114, green: 0.125, blue: 0.149, alpha: 1))
    // 复制提示卡片（对齐 Windows 版样式）
    static let toastTop = dynamic(light: NSColor(srgbRed: 0.984, green: 1.0, blue: 1.0, alpha: 1),
                                  dark: NSColor(srgbRed: 0.200, green: 0.204, blue: 0.224, alpha: 1))
    static let toastBottom = dynamic(light: NSColor(srgbRed: 0.965, green: 0.969, blue: 0.984, alpha: 1),
                                     dark: NSColor(srgbRed: 0.149, green: 0.153, blue: 0.173, alpha: 1))
    static let toastRim = dynamic(light: NSColor(srgbRed: 0.231, green: 0.263, blue: 0.322, alpha: 0.106),
                                  dark: NSColor.white.withAlphaComponent(0.15))

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? dark : light
        }))
    }
}

extension Color {
    init(hex: String) {
        var value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        var number: UInt64 = 0
        Scanner(string: value).scanHexInt64(&number)
        self.init(red: Double((number >> 16) & 0xFF) / 255,
                  green: Double((number >> 8) & 0xFF) / 255,
                  blue: Double(number & 0xFF) / 255)
    }

    /// 与另一颜色按比例混合（amount = 0 保持自身，1 变为另一颜色）。
    func mixed(with other: Color, amount: Double) -> Color {
        let source: NSColor = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let target: NSColor = NSColor(other).usingColorSpace(.sRGB) ?? .white
        let t: Double = max(0, min(1, amount))
        let keep: Double = 1 - t
        let red: Double = Double(source.redComponent) * keep + Double(target.redComponent) * t
        let green: Double = Double(source.greenComponent) * keep + Double(target.greenComponent) * t
        let blue: Double = Double(source.blueComponent) * keep + Double(target.blueComponent) * t
        let alpha: Double = Double(source.alphaComponent) * keep + Double(target.alphaComponent) * t
        return Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

enum Typography {
    static let title = Font.system(size: 20, weight: .semibold)
    static let body = Font.system(size: 13)
    static let secondary = Font.system(size: 12)
    static let caption = Font.system(size: 10.5)
    static let mono = Font.system(size: 12, design: .monospaced)
}

/// 缩略图 / 应用图标异步加载与缓存。
final class AssetLoader {
    static let shared = AssetLoader()
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private let iconCache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "ClipboardManager.Assets", qos: .utility, attributes: .concurrent)

    init() {
        thumbnailCache.countLimit = 240
        iconCache.countLimit = 80
    }

    func cachedThumbnail(path: String) -> NSImage? {
        thumbnailCache.object(forKey: path as NSString)
    }

    func loadThumbnail(path: String, completion: @escaping (NSImage?) -> Void) {
        if let cached = cachedThumbnail(path: path) {
            completion(cached)
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            let image = NSImage(contentsOfFile: path)
            if let image { self.thumbnailCache.setObject(image, forKey: path as NSString) }
            DispatchQueue.main.async { completion(image) }
        }
    }

    func loadIcon(bundleID: String?, completion: @escaping (NSImage?) -> Void) {
        guard let bundleID, !bundleID.isEmpty else {
            completion(nil)
            return
        }
        if let cached = iconCache.object(forKey: bundleID as NSString) {
            completion(cached)
            return
        }
        queue.async { [weak self] in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            var image: NSImage?
            if let url {
                image = NSWorkspace.shared.icon(forFile: url.path)
                image?.size = NSSize(width: 64, height: 64)
            }
            if let image { self?.iconCache.setObject(image, forKey: bundleID as NSString) }
            DispatchQueue.main.async { completion(image) }
        }
    }
}

extension Date {
    /// 卡片时间文案（与原项目一致）。
    var clipboardRelativeText: String {
        let elapsed = Date().timeIntervalSince(self)
        if elapsed < 60 { return "刚刚" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) 分钟前" }
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "\(Int(elapsed / 3600)) 小时前" }
        if calendar.isDateInYesterday(self) { return "昨天" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: self)
    }

    var clipboardDetailText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: self)
    }
}
