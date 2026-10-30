import AppKit
import SwiftUI

/// 复制结果提示卡片（对齐 Windows 版 clipboard-manager 的 OverlayToast 视觉）。
/// 尺寸 352×76、圆角 20、左上 40×40 图标块 + 右下绿色对勾徽章、右侧 ⌘V 提示键帽。
struct CopyToastView: View {
    let item: ClipboardItem
    let success: Bool
    var subtitle: String?

    private var accent: Color {
        switch item.type {
        case .image: return Color(hex: "#E76E82")
        case .url: return Color(hex: "#5A9BE2")
        case .code: return Color(hex: "#8F79CE")
        case .file: return Color(hex: "#66A67B")
        case .html, .rtf: return Color(hex: "#0E9AA7")
        default: return Color(hex: "#EFC453")
        }
    }

    private var symbol: String {
        switch item.type {
        case .image: return "photo"
        case .url: return "link"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .file: return "doc"
        default: return "doc.plaintext"
        }
    }

    /// 副标题：默认显示内容摘要，最多 80 字。
    private var detail: String {
        if let subtitle { return subtitle }
        switch item.type {
        case .image:
            let title = item.sourceTitle ?? ""
            return title.isEmpty ? "图片" : "图片 · \(title)"
        case .file:
            return item.fileSummary
        default:
            let text = (item.previewText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return "新内容" }
            return text.count > 80 ? String(text.prefix(80)) + "…" : text
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            iconTile
            VStack(alignment: .leading, spacing: 3) {
                Text(success ? "已复制" : "复制失败")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.top, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if success { keycap }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .frame(width: 352, height: 76)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Palette.toastTop, Palette.toastBottom],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Palette.toastRim, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
    }

    private var iconTile: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [accent.opacity(0.92), accent],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white)
                )
            if success {
                Circle()
                    .fill(Color(hex: "#30A46C"))
                    .frame(width: 16, height: 16)
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .offset(x: 6, y: 6)
            }
        }
        .frame(width: 40, height: 40)
    }

    private var keycap: some View {
        Text("⌘V")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Palette.textSecondary)
            .frame(width: 53, height: 19)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Palette.textPrimary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Palette.textPrimary.opacity(0.07), lineWidth: 0.7)
            )
            .padding(.top, 1)
    }
}

/// 复制提示浮层：置顶、不抢焦点、鼠标穿透，1.2 秒后自动淡出（失败 2.8 秒）。
@MainActor
final class CopyToastController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var dismissWorkItem: DispatchWorkItem?

    /// 提示出现在屏幕底部居中、距底 24pt（与 Windows 版 OverlayToast 一致）。
    func show(item: ClipboardItem, success: Bool, subtitle: String? = nil) {
        dismissWorkItem?.cancel()

        let size = NSSize(width: 352, height: 76)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24)

        if panel == nil {
            buildPanel(size: size)
        }
        hosting?.rootView = AnyView(CopyToastView(item: item, success: success, subtitle: subtitle))

        guard let panel else { return }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.09
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                panel.orderOut(nil)
            }
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (success ? 1.2 : 2.8), execute: work)
    }

    private func buildPanel(size: NSSize) {
        let toastPanel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered,
                                  defer: false)
        toastPanel.isFloatingPanel = false
        toastPanel.level = .popUpMenu   // 始终浮在画板之上（须在 isFloatingPanel 之后设置）
        toastPanel.becomesKeyOnlyIfNeeded = false
        toastPanel.hidesOnDeactivate = false
        toastPanel.isOpaque = false
        toastPanel.backgroundColor = .clear
        toastPanel.hasShadow = false
        toastPanel.ignoresMouseEvents = true
        toastPanel.isReleasedWhenClosed = false
        toastPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.frame = toastPanel.frame
        hosting.autoresizingMask = [.width, .height]
        toastPanel.contentView = hosting

        panel = toastPanel
        self.hosting = hosting
    }
}
