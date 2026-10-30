import AppKit
import SwiftUI

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 画板尺寸常量：宽度铺满屏幕，高度按内容（卡片 + 头尾）计算。
enum LauncherMetrics {
    /// 画板高度 = 头部 44 + 卡片区 244 + 底部 22
    static let shelfHeight: CGFloat = 310
    /// 画板圆角（顶部两角；底部与屏幕边缘齐平保持直角）
    static let cornerRadius: CGFloat = 14
    /// 卡片尺寸
    static let cardSize = CGSize(width: 248, height: 232)
}

/// 画板容器：材质层向下多铺一段，超出窗口的部分会被系统裁掉，
/// 这样只有顶部两角是圆角、底部与屏幕边缘齐平，材质也不会溢出圆角外。
final class ShelfContainerView: NSView {
    let effect = NSVisualEffectView()
    private var hosting: NSHostingView<LauncherView>?

    init(rootView: LauncherView) {
        super.init(frame: .zero)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = LauncherMetrics.cornerRadius
        effect.layer?.masksToBounds = true
        addSubview(effect)

        let hosting = NSHostingView(rootView: rootView)
        // 尺寸完全由 layout() 计算，避免自动伸缩与遮罩区域错位
        hosting.autoresizingMask = []
        effect.addSubview(hosting)
        self.hosting = hosting
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let radius = LauncherMetrics.cornerRadius
        effect.frame = NSRect(x: 0, y: -radius, width: bounds.width, height: bounds.height + radius)
        hosting?.frame = NSRect(x: 0, y: radius, width: bounds.width, height: bounds.height)
    }
}

/// Launcher 面板：无边框浮动窗 + 毛玻璃 + SwiftUI 内容。
@MainActor
final class LauncherController {
    let model: LauncherModel
    private let environment: AppEnvironment
    private var panel: LauncherPanel!
    private var keyMonitor: Any?
    private var wheelMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private(set) var previousApplication: NSRunningApplication?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.model = LauncherModel(repository: environment.repository, settingsStore: environment.settingsStore)
        buildPanel()
        installObservers()
    }

    // MARK: - 显示 / 隐藏

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hideRestoringFocus() : show()
    }

    func show() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApplication = frontmost
        }

        environment.settingsStore.resumeIfExpired()
        model.prepareForShow()
        positionPanel()

        panel.alphaValue = 0
        // 先激活应用再让面板成为 key window，否则键盘事件（⌘C、方向键、Esc）会落到上一个应用。
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
        retryFocusIfNeeded()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    /// 系统可能延迟或拒绝激活，稍后确认一次键盘焦点。
    private func retryFocusIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.panel.isVisible, self.panel.isKeyWindow == false else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.panel.makeKeyAndOrderFront(nil)
            self.panel.makeFirstResponder(self.panel.contentView)
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        model.detailItem = nil
        if model.searchActive {
            model.closeSearch()
        }
    }

    /// 关闭面板并把焦点交还给打开前的应用，否则复制后 ⌘V 仍落在本应用上。
    func hideRestoringFocus() {
        let target = previousApplication
        hide()
        target?.activate(options: [.activateIgnoringOtherApps])
    }

    func refreshIfVisible() {
        guard isVisible, model.detailItem == nil else { return }
        model.reload()
    }

    func flashCaptured(_ item: ClipboardItem) {
        guard isVisible else { return }
        model.showToast("已记录\(item.type.label)")
    }

    func showToast(_ message: String) {
        guard isVisible else { return }
        model.showToast(message)
    }

    // MARK: - 面板构建

    private func buildPanel() {
        let frame = NSRect(x: 0, y: 0, width: 1200, height: LauncherMetrics.shelfHeight)
        panel = LauncherPanel(contentRect: frame,
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered,
                              defer: false)
        panel.isFloatingPanel = false
        panel.level = .statusBar   // 高于 Dock，画板才能覆盖屏幕底部（须在 isFloatingPanel 之后设置）
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let rootView = LauncherView(model: model,
                                    settings: environment.settingsStore,
                                    actions: makeActions())
        let container = ShelfContainerView(rootView: rootView)
        container.frame = frame
        container.autoresizingMask = [.width, .height]
        panel.contentView = container
    }

    private func makeActions() -> LauncherActions {
        LauncherActions(
            paste: { [weak self] item, plain in
                self?.environment.copy(item, plainText: plain, paste: true)
            },
            copyOnly: { [weak self] item, plain in
                guard let self else { return }
                self.environment.copy(item, plainText: plain, paste: false)
                self.model.updateAfterCopy(item)
            },
            setPaused: { [weak self] minutes in
                guard let self else { return }
                self.environment.settingsStore.setPaused(minutes: minutes)
                self.model.showToast(minutes == 0 ? "已恢复记录" : "已暂停记录 \(minutes) 分钟")
            },
            openSettings: { [weak self] in
                self?.hide()
                self?.environment.showSettings()
            },
            clearHistory: { [weak self] in
                self?.confirmClearHistory()
            },
            backup: { [weak self] in
                self?.environment.backupDatabase { url in
                    if let url {
                        self?.model.showToast("已备份到 \(url.lastPathComponent)")
                    } else {
                        self?.model.showToast("备份失败")
                    }
                }
            }
        )
    }

    /// 画板铺满当前屏幕宽度，从屏幕底部往上铺（覆盖 Dock），高度按内容计算。
    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame
        let visible = screen.visibleFrame
        // 底部贴屏幕边缘（覆盖 Dock），顶部不越过菜单栏
        let height = min(LauncherMetrics.shelfHeight, max(visible.maxY - frame.minY, 240))
        let size = NSSize(width: frame.width, height: height)
        let origin = NSPoint(x: frame.minX, y: frame.minY)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func installObservers() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible,
                  event.window === panel || event.window == nil else {
                return event
            }
            return self.handleKey(event) ? nil : event
        }

        // 纵向滚轮 → 横向滚动卡片行（macOS 默认只支持 Shift+滚轮 横滚）
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible,
                  event.window === panel || event.window == nil,
                  self.model.detailItem == nil else {
                return event
            }
            return self.handleWheel(event)
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.hide()
        }
    }

    // MARK: - 滚轮

    /// 把纵向滚轮转换成画板的横向滚动：优先直接驱动滚动视图，找不到时按卡片步进。
    private func handleWheel(_ event: NSEvent) -> NSEvent? {
        guard event.deltaY != 0, event.deltaX == 0 else { return event }
        // 统一换算成「点」：精确滚动设备本身就是点，行滚动设备按行高换算
        let points: CGFloat = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 24

        if let scrollView = boardScrollView() {
            scrollBoard(scrollView, by: points)
            return nil
        }

        let steps = max(1, Int((points / 24).rounded()))
        model.moveSelection(by: -steps)
        return nil
    }

    /// 找到承载卡片行的横向滚动视图（画板上唯一的高滚动视图）。
    private func boardScrollView() -> NSScrollView? {
        guard let content = panel.contentView else { return nil }
        return content.descendantScrollViews().first { $0.frame.height > 200 }
    }

    /// 1:1 滚动，不做动画，保证跟手。
    /// 画板从左到右是「最新 → 最旧」，所以往下滚（deltaY > 0）向左走，即看到更新的内容。
    private func scrollBoard(_ scrollView: NSScrollView, by points: CGFloat) {
        let clip = scrollView.contentView
        guard let document = clip.documentView else { return }
        let maxX = max(0, document.frame.width - clip.bounds.width)
        let target = min(max(0, clip.bounds.origin.x - points), maxX)
        guard abs(target - clip.bounds.origin.x) > 0.01 else { return }
        clip.scroll(to: NSPoint(x: target, y: clip.bounds.origin.y))
    }

    // MARK: - 键盘

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let shift = flags.contains(.shift)

        switch event.keyCode {
        case 53: // Esc
            if model.detailItem != nil {
                model.detailItem = nil
            } else if model.searchActive {
                if !model.searchText.isEmpty {
                    model.searchText = ""
                } else {
                    model.closeSearch()
                }
            } else {
                hideRestoringFocus()
            }
            return true

        case 126, 123: // ↑ / ←
            model.moveSelection(by: -1)
            return true

        case 125, 124: // ↓ / →
            model.moveSelection(by: 1)
            return true

        case 36, 76: // Enter / keypad Enter
            guard let item = model.selectedItem else { return true }
            environment.copy(item, plainText: shift, paste: true)
            return true

        case 51: // Delete
            guard !model.searchActive else { return false }
            if let item = model.selectedItem {
                model.delete(item) {}
            }
            return true

        case 49: // Space
            guard !model.searchActive else { return false }
            if model.detailItem != nil {
                model.detailItem = nil
            } else {
                model.detailItem = model.selectedItem
            }
            return true

        case 3 where cmd: // Cmd+F
            model.openSearch()
            return true

        case 8 where cmd: // Cmd+C
            guard let item = model.selectedItem else { return true }
            environment.copy(item, plainText: false, paste: false)
            hideRestoringFocus()
            return true

        case 3: // F（收藏）
            guard !model.searchActive, !cmd, let item = model.selectedItem else { return false }
            model.toggleFavorite(item) { _ in }
            return true

        default:
            if cmd && event.keyCode == 8 { return true }
            return false
        }
    }

    // MARK: - 清空历史

    private func confirmClearHistory() {
        let alert = NSAlert()
        alert.messageText = "清空全部剪贴板历史？"
        alert.informativeText = "此操作无法撤销，收藏内容也会一并删除。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let repository = environment.repository else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? repository.clear()
            DispatchQueue.main.async {
                self?.model.reload()
                self?.model.showToast("历史已清空")
            }
        }
    }
}

extension NSView {
    /// 递归收集层级内的所有滚动视图（SwiftUI 的 ScrollView 底层就是 NSScrollView）。
    func descendantScrollViews() -> [NSScrollView] {
        var result: [NSScrollView] = []
        if let scrollView = self as? NSScrollView {
            result.append(scrollView)
        }
        for subview in subviews {
            result.append(contentsOf: subview.descendantScrollViews())
        }
        return result
    }
}
