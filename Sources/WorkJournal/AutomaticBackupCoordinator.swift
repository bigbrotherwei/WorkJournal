import Foundation
import AppKit
import Combine
import JournalCore

@MainActor
final class AutomaticBackupCoordinator: ObservableObject {
    @Published private(set) var settings: AutomaticBackupSettings
    @Published private(set) var state = AutomaticBackupState()
    @Published private(set) var files: [LocalBackupFile] = []
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    @Published var error: String?
    @Published var previewFile: LocalBackupFile?
    private let worker: AutomaticBackupWorker
    private let restoreCallback: (URL) -> Void
    private let captureExtras: (AutomaticBackupSettings) throws -> BackupExtras
    private var timerTask: Task<Void, Never>?
    private var hasLoadedFiles = false

    init(dataDirectory: URL, databaseURL: URL, restore: @escaping (URL) -> Void,
         captureExtras: @escaping (AutomaticBackupSettings) throws -> BackupExtras = { try BackupPreferencesStore().capture(automaticBackup: $0) }) {
        settings = AutomaticBackupSettings(directory: dataDirectory.appendingPathComponent("Backups/Automatic"))
        worker = AutomaticBackupWorker(dataDirectory: dataDirectory, databaseURL: databaseURL)
        restoreCallback = restore
        self.captureExtras = captureExtras
    }
    deinit { timerTask?.cancel() }
    func start() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            guard let worker = self?.worker else { return }
            do {
                let (settings, state) = try await worker.load()
                try await worker.save(settings: settings, state: state)
                self?.settings = settings; self?.state = state; self?.ready = true
                self?.checkIfNeeded()
            } catch { self?.error = "自动备份设置无法读取：\(error.localizedDescription)" }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 300_000_000_000) } catch { return }
                self?.checkIfNeeded()
            }
        }
    }
    func checkIfNeeded() { run(force: false) }
    func backupNow() { run(force: true) }
    private func run(force: Bool) {
        guard ready, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let previous = state
                let extras = try captureExtras(settings)
                state = try await worker.run(settings: settings, state: state, force: force, extras: extras)
                if state != previous || !hasLoadedFiles || force {
                    files = try await worker.files(settings: settings, state: state)
                    hasLoadedFiles = true
                }
                error = nil
            } catch {
                self.error = "备份失败：\(error.localizedDescription)"
                state.lastResult = self.error
                try? await worker.save(settings: settings, state: state)
            }
        }
    }
    func refresh() {
        guard ready, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { files = try await worker.files(settings: settings, state: state); hasLoadedFiles = true; error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
    func update(enabled: Bool? = nil, retentionCount: Int? = nil, directory: URL? = nil) {
        guard ready, !busy else { return }
        var next = settings
        if let enabled { next.enabled = enabled }
        if let retentionCount { next.retentionCount = min(365, max(1, retentionCount)) }
        if let directory { next.directory = directory }
        var nextState = state
        if next.directory != settings.directory { nextState.lastSuccess = nil; nextState.fingerprint = nil; nextState.lastResult = "备份目录已更改" }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await worker.save(settings: next, state: nextState)
                settings = next; state = nextState
                files = try await worker.files(settings: settings, state: state); hasLoadedFiles = true; error = nil
            } catch { self.error = "设置未保存：\(error.localizedDescription)" }
        }
    }
    func chooseDirectory() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "选择本地自动备份目录。建议使用单独文件夹。"; panel.directoryURL = settings.directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        update(directory: url)
    }
    /// Restore only portable scheduling choices; keep this Mac's directory and library identity.
    func restoreSchedule(_ value: BackupSchedulePreferences) async throws {
        guard ready, !busy else { throw JournalError.invalid("自动备份仍在处理中，请稍后重新恢复设置。") }
        var next = settings
        next.enabled = value.enabled
        next.retentionCount = value.retentionCount
        busy = true
        defer { busy = false }
        try await worker.save(settings: next, state: state)
        settings = next
        error = nil
    }
    func preview(_ file: LocalBackupFile) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { var value = file; value.preview = try await worker.preview(url: file.url); previewFile = value; error = nil }
            catch { self.error = "备份无法预览：\(error.localizedDescription)" }
        }
    }
    func restorePreviewedBackup() {
        guard let file = previewFile else { return }
        previewFile = nil
        restoreCallback(file.url)
    }
}
