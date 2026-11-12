import AppKit
import Combine
import SwiftUI

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, clipboard, appearance, shortcuts, privacy, storage, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .clipboard: return "剪贴板"
        case .appearance: return "外观"
        case .shortcuts: return "快捷键"
        case .privacy: return "隐私"
        case .storage: return "存储"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .clipboard: return "doc.on.clipboard"
        case .appearance: return "paintpalette"
        case .shortcuts: return "keyboard"
        case .privacy: return "lock.shield"
        case .storage: return "internaldrive"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    let environment: AppEnvironment

    @State private var category: SettingsCategory = .general
    @State private var recordingHotkey = false
    @State private var excludedInput = ""
    @State private var historyCount = 0
    @State private var databaseSize = "—"
    /// 辅助功能授权状态：每 1s 轮询一次，用户在系统设置里开关后无需重启即可刷新。
    @State private var accessibilityTrusted = Paster.isTrusted()
    private let trustTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 184)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(category.title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    content
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            refreshStats()
            accessibilityTrusted = Paster.isTrusted()
        }
        .onReceive(trustTicker) { _ in
            let trusted = Paster.isTrusted()
            if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsCategory.allCases) { item in
                Button {
                    category = item
                    if item == .storage { refreshStats() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12))
                            .frame(width: 16)
                        Text(item.title)
                            .font(.system(size: 12.5))
                        Spacer()
                    }
                    .foregroundStyle(category == item ? Palette.textPrimary : Palette.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(category == item ? Palette.accent.opacity(0.16) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        switch category {
        case .general: generalSection
        case .clipboard: clipboardSection
        case .appearance: appearanceSection
        case .shortcuts: shortcutsSection
        case .privacy: privacySection
        case .storage: storageSection
        case .about: aboutSection
        }
    }

    // MARK: - 通用

    private var generalSection: some View {
        VStack(spacing: 0) {
            SettingsRow(title: "登录时自动启动", subtitle: "仅在 macOS 登录后静默启动，不弹窗打扰。") {
                Toggle("", isOn: Binding(
                    get: { store.settings.autoStart },
                    set: { value in
                        store.update { $0.autoStart = value }
                        store.applyAutoStart(value)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            SettingsRow(title: "允许自动粘贴", subtitle: "需要在“系统设置 › 隐私与安全性 › 辅助功能”中授权。") {
                HStack(spacing: 8) {
                    Text(accessibilityTrusted ? "已授权" : "未授权")
                        .font(Typography.caption)
                        .foregroundStyle(accessibilityTrusted ? Palette.textSecondary : Palette.danger)
                    Button("去授权") { requestAccessibilityPermission() }
                        .buttonStyle(PillButtonStyle())
                }
            }
            if !accessibilityTrusted {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.danger)
                        Text("如果辅助功能列表里的开关已经打开，这里仍显示“未授权”，说明这条授权记录属于之前的构建版本、已经失效：请在列表中选中“剪贴板管理器”，点左下角“−”移除，再用“+”重新添加当前这个 App，然后重启应用。")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("重新启动应用") { restartApp() }
                        .buttonStyle(PillButtonStyle())
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Palette.control.opacity(0.6))
                )
            }
            SettingsRow(title: "复制后行为", subtitle: "开启后，选择条目将默认只复制纯文本。") {
                Toggle("", isOn: Binding(
                    get: { store.settings.alwaysPastePlainText },
                    set: { value in store.update { $0.alwaysPastePlainText = value } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
        }
    }

    // MARK: - 剪贴板

    private var clipboardSection: some View {
        VStack(spacing: 0) {
            SettingsRow(title: "内容去重", subtitle: "相同内容只保留一条，并移动到最前。") {
                Toggle("", isOn: Binding(
                    get: { store.settings.enableDeduplication },
                    set: { value in store.update { $0.enableDeduplication = value } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            SettingsRow(title: "图片处理", subtitle: "生成缩略图，并在本地识别图片文字用于搜索。") {
                Toggle("", isOn: Binding(
                    get: { store.settings.imageCompression },
                    set: { value in store.update { $0.imageCompression = value } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            SettingsRow(title: "历史保留", subtitle: "超期内容会在后台清理，收藏内容不受影响。") {
                Picker("", selection: Binding(
                    get: { store.settings.retentionDays },
                    set: { value in store.update { $0.retentionDays = value } }
                )) {
                    Text("1 天").tag(1)
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                    Text("永久").tag(0)
                }
                .labelsHidden()
                .frame(width: 110)
            }
            SettingsRow(title: "最大条数", subtitle: "超出上限时自动清理最旧的非收藏条目。") {
                Stepper(value: Binding(
                    get: { store.settings.maxHistoryItems },
                    set: { value in store.update { $0.maxHistoryItems = value } }
                ), in: 1000...500000, step: 1000) {
                    Text("\(store.settings.maxHistoryItems)")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Palette.textPrimary)
                }
                .frame(width: 120)
            }
            SettingsRow(title: "暂停记录", subtitle: "暂停期间复制的任何内容都不会写入历史。") {
                HStack(spacing: 8) {
                    if store.settings.isPaused {
                        Button("恢复记录") { store.setPaused(minutes: 0) }
                            .buttonStyle(PillButtonStyle())
                    } else {
                        Button("5 分钟") { store.setPaused(minutes: 5) }
                            .buttonStyle(PillButtonStyle())
                        Button("30 分钟") { store.setPaused(minutes: 30) }
                            .buttonStyle(PillButtonStyle())
                    }
                }
            }
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        VStack(spacing: 0) {
            SettingsRow(title: "主题", subtitle: "跟随系统，或强制使用浅色 / 深色。") {
                Picker("", selection: Binding(
                    get: { store.settings.theme },
                    set: { value in
                        store.update { $0.theme = value }
                        SettingsStore.applyTheme(value)
                    }
                )) {
                    Text("跟随系统").tag(ThemeMode.system)
                    Text("浅色").tag(ThemeMode.light)
                    Text("深色").tag(ThemeMode.dark)
                }
                .labelsHidden()
                .frame(width: 120)
            }
        }
    }

    // MARK: - 快捷键

    private var shortcutsSection: some View {
        VStack(spacing: 0) {
            SettingsRow(title: "呼出剪贴板", subtitle: "全局生效。若与其他应用冲突，请更换组合键。") {
                HStack(spacing: 8) {
                    if recordingHotkey {
                        HotkeyRecorderView { keyCode, modifiers, description in
                            store.update {
                                $0.hotkeyKeyCode = keyCode
                                $0.hotkeyModifiers = modifiers
                                $0.hotkeyDescription = description
                            }
                            recordingHotkey = false
                        }
                        .frame(width: 130, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Palette.searchBackground)
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.accent.opacity(0.6), lineWidth: 1))
                        )
                        Text("按下组合键…")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textTertiary)
                    } else {
                        Text(hotkeyDescription)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Palette.control))
                        Button("更改") { recordingHotkey = true }
                            .buttonStyle(PillButtonStyle())
                    }
                    Button("恢复默认") {
                        store.update {
                            $0.hotkeyKeyCode = 9
                            $0.hotkeyModifiers = 0x0100 | 0x0200
                            $0.hotkeyDescription = "⌘ ⇧ V"
                        }
                    }
                    .buttonStyle(PillButtonStyle())
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("键盘操作")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                shortcutRow("↑ ↓ ← →", "在历史卡片之间移动")
                shortcutRow("Enter", "复制并粘贴到上一个应用")
                shortcutRow("Shift + Enter", "以纯文本粘贴")
                shortcutRow("⌘ C", "只复制，不粘贴")
                shortcutRow("Space", "查看详情")
                shortcutRow("F", "收藏 / 取消收藏")
                shortcutRow("Delete", "删除当前条目")
                shortcutRow("Esc", "关闭搜索或面板")
            }
            .padding(.top, 6)
        }
    }

    private var hotkeyDescription: String {
        let settings = store.settings
        return settings.hotkeyDescription.isEmpty
            ? GlobalHotkey.description(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
            : settings.hotkeyDescription
    }

    private func shortcutRow(_ key: String, _ description: String) -> some View {
        HStack(spacing: 10) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 96, alignment: .leading)
            Text(description)
                .font(Typography.secondary)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    // MARK: - 隐私

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("以下应用复制的内容不会记入历史。可以填写应用名称或 Bundle ID。")
                .font(Typography.secondary)
                .foregroundStyle(Palette.textSecondary)

            HStack(spacing: 8) {
                TextField("应用名称或 com.example.app", text: $excludedInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.searchBackground))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.rim, lineWidth: 0.5))
                Button("添加") { addExcluded(excludedInput) }
                    .buttonStyle(PillButtonStyle())
                    .disabled(excludedInput.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("添加当前应用") {
                    if let app = environment.launcher.previousApplication {
                        addExcluded(app.bundleIdentifier ?? app.localizedName ?? "")
                    }
                }
                .buttonStyle(PillButtonStyle())
                .disabled(environment.launcher.previousApplication == nil)
            }

            if store.settings.excludedApplications.isEmpty {
                Text("尚未排除任何应用")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 6) {
                    ForEach(store.settings.excludedApplications, id: \.self) { entry in
                        HStack {
                            Image(systemName: "nosign")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.danger)
                            Text(entry)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.textPrimary)
                            Spacer()
                            Button {
                                store.update { $0.excludedApplications.removeAll { $0 == entry } }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.control.opacity(0.7)))
                    }
                }
            }

            Text("提示：密码管理器、银行类应用建议排除。应用从不联网，所有内容仅保存在本机。")
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private func addExcluded(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !store.settings.excludedApplications.contains(trimmed) else { return }
        store.update { $0.excludedApplications.append(trimmed) }
        excludedInput = ""
    }

    // MARK: - 存储

    private var storageSection: some View {
        VStack(spacing: 0) {
            SettingsRow(title: "历史条目", subtitle: nil) {
                Text("\(historyCount) 条")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textPrimary)
            }
            SettingsRow(title: "数据库大小", subtitle: nil) {
                Text(databaseSize)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textPrimary)
            }
            SettingsRow(title: "数据目录", subtitle: AppPaths.root.path) {
                HStack(spacing: 8) {
                    Button("打开") { NSWorkspace.shared.open(AppPaths.root) }
                        .buttonStyle(PillButtonStyle())
                }
            }
            SettingsRow(title: "备份数据库", subtitle: "使用 VACUUM INTO 生成一致性快照，便于恢复。") {
                Button("立即备份") {
                    environment.backupDatabase { url in
                        if let url {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
                .buttonStyle(PillButtonStyle())
            }
            SettingsRow(title: "清空历史", subtitle: "删除全部条目，包括收藏与图片文件索引。") {
                Button("清空…") { clearHistoryWithConfirm() }
                    .buttonStyle(DangerPillButtonStyle())
            }
        }
    }

    private func refreshStats() {
        DispatchQueue.global(qos: .utility).async {
            let count = (try? environment.repository.count()) ?? 0
            let attributes = try? FileManager.default.attributesOfItem(atPath: AppPaths.databaseFile.path)
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            DispatchQueue.main.async {
                historyCount = count
                databaseSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            }
        }
    }

    private func clearHistoryWithConfirm() {
        let alert = NSAlert()
        alert.messageText = "清空全部剪贴板历史？"
        alert.informativeText = "此操作无法撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? environment.repository.clear()
            DispatchQueue.main.async { refreshStats() }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("剪贴板管理器")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text("版本 1.0.0 · macOS 原生版")
                        .font(Typography.secondary)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            Divider()
            Text("Swift · SwiftUI · AppKit · SQLite · Vision OCR · Carbon 热键")
                .font(Typography.secondary)
                .foregroundStyle(Palette.textSecondary)
            Text("所有剪贴板内容仅保存在本机，不上传、不联网。")
                .font(Typography.secondary)
                .foregroundStyle(Palette.textSecondary)
            HStack(spacing: 8) {
                Button("打开辅助功能设置") { openAccessibilitySettings() }
                    .buttonStyle(PillButtonStyle())
                Button("查看日志") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.logs])
                }
                .buttonStyle(PillButtonStyle())
            }
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 先走系统授权提示：只有调用这个 API，当前这个构建版本才会被正式登记进辅助功能列表，
    /// 手动打开系统设置再拨开关，很容易拨到旧构建残留的那条失效记录上。
    private func requestAccessibilityPermission() {
        _ = Paster.isTrusted(prompt: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            let trusted = Paster.isTrusted()
            accessibilityTrusted = trusted
            if !trusted { openAccessibilitySettings() }
        }
    }

    /// 授权状态只在进程启动时读取一次，改动后需要重启进程才会生效。
    private func restartApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// MARK: - 行样式

private struct SettingsRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: () -> Trailing

    init(title: String, subtitle: String?, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rim.opacity(0.7)).frame(height: 0.5)
        }
    }
}

// MARK: - 热键录制

private final class HotkeyRecorderNSView: NSView {
    var onChange: ((UInt32, UInt32, String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !flags.isEmpty else {
            NSSound.beep()
            return
        }
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= GlobalHotkey.cmdKey }
        if flags.contains(.shift) { carbon |= GlobalHotkey.shiftKey }
        if flags.contains(.option) { carbon |= GlobalHotkey.optionKey }
        if flags.contains(.control) { carbon |= GlobalHotkey.controlKey }

        let keyCode = UInt32(event.keyCode)
        let label = GlobalHotkey.description(keyCode: keyCode, modifiers: carbon)
        onChange?(keyCode, carbon, label)
    }
}

private struct HotkeyRecorderView: NSViewRepresentable {
    var onChange: (UInt32, UInt32, String) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.onChange = onChange
    }
}
