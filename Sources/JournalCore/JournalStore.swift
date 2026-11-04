import Foundation
import CSQLite

/// Confined to its caller's serial executor (the app uses the main actor).
public final class JournalStore {
    public private(set) var migrationBackupURL: URL?
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            let error = failure(); sqlite3_close(db); db = nil; throw error
        }
        do {
            sqlite3_busy_timeout(db, 3000)
            try migrateIfNeeded(url: url)
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    private func scalar(_ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int(statement, 0))
    }
    private func checkTables(includeSummaries: Bool = false) throws {
        guard try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('entries','reports')") == 2 else {
            throw JournalError.invalid("数据库结构不完整，已停止打开；请从备份恢复。")
        }
        // Preparing statements checks required columns without mutating the database.
        for table in (["entries", "reports"] + (includeSummaries ? ["range_summaries"] : [])) {
            var statement: OpaquePointer?
            let result = sqlite3_prepare_v2(db, "SELECT id,payload FROM \(table) LIMIT 0", -1, &statement, nil)
            sqlite3_finalize(statement)
            guard result == SQLITE_OK else { throw failure() }
        }
    }
    private func migrateIfNeeded(url: URL) throws {
        let version = try scalar("PRAGMA user_version")
        guard version <= 3 else { throw JournalError.invalid("数据库由更新版本应用创建，请使用更新的工作随记打开；未修改数据。") }
        if version == 3 { try checkTables(includeSummaries: true); return }
        let tables = try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
        if tables > 0 {
            guard tables == 2 || tables == 3 else { throw JournalError.invalid("无法识别旧数据库结构，已停止升级。") }
            if tables == 3 { guard try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='range_summaries'") == 1 else { throw JournalError.invalid("无法识别旧数据库结构。") } }
            try checkTables()
            // Verify legacy payloads before upgrading their container format.
            _ = try read("entries", as: Entry.self); _ = try read("reports", as: Report.self)
            let directory = url.deletingLastPathComponent().appendingPathComponent("Backups")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let backupURL = directory.appendingPathComponent("before-schema-v\(version)-\(UUID()).sqlite")
            try snapshot(to: backupURL)
            migrationBackupURL = backupURL
        }
        try transaction {
            let current = try scalar("PRAGMA user_version")
            guard current <= 3 else { throw JournalError.invalid("数据库版本已变化，停止升级，请重新打开应用。") }
            if current == 3 { try checkTables(includeSummaries: true); return }
            try execute("CREATE TABLE IF NOT EXISTS entries (id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS reports (id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS range_summaries (id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
            try checkTables(includeSummaries: true)
            try execute("PRAGMA user_version=3")
        }
    }
    private func snapshot(to url: URL) throws {
        var destination: OpaquePointer?
        guard sqlite3_open(url.path, &destination) == SQLITE_OK else {
            sqlite3_close(destination)
            throw JournalError.invalid("无法创建升级前备份，已停止升级。")
        }
        var complete = false
        defer { sqlite3_close(destination); if !complete { try? FileManager.default.removeItem(at: url) } }
        guard let backup = sqlite3_backup_init(destination, "main", db, "main") else {
            throw JournalError.invalid("无法读取升级前快照，已停止升级。")
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE && finish == SQLITE_OK else {
            throw JournalError.invalid("升级前备份未完成，可能数据库正在使用；已停止升级，请稍后重试。")
        }
        complete = true
    }
    deinit { sqlite3_close(db) }
    private func failure() -> JournalError {
        .invalid("本地数据库错误：\(db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开")")
    }
    private func execute(_ sql: String, values: [String] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in values.enumerated() {
            let result = value.withCString { sqlite3_bind_text(stmt, Int32(i + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard result == SQLITE_OK else { throw failure() }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    private func read<T: Decodable>(_ table: String, as: T.Type) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM \(table)", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        var result: [T] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { throw failure() }
            result.append(try decoder.decode(T.self, from: Data(String(cString: text).utf8)))
        }
        return result
    }
    private func payload<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    public func save(_ entry: Entry) throws {
        guard entry.hasContent else { throw JournalError.invalid("请输入文字或添加图片") }
        try RecordContent.validate(text: entry.text, images: entry.images)
        try validateDay(entry.day)
        try execute("INSERT INTO entries(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", values: [entry.id.uuidString, try payload(entry)])
    }
    public struct ImportResult {
        public var entries: Int
        public var reports: Int
        public var skipped: Int
        public var summaries: Int = 0
    }
    private struct Backup: Codable {
        var formatVersion: Int
        var entries: [Entry]
        var reports: [Report]
        var summaries: [RangeSummary]?
    }
    public func importBackup(_ data: Data) throws -> ImportResult {
        let backup = try decoder.decode(Backup.self, from: data)
        guard [1, 2, 3].contains(backup.formatVersion) else { throw JournalError.invalid("备份版本不受支持，未修改本机数据。") }
        guard Set(backup.entries.map(\.id)).count == backup.entries.count,
              Set(backup.reports.map(\.id)).count == backup.reports.count,
              Set((backup.summaries ?? []).map(\.id)).count == (backup.summaries ?? []).count else {
            throw JournalError.invalid("备份中存在重复 ID，未导入。")
        }
        // Validate even skipped rows, so corrupted files cannot look like successful imports.
        for entry in backup.entries {
            try validateDay(entry.day)
            try RecordContent.validate(text: entry.text, images: entry.images)
            guard entry.hasContent,
                  !entry.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw JournalError.invalid("备份包含空白记录或分类。")
            }
        }
        for report in backup.reports {
            try validateDay(report.day)
            guard !report.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw JournalError.invalid("备份包含空白日报。") }
        }
        for summary in backup.summaries ?? [] { try validateSummary(summary) }
        return try transaction {
            let entryIDs = Set(try read("entries", as: Entry.self).map(\.id))
            let reportIDs = Set(try read("reports", as: Report.self).map(\.id))
            var result = ImportResult(entries: 0, reports: 0, skipped: 0)
            for entry in backup.entries {
                if entryIDs.contains(entry.id) { result.skipped += 1 }
                else { try save(entry); result.entries += 1 }
            }
            for report in backup.reports {
                if reportIDs.contains(report.id) { result.skipped += 1 }
                else { try saveReport(report); result.reports += 1 }
            }
            let summaryIDs = Set(try read("range_summaries", as: RangeSummary.self).map(\.id))
            for summary in backup.summaries ?? [] {
                if summaryIDs.contains(summary.id) { result.skipped += 1 }
                else { try saveSummary(summary); result.summaries += 1 }
            }
            return result
        }
    }
    public func renameCategory(from source: String, to proposed: String) throws -> Int {
        let target = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target.count <= 40, !target.contains("\n"), target != "未分类", target != "全部" else {
            throw JournalError.invalid("分类名称须为 1～40 字，不能使用“未分类”或“全部”。")
        }
        guard source != "未分类", source != target else { return 0 }
        return try transaction {
            let affected = try entries().filter { $0.category == source }
            for var entry in affected {
                entry.category = target; entry.manualCategory = true; entry.updatedAt = Date()
                try save(entry)
            }
            return affected.count
        }
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func exportBackup() throws -> Data {
        let value = Backup(formatVersion: 3, entries: try read("entries", as: Entry.self), reports: try read("reports", as: Report.self), summaries: try read("range_summaries", as: RangeSummary.self))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
    public func entries() throws -> [Entry] {
        try read("entries", as: Entry.self).filter { $0.deletedAt == nil }.sorted { $0.createdAt > $1.createdAt }
    }
    public func trashedEntries() throws -> [Entry] {
        try read("entries", as: Entry.self).filter { $0.deletedAt != nil }.sorted { $0.deletedAt! > $1.deletedAt! }
    }
    public func delete(id: UUID) throws {
        try transaction {
            guard var entry = try entries().first(where: { $0.id == id }) else { return }
            entry.deletedAt = Date(); entry.updatedAt = Date(); try save(entry)
        }
    }
    public func restore(id: UUID) throws {
        try transaction {
            guard var entry = try trashedEntries().first(where: { $0.id == id }) else { return }
            entry.deletedAt = nil; entry.updatedAt = Date(); try save(entry)
        }
    }
    public func permanentlyDelete(id: UUID) throws {
        try transaction {
            guard try trashedEntries().contains(where: { $0.id == id }) else { throw JournalError.invalid("只能永久删除回收站中的记录。") }
            try execute("DELETE FROM entries WHERE id=?", values: [id.uuidString])
        }
    }
    private func validateSummary(_ summary: RangeSummary) throws {
        try validateDay(summary.startDay); try validateDay(summary.endDay)
        guard summary.startDay <= summary.endDay, !summary.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JournalError.invalid("总结日期范围或内容无效。")
        }
    }
    public func saveSummary(_ summary: RangeSummary) throws {
        try validateSummary(summary)
        try execute("INSERT INTO range_summaries(id,payload) VALUES(?,?)", values: [summary.id.uuidString, try payload(summary)])
    }
    public func summaries(startDay: String, endDay: String) throws -> [RangeSummary] {
        try read("range_summaries", as: RangeSummary.self).filter { $0.startDay == startDay && $0.endDay == endDay }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString > $1.id.uuidString : $0.createdAt > $1.createdAt }
    }
    public func reportEntries(day: String) throws -> [Entry] { try entries().filter { $0.day == day && $0.inReport }.sorted { $0.createdAt < $1.createdAt } }
    private func validateDay(_ day: String) throws {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: day), formatter.string(from: date) == day else { throw JournalError.invalid("日期格式应为 yyyy-MM-dd，例如 2026-10-30") }
    }
    public func saveReport(_ report: Report) throws {
        try validateDay(report.day)
        guard !report.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw JournalError.invalid("日报内容为空") }
        try execute("INSERT INTO reports(id,payload) VALUES(?,?)", values: [report.id.uuidString, try payload(report)])
    }
    public func reportArchive() throws -> [ReportArchiveDay] {
        ReportArchiveDay.build(entries: try entries(), reports: try read("reports", as: Report.self))
    }
    public func reports(day: String) throws -> [Report] {
        try read("reports", as: Report.self).filter { $0.day == day }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString > $1.id.uuidString : $0.createdAt > $1.createdAt }
    }
}
