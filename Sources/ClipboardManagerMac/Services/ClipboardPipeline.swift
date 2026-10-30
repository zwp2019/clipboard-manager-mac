import AppKit
import Foundation

/// 剪贴板监听：macOS 没有剪贴板变更事件，只能基于 changeCount 低频轮询（0.35s）。
final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    var onChange: (() -> Void)?

    func start(interval: TimeInterval = 0.35) {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let current = NSPasteboard.general.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        onChange?()
    }
}

/// 剪贴板处理管道：Monitor → Reader → Normalizer → Hash → Dedup → Storage → UI。
final class ClipboardPipeline {
    private let repository: ClipboardRepository
    private let imageStore: ImageStore
    private let ocrService: OCRService
    private let reader = ClipboardReader()
    private let internalGuard = InternalClipboardGuard()
    private let settingsProvider: () -> AppSettings
    private let workQueue = DispatchQueue(label: "ClipboardManager.Pipeline", qos: .utility)
    private let monitor = ClipboardMonitor()

    private var lastHash: String?
    private var lastHashAt: Date = .distantPast
    private var cleanupTimer: Timer?
    private var insertionsSinceTrim = 0

    /// 主线程回调：历史发生变化。
    var onChanged: (() -> Void)?
    /// 主线程回调：成功捕获新条目。
    var onCaptured: ((ClipboardItem) -> Void)?

    init(repository: ClipboardRepository,
         imageStore: ImageStore,
         ocrService: OCRService,
         settings: @escaping () -> AppSettings) {
        self.repository = repository
        self.imageStore = imageStore
        self.ocrService = ocrService
        self.settingsProvider = settings
    }

    func start() {
        monitor.onChange = { [weak self] in
            self?.handlePasteboardChange()
        }
        monitor.start()
        scheduleCleanup()
    }

    func stop() {
        monitor.stop()
        cleanupTimer?.invalidate()
        cleanupTimer = nil
    }

    /// 外部写入剪贴板时调用，避免自身复制产生新的历史。
    func markInternalWrite() {
        internalGuard.begin()
    }

    private func handlePasteboardChange() {
        let result = reader.read()
        guard let data = result.data else { return }
        if data.internalWriteMarker != nil { return }
        if internalGuard.isGuarding() { return }
        guard data.size > 0 else { return }

        workQueue.async { [weak self] in
            self?.process(data)
        }
    }

    private func process(_ data: ClipboardData) {
        let settings = settingsProvider()
        guard !settings.isPaused else { return }

        let sourceName = data.sourceApplication ?? ""
        let sourceBundle = data.sourceBundleID ?? ""
        let excluded = settings.excludedApplications.contains { entry in
            let value = entry.lowercased()
            return value == sourceName.lowercased() || value == sourceBundle.lowercased()
        }
        guard !excluded else { return }

        let hash = HashService.hash(data: data)
        let now = Date()
        if settings.enableDeduplication, hash == lastHash, now.timeIntervalSince(lastHashAt) < 2.5 {
            return
        }
        lastHash = hash
        lastHashAt = now

        // 已存在相同内容：移动到最前，不重复入库。
        if settings.enableDeduplication, let existing = (try? repository.findByHash(hash)) ?? nil {
            try? repository.touch(id: existing.id)
            notifyChanged()
            return
        }

        var item = ClipboardItem()
        item.type = data.type
        item.text = data.text
        item.html = data.html
        item.rtf = data.rtf
        item.hash = hash
        item.size = data.size
        item.sourceApplication = data.sourceApplication
        item.sourceTitle = data.sourceTitle
        item.sourceBundleID = data.sourceBundleID
        item.createdAt = now
        item.updatedAt = now
        if let files = data.filePaths, !files.isEmpty,
           let json = try? JSONEncoder().encode(files),
           let string = String(data: json, encoding: .utf8) {
            item.filePaths = string
        }

        if data.type == .image, let imageData = data.imageData {
            if let saved = try? imageStore.save(pngData: imageData,
                                                hash: hash,
                                                generateThumbnail: settings.imageCompression) {
                item.imagePath = saved.imagePath
                item.thumbnailPath = saved.thumbnailPath
                item.sourceTitle = saved.pixelSize
            }
        }

        do {
            let id = try repository.insert(item)
            item.id = id
        } catch {
            AppLog.error("insert failed: \(error.localizedDescription)")
            return
        }

        insertionsSinceTrim += 1
        if insertionsSinceTrim >= 20 {
            insertionsSinceTrim = 0
            try? repository.trim(to: settings.maxHistoryItems)
        }

        AppLog.info("captured type=\(item.type.rawValue) hash=\(hash.prefix(12)) size=\(item.size) source=\(sourceBundle)")

        if item.type == .image, let imagePath = item.imagePath {
            let id = item.id
            ocrService.recognize(imagePath: imagePath) { [weak self] text in
                guard let self, !text.isEmpty else { return }
                self.workQueue.async {
                    try? self.repository.updateOCR(id: id, text: text)
                    self.notifyChanged()
                }
            }
        }

        notifyChanged()
        if let item = try? repository.get(id: item.id) {
            DispatchQueue.main.async { [weak self] in
                self?.onCaptured?(item)
            }
        }
    }

    private func notifyChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.onChanged?()
        }
    }

    // MARK: - 清理

    private func scheduleCleanup() {
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            self?.runCleanup()
        }
        RunLoop.main.add(timer, forMode: .common)
        cleanupTimer = timer

        // 启动后延迟执行，避免影响冷启动（规范 §33）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.runCleanup()
        }
    }

    func runCleanup() {
        let settings = settingsProvider()
        workQueue.async { [weak self] in
            guard let self else { return }
            if settings.retentionDays > 0,
               let cutoff = Calendar.current.date(byAdding: .day, value: -settings.retentionDays, to: Date()) {
                try? self.repository.removeOlderThan(cutoff)
            }
            try? self.repository.trim(to: settings.maxHistoryItems)
        }
    }
}
