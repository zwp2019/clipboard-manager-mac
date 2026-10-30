import AppKit
import SwiftUI

/// 偏好设置窗口。
@MainActor
final class SettingsWindowController {
    private let environment: AppEnvironment
    private var window: NSWindow?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: SettingsView(store: environment.settingsStore,
                                                                environment: environment))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered,
                                  defer: false)
            window.title = "剪贴板管理器 · 偏好设置"
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 720, height: 520)
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}

/// 菜单栏（系统托盘）入口。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let environment: AppEnvironment
    private let statusItem: NSStatusItem
    private var hotkeyItem: NSMenuItem?
    private var pauseItem: NSMenuItem?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        buildMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "剪贴板管理器")
        image?.isTemplate = true
        button.image = image
        button.image?.size = NSSize(width: 16, height: 16)
        button.toolTip = "剪贴板管理器"
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let open = NSMenuItem(title: "打开剪贴板", action: #selector(openLauncher), keyEquivalent: "v")
        open.keyEquivalentModifierMask = [.command, .shift]
        open.target = self
        menu.addItem(open)
        hotkeyItem = open
        menu.addItem(.separator())

        let favorites = NSMenuItem(title: "查看收藏", action: #selector(openFavorites), keyEquivalent: "")
        favorites.target = self
        menu.addItem(favorites)

        pauseItem = NSMenuItem(title: "暂停记录", action: nil, keyEquivalent: "")
        let pauseMenu = NSMenu()
        let pause5 = NSMenuItem(title: "暂停 5 分钟", action: #selector(pause5), keyEquivalent: "")
        pause5.target = self
        let pause30 = NSMenuItem(title: "暂停 30 分钟", action: #selector(pause30), keyEquivalent: "")
        pause30.target = self
        let resume = NSMenuItem(title: "恢复记录", action: #selector(resumeRecording), keyEquivalent: "")
        resume.target = self
        pauseMenu.addItem(pause5)
        pauseMenu.addItem(pause30)
        pauseMenu.addItem(.separator())
        pauseMenu.addItem(resume)
        pauseItem?.submenu = pauseMenu
        if let pauseItem { menu.addItem(pauseItem) }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "偏好设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let backup = NSMenuItem(title: "备份数据库", action: #selector(backup), keyEquivalent: "")
        backup.target = self
        menu.addItem(backup)

        let dataFolder = NSMenuItem(title: "打开数据目录", action: #selector(openDataFolder), keyEquivalent: "")
        dataFolder.target = self
        menu.addItem(dataFolder)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出剪贴板管理器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func setHotkeyAvailable(_ available: Bool) {
        hotkeyItem?.title = available ? "打开剪贴板" : "打开剪贴板（全局快捷键注册失败）"
    }

    func menuWillOpen(_ menu: NSMenu) {
        environment.settingsStore.resumeIfExpired()
        pauseItem?.title = environment.settingsStore.settings.isPaused ? "暂停记录 · 已暂停" : "暂停记录"
    }

    @objc private func openLauncher() {
        environment.showLauncher()
    }

    @objc private func openFavorites() {
        environment.showLauncher()
    }

    @objc private func pause5() {
        environment.settingsStore.setPaused(minutes: 5)
    }

    @objc private func pause30() {
        environment.settingsStore.setPaused(minutes: 30)
    }

    @objc private func resumeRecording() {
        environment.settingsStore.setPaused(minutes: 0)
    }

    @objc private func openSettings() {
        environment.showSettings()
    }

    @objc private func backup() {
        environment.backupDatabase { url in
            if let url {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    @objc private func openDataFolder() {
        NSWorkspace.shared.open(AppPaths.root)
    }
}
