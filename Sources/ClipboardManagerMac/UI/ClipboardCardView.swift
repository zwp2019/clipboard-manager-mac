import AppKit
import SwiftUI

struct ClipboardCardView: View {
    let item: ClipboardItem
    let isSelected: Bool
    let pinboards: [Pinboard]
    let onSelect: () -> Void
    let onPaste: () -> Void
    let onCopy: () -> Void
    let onCopyPlain: () -> Void
    let onToggleFavorite: () -> Void
    let onMoveToGroup: (String?) -> Void
    let onDelete: () -> Void

    @State private var thumbnail: NSImage?
    @State private var appIcon: NSImage?

    private let cardSize = LauncherMetrics.cardSize
    private let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    private var isColorItem: Bool {
        guard item.type == .text, let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return text.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
    }

    private var previewFont: Font {
        // 12.5pt 的常规中文在暗色卡片上笔画太细，观感会「发虚」，统一用 13pt 正文
        item.type == .code ? Typography.mono : Typography.body
    }

    private var headerTextColor: Color {
        item.type.prefersDarkHeaderText ? Color(hex: "#3A2C00") : .white
    }

    private var footerText: String {
        switch item.type {
        case .image: return item.sourceTitle ?? "图片"
        case .url:
            if let text = item.text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return url.host.map { $0 + (url.path == "/" ? "" : url.path) } ?? text
            }
            return textFallback
        case .file: return item.fileSummary
        default: return "\(item.characterCount) 个字符"
        }
    }

    private var textFallback: String {
        let text = (item.previewText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 500 ? String(text.prefix(500)) : text
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isColorItem, let color = item.text?.trimmingCharacters(in: .whitespacesAndNewlines) {
                colorBody(color)
            } else if item.type == .image {
                imageBody
            } else {
                textBody
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        // 先裁切内容，再把带阴影的背景垫在后面。
        // 若把 .shadow 加在整张卡上，SwiftUI 会把「包含文字」的整棵子树离屏栅格化后再投影，
        // 字形在这一步被当作图片重新合成，边缘会明显发虚。
        .clipShape(cardShape)
        .overlay(
            cardShape.strokeBorder(isSelected ? Palette.accent : Palette.rim,
                                   lineWidth: isSelected ? 2 : 0.75)
        )
        // 只让描边做过渡动画；阴影放在动画之外，避免逐帧重算模糊导致卡顿
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .background {
            cardShape
                .fill(LinearGradient(colors: [Palette.cardSurfaceTop, Palette.cardSurfaceBottom],
                                     startPoint: .top, endPoint: .bottom))
                .shadow(color: isSelected ? Palette.accent.opacity(0.26) : .black.opacity(0.10),
                        radius: isSelected ? 10 : 7,
                        y: isSelected ? 4 : 3)
        }
        .overlay(alignment: .topLeading) {
            if item.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Circle().fill(Color.black.opacity(0.28)))
                    .padding(7)
                    .offset(x: cardSize.width - 26)
            }
        }
        // 只让描边做过渡动画；阴影放在动画之外，避免逐帧重算模糊导致卡顿
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .shadow(color: isSelected ? Palette.accent.opacity(0.26) : .black.opacity(0.10),
                radius: isSelected ? 10 : 7,
                y: isSelected ? 4 : 3)
        // 单击立即选中、双击粘贴：两个手势并行，单击不再等双击判定超时
        .onTapGesture(count: 2, perform: onPaste)
        .simultaneousGesture(TapGesture(count: 1).onEnded { onSelect() })
        .contextMenu {
            Button("粘贴到当前应用") { onPaste() }
            Button("复制到剪贴板") { onCopy() }
            Button("复制为纯文本") { onCopyPlain() }
            Divider()
            Button(item.isFavorite ? "取消收藏" : "收藏") { onToggleFavorite() }
            Menu("移入收藏板") {
                Button("未分组") { onMoveToGroup(nil) }
                ForEach(pinboards) { board in
                    Button(board.name) { onMoveToGroup(board.name) }
                }
            }
            Divider()
            Button("删除", role: .destructive) { onDelete() }
        }
        .onAppear { loadAssets() }
    }

    private var headerColor: Color { Color(hex: item.type.headerHex) }

    private var header: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(isColorItem ? "颜色" : item.type.label)
                    .font(.system(size: 12.5, weight: .medium))
                Text(item.createdAt.clipboardRelativeText)
                    .font(.system(size: 10))
                    .opacity(0.86)
            }
            .foregroundStyle(headerTextColor)
            .padding(.leading, 12)
            .padding(.top, 7)
            .frame(maxHeight: .infinity, alignment: .topLeading)

            Spacer(minLength: 4)

            // 图标放进半透明方块，避免大图标直接压色块显得廉价
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.20))
                    .frame(width: 30, height: 30)
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: symbolName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(headerTextColor)
                }
            }
            .frame(width: 42, height: 42)
        }
        .frame(height: 46)
        .background(
            LinearGradient(colors: [headerColor.mixed(with: .white, amount: 0.16), headerColor],
                           startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.28))
                .frame(height: 0.5)
        }
    }

    private var symbolName: String {
        switch item.type {
        case .image: return "photo"
        case .url: return "link"
        case .file: return "doc"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .html: return "globe"
        case .rtf: return "textformat"
        default: return "doc.plaintext"
        }
    }

    private var textBody: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                if let title = item.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                }
                Text(textFallback)
                    .font(previewFont)
                    .foregroundStyle(Palette.textPrimary)
                    .lineSpacing(2)
                    .lineLimit(item.title == nil ? 7 : 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.top, 9)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [Palette.cardSurfaceBottom.opacity(0), Palette.cardSurfaceBottom],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 22)
                    .allowsHitTesting(false)
            }

            HStack {
                Spacer()
                Text(footerText)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                Spacer()
            }
            .frame(height: 24)
            .padding(.horizontal, 12)
            .padding(.bottom, 3)
        }
    }

    private var imageBody: some View {
        ZStack {
            Palette.imagePlaceholder
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "photo")
                        .font(.system(size: 26))
                        .foregroundStyle(Palette.textTertiary)
                    Text("正在载入图片…")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(footerText)
                        .font(Typography.caption)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.62)))
                        .padding(7)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func colorBody(_ hex: String) -> some View {
        let color = Color(hex: hex)
        let isLight = contrastIsLight(hex)
        return ZStack {
            color
            Text(hex.uppercased())
                .font(.system(size: 23, weight: .semibold, design: .monospaced))
                .foregroundStyle(isLight ? .black : .white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func contrastIsLight(_ hex: String) -> Bool {
        var value = hex.replacingOccurrences(of: "#", with: "")
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        var number: UInt64 = 0
        Scanner(string: value).scanHexInt64(&number)
        let r = Double((number >> 16) & 0xFF)
        let g = Double((number >> 8) & 0xFF)
        let b = Double(number & 0xFF)
        return (r * 0.299 + g * 0.587 + b * 0.114) > 160
    }

    private func loadAssets() {
        if item.type == .image {
            if let path = item.thumbnailPath ?? item.imagePath, thumbnail == nil {
                AssetLoader.shared.loadThumbnail(path: path) { image in
                    thumbnail = image
                }
            }
        }
        if appIcon == nil, let bundleID = item.sourceBundleID, !bundleID.isEmpty {
            AssetLoader.shared.loadIcon(bundleID: bundleID) { image in
                appIcon = image
            }
        }
    }
}
