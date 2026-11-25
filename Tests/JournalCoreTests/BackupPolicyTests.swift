import Foundation
import Testing
@testable import JournalCore

struct BackupPolicyTests {
    private func fixture(_ body: (JournalStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-policy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try body(JournalStore(url: root.appendingPathComponent("journal.sqlite")), root)
    }
    @Test func verifiedWritePrunesOnlyOwnedValidBackups() throws {
        try fixture { store, root in
            try store.save(Entry(text: "备份素材", day: "2026-11-18"))
            let directory = root.appendingPathComponent("backups")
            let owner = UUID(); let start = Date(timeIntervalSince1970: 1_800_000_000)
            let data = try store.exportBackup()
            let first = try LocalBackupArchive.write(data: data, directory: directory, libraryID: owner, retentionCount: 2, now: start)
            let second = try LocalBackupArchive.write(data: data, directory: directory, libraryID: owner, retentionCount: 2, now: start.addingTimeInterval(1))
            let foreign = try LocalBackupArchive.write(data: data, directory: directory, libraryID: UUID(), retentionCount: 2, now: start)
            let manual = directory.appendingPathComponent("manual.json"); try data.write(to: manual)
            let corrupt = directory.appendingPathComponent("workjournal-auto-corrupt.json"); try Data("broken".utf8).write(to: corrupt)
            let last = try LocalBackupArchive.write(data: data, directory: directory, libraryID: owner, retentionCount: 2, now: start.addingTimeInterval(2))
            #expect(!FileManager.default.fileExists(atPath: first.file.url.path))
            for url in [second.file.url, last.file.url, foreign.file.url, manual, corrupt] { #expect(FileManager.default.fileExists(atPath: url.path)) }
            #expect(try LocalBackupArchive.list(directory: directory, libraryID: owner).map(\.preview.entries) == [1, 1])
            #expect(try JournalStore.backupPreview(Data(contentsOf: last.file.url)).entries == 1)
        }
    }
    @Test func failedWriteAndFailedRetentionKeepLastGoodBackup() throws {
        try fixture { store, root in
            let directory = root.appendingPathComponent("backups"); let owner = UUID()
            let first = try LocalBackupArchive.write(data: store.exportBackup(), directory: directory, libraryID: owner, retentionCount: 1)
            #expect(throws: (any Error).self) { try LocalBackupArchive.write(data: Data("invalid".utf8), directory: directory, libraryID: owner, retentionCount: 1) }
            #expect(FileManager.default.fileExists(atPath: first.file.url.path))
            let second = try LocalBackupArchive.write(data: store.exportBackup(), directory: directory, libraryID: owner, retentionCount: 1, now: Date().addingTimeInterval(1), remove: { _ in throw CocoaError(.fileWriteNoPermission) })
            #expect(second.warning != nil)
            #expect(FileManager.default.fileExists(atPath: first.file.url.path))
            #expect(try JournalStore.backupPreview(Data(contentsOf: second.file.url)).notes == 0)
        }
    }
    @Test func previewValidatesSkippedContentBeforeAnyRestore() throws {
        let invalid = Data("{\"formatVersion\":6,\"entries\":[{\"id\":\"bad\"}],\"reports\":[]}".utf8)
        #expect(throws: (any Error).self) { try JournalStore.backupPreview(invalid) }
    }
    @Test func dailyPolicyRequiresChangedDataAndDoesNotReplaceFailedState() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var state = AutomaticBackupState()
        #expect(BackupPolicy.shouldWrite(enabled: true, force: false, now: start, fingerprint: "a", state: state))
        state.lastSuccess = start; state.fingerprint = "a"
        #expect(!BackupPolicy.shouldWrite(enabled: true, force: false, now: start.addingTimeInterval(60), fingerprint: "b", state: state))
        #expect(!BackupPolicy.shouldWrite(enabled: true, force: false, now: start.addingTimeInterval(86400), fingerprint: "a", state: state))
        #expect(BackupPolicy.shouldWrite(enabled: true, force: false, now: start.addingTimeInterval(86400), fingerprint: "b", state: state))
        #expect(BackupPolicy.shouldWrite(enabled: false, force: true, now: start, fingerprint: "a", state: state))
    }
    @Test func backgroundWorkerPersistsDailyStateAndNoticesNextDayChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-worker-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.sqlite")
        let writer = try JournalStore(url: url)
        let worker = AutomaticBackupWorker(dataDirectory: root, databaseURL: url)
        let (settings, initial) = try await worker.load()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await worker.run(settings: settings, state: initial, now: start)
        #expect(first.lastSuccess == start)
        #expect(try await worker.files(settings: settings, state: first).count == 1)
        try writer.save(Entry(text: "later", day: "2026-11-18"))
        let sameDay = try await worker.run(settings: settings, state: first, now: start.addingTimeInterval(1))
        #expect(sameDay == first)
        let nextDay = try await worker.run(settings: settings, state: sameDay, now: start.addingTimeInterval(86400))
        #expect(nextDay.lastSuccess == start.addingTimeInterval(86400))
        let restarted = AutomaticBackupWorker(dataDirectory: root, databaseURL: url)
        let (_, reloaded) = try await restarted.load()
        #expect(reloaded == nextDay)
        #expect(try await restarted.files(settings: settings, state: reloaded).map(\.preview.entries) == [1, 0])
        let unchanged = try await restarted.run(settings: settings, state: reloaded, now: start.addingTimeInterval(172800))
        #expect(unchanged.lastSuccess == nextDay.lastSuccess)
    }
    @Test func choosingNewDirectoryCreatesBackupEvenAfterUnchangedCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-directory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.sqlite")
        _ = try JournalStore(url: url)
        let worker = AutomaticBackupWorker(dataDirectory: root, databaseURL: url)
        var (settings, state) = try await worker.load()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        state = try await worker.run(settings: settings, state: state, now: start)
        _ = try await worker.run(settings: settings, state: state, now: start.addingTimeInterval(86400))
        settings.directory = root.appendingPathComponent("new-folder")
        state.lastSuccess = nil; state.fingerprint = nil
        let moved = try await worker.run(settings: settings, state: state, now: start.addingTimeInterval(86401))
        #expect(moved.lastSuccess != nil)
        #expect(try await worker.files(settings: settings, state: moved).count == 1)
    }

}
