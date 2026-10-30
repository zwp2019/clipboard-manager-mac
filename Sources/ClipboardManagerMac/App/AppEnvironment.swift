import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var settings: AppSettings

    private let repository: SettingsRepository
    var onChange: ((AppSettings) -> Void)?

    init(repository: SettingsRepository) {
        self.repository = repository
        self.settings = repository.load()
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
        repository.save(copy)
        onChange?(copy)
    }

    func setPaused(minutes: Int) {
        update { settings in
            if minutes > 0 {
                settings.pauseMonitoring = true
                settings.pauseUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
            } else {
                settings.pauseMonitoring = false
                settings.pauseUntil = nil
            }
        }
    }

    func resumeIfExpired() {
        guard settings.pauseMonitoring, let until = settings.pauseUntil, Date() >= until else { return }
        update { $0.pauseMonitoring = false; $0.pauseUntil = nil }
    }

    func applyAutoStart(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AppLog.warning("auto start update failed: \(error.localizedDescription)")
        }
    }

    static func applyTheme(_ mode: ThemeMode) {
        switch mode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// 应用装配根：对应原项目 DI 容器 + 启动流程。
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    private(set) var database: SQLiteDatabase!
    private(set) var repository: ClipboardRepository!
    private(set) var settingsStore: SettingsStore!
    private(set) var pipeline: ClipboardPipeline!
    private(set) var writer = ClipboardWriter()
    private(set) var hotkey = GlobalHotkey()
    private(set) var launcher: LauncherController!
    private(set) var menuBar: MenuBarController!
    private(set) var settingsWindow: SettingsWindowController!
    private(set) var copyToast: CopyToastController!

    private var started = false

    func bootstrap() throws {
        guard !started else { return }
        try AppPaths.prepare()

        database = try SQLiteDatabase(path: AppPaths.databaseFile.path)
        repository = ClipboardRepository(db: database)
        settingsStore = SettingsStore(repository: SettingsRepository(db: database))

        let imageStore = ImageStore()
        let ocr = OCRService()
        pipeline = ClipboardPipeline(repository: repository,
                                     imageStore: imageStore,
                                     ocrService: ocr,
                                     settings: { [weak self] in self?.settingsStore.settings ?? AppSettings() })
        pipeline.start()

        settingsStore.onChange = { [weak self] settings in
            self?.apply(settings)
        }
        SettingsStore.applyTheme(settingsStore.settings.theme)

        launcher = LauncherController(environment: self)
        settingsWindow = SettingsWindowController(environment: self)
        menuBar = MenuBarController(environment: self)
        copyToast = CopyToastController()

        registerHotkey()
        settingsStore.resumeIfExpired()

        pipeline.onChanged = { [weak self] in
            self?.launcher.refreshIfVisible()
        }
        pipeline.onCaptured = { [weak self] item in
            self?.launcher.flashCaptured(item)
        }

        started = true
        AppLog.info("application bootstrapped")
    }

    func apply(_ settings: AppSettings) {
        SettingsStore.applyTheme(settings.theme)
        registerHotkey()
    }

    func registerHotkey() {
        let settings = settingsStore.settings
        let success = hotkey.register(keyCode: settings.hotkeyKeyCode,
                                      modifiers: settings.hotkeyModifiers) { [weak self] in
            self?.launcher.toggle()
        }
        if !success {
            AppLog.warning("global hotkey registration failed")
            menuBar?.setHotkeyAvailable(false)
        } else {
            menuBar?.setHotkeyAvailable(true)
        }
    }

    func shutdown() {
        pipeline?.stop()
        hotkey.unregister()
    }

    func showLauncher() { launcher.show() }
    func showSettings() { settingsWindow.show() }

    func copy(_ item: ClipboardItem, plainText: Bool, paste: Bool) {
        var target = item
        if plainText, let text = item.text {
            target = ClipboardItem(id: item.id, type: .text, text: text)
        }
        do {
            try writer.write(target)
            pipeline.markInternalWrite()
        } catch {
            AppLog.error("clipboard write failed: \(error.localizedDescription)")
            copyToast.show(item: target, success: false)
            return
        }

        copyToast.show(item: target, success: true)

        guard paste else { return }

        let previous = launcher.previousApplication
        launcher.hide()
        Paster.activateAndPaste(into: previous) { [weak self] pasted in
            guard let self, !pasted else { return }
            self.copyToast.show(item: target,
                                success: true,
                                subtitle: "已复制。开启“辅助功能”权限后可自动粘贴")
        }
    }

    func backupDatabase(completion: ((URL?) -> Void)? = nil) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = AppPaths.backups.appendingPathComponent("clipboard-\(formatter.string(from: Date())).db")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var result: URL?
            do {
                try self?.database.backup(to: destination.path)
                result = destination
            } catch {
                AppLog.error("backup failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { completion?(result) }
        }
    }
}

/// 全局热键（Carbon RegisterEventHotKey，无需辅助功能权限）。
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var trigger: (() -> Void)?

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static let signature: OSType = 0x434D4752 // 'CMGR'

    static let cmdKey: UInt32 = 0x0100
    static let shiftKey: UInt32 = 0x0200
    static let optionKey: UInt32 = 0x0800
    static let controlKey: UInt32 = 0x1000

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, onTrigger: @escaping () -> Void) -> Bool {
        unregister()
        trigger = onTrigger

        if eventHandler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotkeyID = EventHotKeyID()
                let error = GetEventParameter(event,
                                              EventParamName(kEventParamDirectObject),
                                              EventParamType(typeEventHotKeyID),
                                              nil,
                                              MemoryLayout<EventHotKeyID>.size,
                                              nil,
                                              &hotkeyID)
                guard error == noErr else { return OSStatus(eventNotHandledErr) }
                GlobalHotkey.handlers[hotkeyID.id]?()
                return noErr
            }, 1, &eventType, nil, &eventHandler)
            if status != noErr {
                AppLog.warning("install hotkey handler failed: \(status)")
                eventHandler = nil
                return false
            }
        }

        let id = Self.nextID
        Self.nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            AppLog.warning("register hotkey failed: \(status) (might conflict with another app)")
            return false
        }
        hotKeyRef = ref
        Self.handlers[id] = onTrigger
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        for key in Self.handlers.keys {
            Self.handlers.removeValue(forKey: key)
        }
        trigger = nil
    }

    static func description(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts = ""
        if modifiers & controlKey != 0 { parts += "⌃ " }
        if modifiers & optionKey != 0 { parts += "⌥ " }
        if modifiers & shiftKey != 0 { parts += "⇧ " }
        if modifiers & cmdKey != 0 { parts += "⌘ " }
        return parts + keyLabel(keyCode)
    }

    static func keyLabel(_ keyCode: UInt32) -> String {
        let letters: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
            36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "Esc"
        ]
        return letters[keyCode] ?? "按键\(keyCode)"
    }
}

/// 模拟粘贴：需要用户授予“辅助功能”权限。
enum Paster {
    static func isTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func activateAndPaste(into application: NSRunningApplication?, completion: @escaping (Bool) -> Void) {
        // 先交还焦点，即使没有辅助功能权限也能手动 ⌘V。
        application?.activate(options: [.activateIgnoringOtherApps])
        guard isTrusted() else {
            completion(false)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            sendCommandV()
            completion(true)
        }
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
