import Foundation
import SwiftUI
import JournalCore

@MainActor final class LocalOCRCoordinator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progress = OCRBatchProgress()
    @Published private(set) var status = "尚未识别图片文字"
    @Published private(set) var errors: [String] = []
    @Published private(set) var revision = 0
    @Published private(set) var isCancelling = false
    private let worker: LocalOCRWorker
    private let reader: LocalOCRWorker
    private var operation: Task<Void, Never>?
    private var generation = UUID()

    init(databaseURL: URL, cacheURL: URL) {
        worker = LocalOCRWorker(databaseURL: databaseURL, cacheURL: cacheURL)
        reader = LocalOCRWorker(databaseURL: databaseURL, cacheURL: cacheURL)
    }
    func validatedTexts() async throws -> [OCRSearchText] { try await reader.validatedTexts() }
    func start() {
        guard !isRunning else { return }
        let token = UUID(); generation = token
        isRunning = true; isCancelling = false; errors = []; progress = OCRBatchProgress(); status = "正在检查本地图片…"
        operation = Task { [self] in
            do {
                let result = try await worker.run { [self] progress in
                    Task { @MainActor in
                        guard self.generation == token, self.isRunning, !self.isCancelling else { return }
                        self.progress = progress
                        self.status = "识别图片 \(progress.completed)/\(progress.total)"
                    }
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                errors = result.errors
                status = "完成：新识别 \(result.recognized) 张，复用 \(result.reused) 张" + (errors.isEmpty ? "" : "，失败 \(errors.count) 张")
            } catch is CancellationError { status = "已取消，已保存的有效识别结果仍可搜索" }
            catch { errors = [error.localizedDescription]; status = "图片文字识别未完成" }
            guard generation == token else { return }
            isRunning = false; isCancelling = false; operation = nil; revision += 1
        }
    }
    func cancel() {
        guard isRunning else { return }
        isCancelling = true; status = "正在取消…"; operation?.cancel()
    }
}
