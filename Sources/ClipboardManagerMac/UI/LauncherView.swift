import AppKit
import SwiftUI

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var settings: SettingsStore
    let actions: LauncherActions

    @State private var showPinboardSheet = false
    @State private var pinboardName = ""
    @State private var pinboardColor = "#9170D4"
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                header
                content
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // 玻璃三层结构：色调层 + 顶部高光带
                ZStack {
                    Palette.glassTint
                    VStack(spacing: 0) {
                        LinearGradient(colors: [Palette.glassSheen, Color.clear],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 96)
                        Spacer(minLength: 0)
                    }
                }
            }
            .overlay(alignment: .top) {
                // 顶部分界细线，玻璃边缘更利落
                Rectangle()
                    .fill(Palette.glassEdge)
                    .frame(height: 0.5)
            }

            if let detail = model.detailItem {
                ItemDetailOverlay(item: detail,
                                  model: model,
                                  actions: actions,
                                  onClose: { model.detailItem = nil })
                    .transition(.opacity)
                    .zIndex(2)
            }

            if showPinboardSheet {
                PinboardEditor(name: $pinboardName, color: $pinboardColor) {
                    showPinboardSheet = false
                } onSave: {
                    model.savePinboard(name: pinboardName, color: pinboardColor)
                    showPinboardSheet = false
                }
                .zIndex(3)
            }

            if let toast = model.toastText {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(.regularMaterial)
                                .overlay(Capsule().strokeBorder(Palette.rim, lineWidth: 0.5))
                        )
                        .padding(.bottom, 42)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
                .zIndex(4)
            }
        }
        .onChange(of: model.focusToken) { _, _ in
            if model.searchActive {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
            }
        }
        .onChange(of: model.searchActive) { _, active in
            if active {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
            } else {
                searchFocused = false
            }
        }
        .onAppear {
            model.loadPinboards()
            if model.items.isEmpty { model.reload() }
        }
        .overlay {
            // 画板外沿描边：贴屏幕底部，顶部两角圆角
            UnevenRoundedRectangle(topLeadingRadius: LauncherMetrics.cornerRadius,
                                   bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 0,
                                   topTrailingRadius: LauncherMetrics.cornerRadius)
                .inset(by: 0.5)
                .strokeBorder(Palette.rim, lineWidth: 0.75)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            searchControl
            HStack(spacing: 6) {
                chip(title: "剪贴板", symbol: "doc.on.clipboard", isSelected: model.scope == .all) {
                    model.setScope(.all)
                }
                chip(title: "收藏", dotColor: Palette.favorite, isSelected: model.scope == .favorites) {
                    model.setScope(.favorites)
                }
                ForEach(model.pinboards) { board in
                    chip(title: board.name,
                         dotColor: Color(hex: board.color),
                         isSelected: model.scope == .group(board.name)) {
                        model.setScope(.group(board.name))
                    }
                    .contextMenu {
                        Button("删除收藏板") { model.deletePinboard(board.name) }
                    }
                }
                Button {
                    pinboardName = ""
                    pinboardColor = "#9170D4"
                    showPinboardSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.control))
                }
                .buttonStyle(.plain)
                .help("新建收藏板")
            }
            .padding(.horizontal, 2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .overlay(alignment: .trailing) {
            overflowMenu
                .padding(.trailing, 12)
        }
    }

    private var searchControl: some View {
        HStack(spacing: 6) {
            if model.searchActive {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                    TextField("搜索剪贴板…", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($searchFocused)
                        .onSubmit {
                            if let item = model.selectedItem { actions.paste(item, false) }
                        }
                }
                .padding(.horizontal, 8)
                .frame(width: 220, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.searchBackground))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.rim, lineWidth: 0.5))
                .transition(.opacity.combined(with: .move(edge: .leading)))
            } else {
                Button {
                    model.openSearch()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.control))
                }
                .buttonStyle(.plain)
                .help("搜索 (⌘F)")
            }
        }
        .animation(.easeOut(duration: 0.16), value: model.searchActive)
    }

    private func chip(title: String, symbol: String? = nil, dotColor: Color? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10.5))
                }
                if let dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                }
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Palette.controlHover : Palette.control.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Palette.accent.opacity(0.55) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var overflowMenu: some View {
        Menu {
            Menu("内容类型") {
                Button("全部内容") { model.setScope(.all) }
                Button("文本") { model.setScope(.type(.text)) }
                Button("链接") { model.setScope(.type(.url)) }
                Button("图片") { model.setScope(.type(.image)) }
                Button("代码") { model.setScope(.type(.code)) }
                Button("文件") { model.setScope(.type(.file)) }
            }
            Menu("暂停记录") {
                if settings.settings.isPaused {
                    Button("恢复记录") { actions.setPaused(0) }
                } else {
                    Button("暂停 5 分钟") { actions.setPaused(5) }
                    Button("暂停 30 分钟") { actions.setPaused(30) }
                }
            }
            Divider()
            Button("清空历史…") { actions.clearHistory() }
            Button("备份数据库") { actions.backup() }
            Divider()
            Button("偏好设置…") { actions.openSettings() }
            Button("关于剪贴板管理器") {
                NSApp.orderFrontStandardAboutPanel(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("退出") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多操作")
    }

    // MARK: - Content

    private var content: some View {
        ZStack {
            if model.items.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            ClipboardCardView(
                                item: item,
                                isSelected: index == model.selectedIndex,
                                pinboards: model.pinboards,
                                onSelect: { model.select(item) },
                                onPaste: { actions.paste(item, false) },
                                onCopy: { actions.copyOnly(item, false) },
                                onCopyPlain: { actions.copyOnly(item, true) },
                                onToggleFavorite: {
                                    model.toggleFavorite(item) { updated in
                                        if model.detailItem?.id == updated.id { model.detailItem = updated }
                                    }
                                },
                                onMoveToGroup: { group in model.moveToGroup(item, group: group) },
                                onDelete: { model.delete(item) {} }
                            )
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, 20)
                                            .padding(.vertical, 6)
                                        }

                .scrollPosition(id: $model.centeredItemID, anchor: .center)
                .onChange(of: model.scrollRequestToken) { _, _ in
                    // 只有方向键导航才把选中项滚到中间，点击卡片不会触发居中
                    let index = model.selectedIndex
                    guard model.items.indices.contains(index) else { return }
                    let id = model.items[index].id
                    guard id != model.centeredItemID else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        model.centeredItemID = id
                    }
                }
                .onChange(of: model.centeredItemID) { _, id in
                    // 滚轮滚动时同步选中项，方向键与滚轮行为一致
                    guard let id, let index = model.items.firstIndex(where: { $0.id == id }) else { return }
                    guard index != model.selectedIndex else { return }
                    model.select(model.items[index])
                }
            }

            if model.isLoading, model.items.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.searchText.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(Palette.textTertiary)
            Text(model.searchText.isEmpty ? model.emptyTitle : "没有匹配内容")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Text(model.searchText.isEmpty ? "复制一些内容，或换个关键词试试" : "换个关键词试试")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
            if !model.searchText.isEmpty {
                Text("Esc 退出搜索")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(model.statusText)
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
            Spacer()
            if model.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            }
            if model.hasMore {
                Button {
                    model.loadMore()
                } label: {
                    Text("更多历史 →")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 22)
    }
}

// MARK: - 详情面板

private struct ItemDetailOverlay: View {
    let item: ClipboardItem
    @ObservedObject var model: LauncherModel
    let actions: LauncherActions
    let onClose: () -> Void

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.18))
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(hex: item.type.headerHex))
                        .frame(width: 8, height: 8)
                    Text(item.type.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text(item.createdAt.clipboardDetailText)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    if let source = item.sourceApplication {
                        Text("· \(source)")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.textSecondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Palette.control))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)

                Divider().opacity(0.4)

                ScrollView {
                    detailContent
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider().opacity(0.4)

                HStack(spacing: 8) {
                    Button("粘贴") { actions.paste(item, false) }
                        .buttonStyle(PrimaryPillButtonStyle())
                    Button("复制") { actions.copyOnly(item, false) }
                        .buttonStyle(PillButtonStyle())
                    Button("纯文本") { actions.copyOnly(item, true) }
                        .buttonStyle(PillButtonStyle())
                    if item.type == .image {
                        Button("识别文字") { model.extractText(item) }
                            .buttonStyle(PillButtonStyle())
                    }
                    Button(item.isFavorite ? "取消收藏" : "收藏") {
                        model.toggleFavorite(item) { updated in model.detailItem = updated }
                    }
                    .buttonStyle(PillButtonStyle())
                    Spacer()
                    Button("删除") { model.delete(item) {} }
                        .buttonStyle(DangerPillButtonStyle())
                }
                .padding(.horizontal, 16)
                .frame(height: 50)
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.rim, lineWidth: 0.75))
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.24), radius: 22, y: 8)
            .padding(22)
        }
        .onAppear {
            if item.type == .image, let path = item.imagePath {
                image = NSImage(contentsOfFile: path)
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch item.type {
        case .image:
            VStack(alignment: .leading, spacing: 12) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 210)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.imagePlaceholder))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                HStack(spacing: 12) {
                    if let size = item.sourceTitle {
                        metaPill(size)
                    }
                    metaPill(byteText(item.size))
                }
                if let ocr = item.ocrText, !ocr.isEmpty {
                    Text("识别文字")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                    Text(ocr)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.textPrimary)
                        .textSelection(.enabled)
                }
            }
        case .file:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(item.filePathList, id: \.self) { path in
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .foregroundStyle(Palette.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((path as NSString).lastPathComponent)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Palette.textPrimary)
                            Text(path)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textTertiary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        default:
            Text(item.text ?? item.previewText ?? "")
                .font(item.type == .code ? Font.system(size: 12.5, design: .monospaced) : Font.system(size: 13))
                .foregroundStyle(Palette.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metaPill(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Palette.control))
    }

    private func byteText(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

// MARK: - 收藏板编辑

private struct PinboardEditor: View {
    @Binding var name: String
    @Binding var color: String
    let onCancel: () -> Void
    let onSave: () -> Void

    private let colors = ["#9170D4", "#FF4D68", "#2BB77B", "#078BFA", "#FFBE00", "#0E9AA7"]

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.2))
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 12) {
                Text("新建收藏板")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                TextField("收藏板名称", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.searchBackground))
                HStack(spacing: 8) {
                    ForEach(colors, id: \.self) { value in
                        Circle()
                            .fill(Color(hex: value))
                            .frame(width: 20, height: 20)
                            .overlay(
                                Circle().strokeBorder(color == value ? Palette.textPrimary : Color.clear, lineWidth: 2)
                            )
                            .onTapGesture { color = value }
                    }
                }
                HStack {
                    Spacer()
                    Button("取消", action: onCancel)
                        .buttonStyle(PillButtonStyle())
                    Button("创建", action: onSave)
                        .buttonStyle(PrimaryPillButtonStyle())
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(18)
            .frame(width: 300)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.rim, lineWidth: 0.75))
            )
            .shadow(color: .black.opacity(0.2), radius: 18, y: 6)
        }
    }
}

// MARK: - 按钮样式

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(Palette.control.opacity(configuration.isPressed ? 1 : 0.7)))
            .overlay(Capsule().strokeBorder(Palette.rim, lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct PrimaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 5)
            .background(Capsule().fill(Palette.accent.opacity(configuration.isPressed ? 0.8 : 1)))
    }
}

struct DangerPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(Palette.danger)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(Palette.control.opacity(0.7)))
            .overlay(Capsule().strokeBorder(Palette.danger.opacity(0.35), lineWidth: 0.5))
    }
}
