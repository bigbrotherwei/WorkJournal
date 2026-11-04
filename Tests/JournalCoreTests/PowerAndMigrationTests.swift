import Foundation
import Testing
import CSQLite
@testable import JournalCore

struct PowerAndMigrationTests {
    @Test func automaticPowerPolicyAndManualOverride() {
        #expect(PowerPolicy.pausesBackground(mode: .automatic, state: PowerSnapshot(source: .battery)))
        #expect(PowerPolicy.pausesBackground(mode: .automatic, state: PowerSnapshot()))
        #expect(!PowerPolicy.pausesBackground(mode: .automatic, state: PowerSnapshot(source: .external)))
        #expect(PowerPolicy.pausesBackground(mode: .automatic, state: PowerSnapshot(source: .external, lowPower: true)))
        #expect(PowerPolicy.pausesBackground(mode: .automatic, state: PowerSnapshot(source: .external, hot: true)))
        #expect(PowerPolicy.pausesBackground(mode: .saving, state: PowerSnapshot(source: .external)))
        #expect(!PowerPolicy.pausesBackground(mode: .unrestricted, state: PowerSnapshot(source: .battery, lowPower: true, hot: true)))
    }
    @Test func preservesLegacyUserChoice() {
        #expect(PowerPolicy.mode(saved: nil, legacySaving: true) == .saving)
        #expect(PowerPolicy.mode(saved: nil, legacySaving: false) == .unrestricted)
        #expect(PowerPolicy.mode(saved: nil, legacySaving: nil) == .automatic)
        #expect(PowerPolicy.mode(saved: PowerMode.automatic.rawValue, legacySaving: true) == .automatic)
    }
    private func withDB<T>(_ url: URL, _ body: (OpaquePointer?) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw JournalError.invalid("fixture open") }
        defer { sqlite3_close(db) }
        return try body(db)
    }
    private func sql(_ url: URL, _ sql: String) throws {
        try withDB(url) { db in guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw JournalError.invalid("fixture SQL") } }
    }
    private func scalar(_ url: URL, _ sql: String) throws -> Int {
        try withDB(url) { db in
            var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { throw JournalError.invalid("fixture query") }
            return Int(sqlite3_column_int(statement, 0))
        }
    }
    private func legacyDB(_ url: URL) throws -> Entry {
        let entry = Entry(text: "升级前的原始记录", day: "2026-10-30")
        do { let store = try JournalStore(url: url); try store.save(entry); try store.saveReport(Report(day: entry.day, text: "手工日报")) }
        try sql(url, "PRAGMA user_version=0")
        return entry
    }
    @Test func migrationBacksUpLegacyDatabaseAndPreservesRows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.sqlite")
        let entry = try legacyDB(url)
        let store = try JournalStore(url: url)
        #expect(try scalar(url, "PRAGMA user_version") == 4)
        #expect(try store.entries() == [entry])
        #expect(try store.reports(day: entry.day).first?.text == "手工日报")
        let backup = try #require(store.migrationBackupURL)
        #expect(try scalar(backup, "PRAGMA user_version") == 0)
        #expect(try scalar(backup, "SELECT count(*) FROM entries") == 1)
        #expect(try JournalStore(url: url).migrationBackupURL == nil)
    }
    @Test func versionTwoUpgradePreservesImagesAndCreatesSummaryTable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("v2-migration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.sqlite")
        var entry = Entry(text: "图片迁移", day: "2026-11-04"); entry.images = [ImageAttachmentTests().picture()]
        do { let store = try JournalStore(url: url); try store.save(entry) }
        try sql(url, "DROP TABLE range_summaries; PRAGMA user_version=2")
        let store = try JournalStore(url: url)
        #expect(try store.entries() == [entry])
        #expect(try scalar(url, "PRAGMA user_version") == 4)
        #expect(try scalar(url, "SELECT count(*) FROM sqlite_master WHERE name='range_summaries'") == 1)
        let backup = try #require(store.migrationBackupURL)
        #expect(try scalar(backup, "PRAGMA user_version") == 2)
    }
    @Test func futureSchemaRejectedWithoutMutation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("future-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try sql(url, "PRAGMA user_version=99; CREATE TABLE future_data(value TEXT)")
        #expect(throws: (any Error).self) { try JournalStore(url: url) }
        #expect(try scalar(url, "PRAGMA user_version") == 99)
        #expect(try scalar(url, "SELECT count(*) FROM sqlite_master WHERE name='entries'") == 0)
    }
    @Test func backupFailureLeavesLegacySchemaUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-fail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.sqlite")
        _ = try legacyDB(url)
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("Backups"))
        #expect(throws: (any Error).self) { try JournalStore(url: url) }
        #expect(try scalar(url, "PRAGMA user_version") == 0)
        #expect(try scalar(url, "SELECT count(*) FROM entries") == 1)
    }
    @Test func legacySnapshotIncludesUncheckpointedWALRows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-wal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.sqlite")
        _ = try legacyDB(url)
        try withDB(url) { db in
            #expect(sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0", nil, nil, nil) == SQLITE_OK)
            let entry = Entry(text: "WAL 中尚未 checkpoint 的记录", day: "2026-10-30")
            let payload = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
            let insert = "INSERT INTO entries(id,payload) VALUES('\(entry.id.uuidString)','\(payload)')"
            #expect(sqlite3_exec(db, insert, nil, nil, nil) == SQLITE_OK)
            #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))
            let store = try JournalStore(url: url)
            let backup = try #require(store.migrationBackupURL)
            #expect(try scalar(backup, "SELECT count(*) FROM entries") == 2)
            #expect(try store.entries().contains(entry))
        }
    }
    @Test func incompleteLegacySchemaIsNotSilentlyRepaired() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("incomplete-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try sql(url, "CREATE TABLE entries(id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
        #expect(throws: (any Error).self) { try JournalStore(url: url) }
        #expect(try scalar(url, "SELECT count(*) FROM sqlite_master WHERE name='reports'") == 0)
        #expect(try scalar(url, "PRAGMA user_version") == 0)
    }
}
