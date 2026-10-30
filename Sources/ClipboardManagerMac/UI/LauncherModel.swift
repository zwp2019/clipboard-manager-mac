import AppKit
import Combine
import Foundation
import SwiftUI

struct LauncherActions {
    var paste: (ClipboardItem, Bool) -> Void
    var copyOnly: (ClipboardItem, Bool) -> Void
    var setPaused: (Int) -> Void
    var openSettings: () -> Void
    var clearHistory: () -> Void
    var backup: () -> Void
}

final class LauncherModel: ObservableObject {
    enum Scope: Equatable {
        case all
        case favorites
        case type(ClipboardType)
        case group(String)

        var title: String {
            switch self {
            case .all: return "全部历史"
            case .favorites: return "收藏"
            case .type(let type):
                switch type {
                case .image: return "图片"
                case .url: return "链接"
                case .file: return "文件"
                case .code: return "代码"
                default: return type.label
                }
            case .group(let name): return name
            }
        }
    }

    static let pageSize = 80

    @Published private(set) var items: [ClipboardItem] = []
    @Published var selectedIndex: Int = 0
    /// 当前滚动到视口中央的卡片（滚轮 / 方向键都会同步这里）
    @Published var centeredItemID: Int64?
    /// 方向键导航时请求把选中项滚动到视野中央（点击选中不触发，避免点击即居中）
    @Published private(set) var scrollRequestToken: Int = 0
    @Published var searchText: String = "" {
        didSet { scheduleSearch() }
    }
    @Published var searchActive = false
    @Published private(set) var scope: Scope = .all
    @Published private(set) var pinboards: [Pinboard] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published private(set) var totalCount = 0
    @Published var statusText = "你的剪贴板，井然有序"
    @Published var toastText: String?
    @Published var detailItem: ClipboardItem?
    @Published var focusToken = 0

    private let repository: ClipboardRepository
    private let settingsStore: SettingsStore
    private var searchWorkItem: DispatchWorkItem?
    private var loadGeneration = 0
    private var toastWorkItem: DispatchWorkItem?
    /// 打开面板时置位，数据到位后把画板滚回第一条
    private var needsScrollReset = false

    init(repository: ClipboardRepository, settingsStore: SettingsStore) {
        self.repository = repository
        self.settingsStore = settingsStore
    }

    var selectedItem: ClipboardItem? {
        guard items.indices.contains(selectedIndex) else { return items.first }
        return items[selectedIndex]
    }

    var emptyTitle: String { scope.title }

    // MARK: - 加载

    func prepareForShow() {
        searchActive = false
        searchText = ""
        detailItem = nil
        focusToken += 1
        // 每次打开都回到第一页（最新的内容在最左侧）
        needsScrollReset = true
        centeredItemID = nil
        selectedIndex = 0
        loadPinboards()
        reload()
    }

    func openSearch() {
        searchActive = true
        focusToken += 1
    }

    func closeSearch() {
        searchActive = false
        searchText = ""
    }

    func reload() {
        load(reset: true)
    }

    func refreshIfVisible() {
        load(reset: true)
    }

    func loadMore() {
        guard hasMore, !isLoading else { return }
        load(reset: false)
    }

    func setScope(_ scope: Scope) {
        self.scope = scope
        selectedIndex = 0
        load(reset: true)
    }

    func loadPinboards() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let boards = (try? self.repository.pinboards()) ?? []
            DispatchQueue.main.async {
                self.pinboards = boards
            }
        }
    }

    private func currentQuery() -> ClipboardQuery {
        var query = ClipboardQuery()
        query.text = searchText
        switch scope {
        case .all:
            break
        case .favorites:
            query.favoritesOnly = true
        case .type(let type):
            query.type = type
        case .group(let name):
            query.group = name
        }
        return query
    }

    private func load(reset: Bool) {
        loadGeneration += 1
        let generation = loadGeneration
        let query = currentQuery()
        let offset = reset ? 0 : items.count
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let rows = (try? self.repository.query(query, offset: offset, limit: Self.pageSize)) ?? []
            let total = (try? self.repository.count()) ?? 0
            DispatchQueue.main.async {
                guard generation == self.loadGeneration else { return }
                if reset {
                    self.items = rows
                    self.selectedIndex = rows.isEmpty ? 0 : min(self.selectedIndex, rows.count - 1)
                    if self.needsScrollReset {
                        // 打开面板后滚回第一条（最新内容）
                        self.needsScrollReset = false
                        self.centeredItemID = rows.first?.id
                    }
                } else {
                    let existing = Set(self.items.map(\.id))
                    self.items.append(contentsOf: rows.filter { !existing.contains($0.id) })
                }
                self.hasMore = rows.count == Self.pageSize
                self.totalCount = total
                self.isLoading = false
                let suffix = self.hasMore ? "+" : ""
                self.statusText = "\(self.scope.title) · \(self.items.count) 项\(suffix)"
                if let detail = self.detailItem, let updated = self.items.first(where: { $0.id == detail.id }) {
                    self.detailItem = updated
                }
            }
        }
    }

    private func scheduleSearch() {
        searchWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.selectedIndex = 0
            self.load(reset: true)
        }
        searchWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    // MARK: - 选择与操作

    func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + offset), items.count - 1)
        scrollRequestToken += 1
    }

    func select(_ item: ClipboardItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            selectedIndex = index
        }
    }

    func toggleFavorite(_ item: ClipboardItem, completion: @escaping (ClipboardItem) -> Void) {
        let newValue = !item.isFavorite
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? self?.repository.setFavorite(id: item.id, favorite: newValue)
            DispatchQueue.main.async {
                guard let self else { return }
                if let index = self.items.firstIndex(where: { $0.id == item.id }) {
                    self.items[index].isFavorite = newValue
                    completion(self.items[index])
                }
                if case .favorites = self.scope, !newValue {
                    self.load(reset: true)
                }
            }
        }
    }

    func delete(_ item: ClipboardItem, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? self?.repository.delete(id: item.id)
            DispatchQueue.main.async {
                guard let self else { return }
                if let index = self.items.firstIndex(where: { $0.id == item.id }) {
                    self.items.remove(at: index)
                    self.selectedIndex = min(self.selectedIndex, max(0, self.items.count - 1))
                }
                if self.detailItem?.id == item.id { self.detailItem = nil }
                self.statusText = "\(self.scope.title) · \(self.items.count) 项"
                self.showToast("已删除")
                completion()
            }
        }
    }

    func moveToGroup(_ item: ClipboardItem, group: String?, completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? self?.repository.setGroup(id: item.id, group: group)
            DispatchQueue.main.async {
                guard let self else { return }
                if let index = self.items.firstIndex(where: { $0.id == item.id }) {
                    self.items[index].groupName = group
                }
                if case .group = self.scope { self.load(reset: true) }
                self.loadPinboards()
                self.showToast(group == nil ? "已移出收藏板" : "已移入 \(group ?? "")")
                completion?()
            }
        }
    }

    func extractText(_ item: ClipboardItem) {
        guard let path = item.imagePath else { return }
        statusText = "正在识别图片文字…"
        OCRService.shared.recognize(imagePath: path) { [weak self] text in
            guard let self else { return }
            guard !text.isEmpty else {
                self.showToast("未识别到文字")
                return
            }
            DispatchQueue.global(qos: .utility).async {
                try? self.repository.updateOCR(id: item.id, text: text)
                DispatchQueue.main.async {
                    if let index = self.items.firstIndex(where: { $0.id == item.id }) {
                        self.items[index].ocrText = text
                        if self.detailItem?.id == item.id { self.detailItem = self.items[index] }
                    }
                    self.showToast("图片文字已识别，可通过搜索查找")
                }
            }
        }
    }

    // MARK: - 收藏板

    func savePinboard(name: String, color: String, previous: String? = nil, completion: (() -> Void)? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var board = Pinboard(name: trimmed, color: color)
        board.position = pinboards.count
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? self?.repository.savePinboard(board, previousName: previous)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadPinboards()
                self.setScope(.group(trimmed))
                completion?()
            }
        }
    }

    func deletePinboard(_ name: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? self?.repository.deletePinboard(name: name)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.scope == .group(name) { self.setScope(.all) }
                self.loadPinboards()
                self.showToast("收藏板已删除，内容已回到历史")
            }
        }
    }

    // MARK: - 其他

    func updateAfterCopy(_ item: ClipboardItem) {
        statusText = "已复制到剪贴板"
    }

    func showToast(_ message: String) {
        toastText = message
        toastWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.2)) { self?.toastText = nil }
        }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}
