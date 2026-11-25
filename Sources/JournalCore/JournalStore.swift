import Foundation
import CSQLite

/// Confined to its caller's serial executor (the app uses the main actor).
public final class JournalStore {
    public private(set) var migrationBackupURL: URL?
    var notebookSaveValidationStamp: NotebookSaveValidationStamp?
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
        guard version <= 6 else { throw JournalError.invalid("数据库由更新版本应用创建，请使用更新的工作随记打开；未修改数据。") }
        if version == 6 { try checkTables(includeSummaries: true); try checkNotebookTables(); try checkHistoryTable(); return }
        let tables = try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
        if tables > 0 {
            guard tables == 2 || tables == 3 || version == 5 && tables == 6 else { throw JournalError.invalid("无法识别旧数据库结构，已停止升级。") }
            if tables == 3 { guard try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='range_summaries'") == 1 else { throw JournalError.invalid("无法识别旧数据库结构。") } }
            try checkTables()
            // Verify legacy payloads before upgrading their container format.
            _ = try read("entries", as: Entry.self); _ = try read("reports", as: Report.self)
            if version >= 4 { _ = try read("range_summaries", as: RangeSummary.self) }
            if version == 5 {
                try checkNotebookTables()
                try NotebookValidation.validateStoredSnapshot(NotebookSnapshot(folders: try noteFolders(includeDeleted: true), notes: try notes(includeDeleted: true), assets: try read("note_assets", as: NoteAsset.self)))
            }
            let directory = url.deletingLastPathComponent().appendingPathComponent("Backups")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let backupURL = directory.appendingPathComponent("before-schema-v\(version)-\(UUID()).sqlite")
            try snapshot(to: backupURL)
            migrationBackupURL = backupURL
        }
        try transaction {
            let current = try scalar("PRAGMA user_version")
            guard current <= 6 else { throw JournalError.invalid("数据库版本已变化，停止升级，请重新打开应用。") }
            if current == 6 { try checkTables(includeSummaries: true); try checkNotebookTables(); try checkHistoryTable(); return }
            try execute("CREATE TABLE IF NOT EXISTS entries (id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS reports (id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS range_summaries (id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
            try checkTables(includeSummaries: true)
            try execute("CREATE TABLE IF NOT EXISTS note_folders (id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS notes (id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS note_assets (id TEXT PRIMARY KEY, owner_note_id TEXT NOT NULL, payload TEXT NOT NULL, data BLOB NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS note_assets_owner ON note_assets(owner_note_id)")
            try checkNotebookTables()
            try execute("CREATE TABLE IF NOT EXISTS note_history (id TEXT PRIMARY KEY, note_id TEXT NOT NULL, saved_at REAL NOT NULL, payload TEXT NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS note_history_owner ON note_history(note_id,saved_at)")
            try checkHistoryTable()
            try execute("PRAGMA user_version=6")
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
        var check: OpaquePointer?
        defer { sqlite3_finalize(check) }
        guard sqlite3_prepare_v2(destination, "PRAGMA integrity_check", -1, &check, nil) == SQLITE_OK,
              sqlite3_step(check) == SQLITE_ROW, let value = sqlite3_column_text(check, 0), String(cString: value) == "ok" else {
            throw JournalError.invalid("升级前备份校验失败，已停止升级。")
        }
        complete = true
    }
    func withStatement<T>(_ sql: String, _ body: (OpaquePointer?) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }
    private func checkNotebookTables() throws {
        for table in ["note_folders", "notes"] {
            try withStatement("SELECT id,payload FROM \(table) LIMIT 0") { _ in }
        }
        try withStatement("SELECT id,owner_note_id,payload,data FROM note_assets LIMIT 0") { _ in }
    }
    private func checkHistoryTable() throws {
        try withStatement("SELECT id,note_id,saved_at,payload FROM note_history LIMIT 0") { _ in }
    }
    deinit { sqlite3_close(db) }
    func failure() -> JournalError {
        .invalid("本地数据库错误：\(db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开")")
    }
    func execute(_ sql: String, values: [String] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in values.enumerated() {
            let result = value.withCString { sqlite3_bind_text(stmt, Int32(i + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard result == SQLITE_OK else { throw failure() }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    func read<T: Decodable>(_ table: String, as: T.Type, cancelled: () -> Bool = { false }) throws -> [T] {
        try checkNotebookCancellation(cancelled)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM \(table)", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        var result: [T] = []
        while true {
            try checkNotebookCancellation(cancelled)
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { throw failure() }
            result.append(try decoder.decode(T.self, from: Data(String(cString: text).utf8)))
        }
        return result
    }
    func payload<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    public func save(_ proposed: Entry, now: Date = Date(), calendar: Calendar = .current) throws {
        try transaction {
            let current = try read("entries", as: Entry.self).first { $0.id == proposed.id }
            var entry = proposed
            if let current {
                entry.nextOccurrenceID = current.nextOccurrenceID
                entry.recurrenceSeriesID = current.recurrenceSeriesID
                if current.nextOccurrenceID != nil && entry.status != .done {
                    throw JournalError.invalid("这期事项已生成下一期待办，请在待办列表修改下一期。")
                }
                if current.dueAt != entry.dueAt { entry.snoozedUntil = nil }
                if current.dueAt != entry.dueAt || current.recurrence != entry.recurrence {
                    entry.recurrenceDayOfMonth = nil; entry.recurrenceClock = nil
                }
            }
            if entry.recurrence != .none && entry.recurrenceSeriesID == nil { entry.recurrenceSeriesID = entry.id }
            if entry.status != .pending || !entry.reminderEnabled || entry.dueAt == nil { entry.snoozedUntil = nil }
            if entry.recurrence != .none, entry.recurrenceClock == nil, let due = entry.dueAt {
                entry.recurrenceClock = RecurrenceClock(date: due, calendar: calendar)
            } else if entry.recurrence == .none { entry.recurrenceClock = nil }
            if entry.recurrence == .monthly, entry.recurrenceDayOfMonth == nil, let due = entry.dueAt {
                entry.recurrenceDayOfMonth = calendar.component(.day, from: due)
            } else if entry.recurrence != .monthly { entry.recurrenceDayOfMonth = nil }
            if let current, current.deletedAt == nil, entry.deletedAt == nil,
               current.status == .pending, entry.status == .done,
               entry.recurrence != .none, entry.nextOccurrenceID == nil {
                let nextDue = try RecurringTasks.nextDeadline(for: entry, after: now, calendar: calendar)
                var next = Entry(text: entry.text, day: Days.key(nextDue))
                next.createdAt = now; next.updatedAt = now
                next.status = .pending; next.dueAt = nextDue
                next.reminderEnabled = entry.reminderEnabled
                next.recurrence = entry.recurrence; next.recurrenceDayOfMonth = entry.recurrenceDayOfMonth; next.recurrenceClock = entry.recurrenceClock
                next.recurrenceSeriesID = entry.recurrenceSeriesID
                next.category = entry.category; next.manualCategory = entry.manualCategory; next.images = entry.images
                next.sourceNoteID = entry.sourceNoteID; next.sourceNoteTitle = entry.sourceNoteTitle
                entry.nextOccurrenceID = next.id
                try persist(next)
            }
            try persist(entry)
        }
    }
    public func snooze(id: UUID, until date: Date, now: Date = Date()) throws {
        try transaction {
            guard var entry = try entries().first(where: { $0.id == id }), entry.status == .pending, entry.dueAt != nil else {
                throw JournalError.invalid("只有设置截止时间的待处理事项可以稍后提醒。")
            }
            guard date > now, date.timeIntervalSinceReferenceDate.isFinite else {
                throw JournalError.invalid("请选择未来的提醒时间。")
            }
            entry.snoozedUntil = date; entry.reminderEnabled = true; entry.updatedAt = now
            try persist(entry)
        }
    }
    private func persist(_ entry: Entry) throws {
        guard entry.hasContent else { throw JournalError.invalid("请输入文字或添加图片") }
        try RecordContent.validate(text: entry.text, images: entry.images)
        try RecurringTasks.validate(entry)
        try Self.validateDay(entry.day)
        try execute("INSERT INTO entries(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", values: [entry.id.uuidString, try payload(entry)])
    }
    public struct ImportResult {
        public var entries: Int
        public var reports: Int
        public var skipped: Int
        public var summaries: Int = 0
        public var notebook: NotebookImportResult = NotebookImportResult()
    }
    private struct Backup: Codable {
        var formatVersion: Int
        var entries: [Entry]
        var reports: [Report]
        var summaries: [RangeSummary]?
        var notebook: NotebookSnapshot?
        var extras: BackupExtras?
    }
    private static func validatedBackup(_ data: Data) throws -> Backup {
        let backup = try JSONDecoder().decode(Backup.self, from: data)
        guard (1...7).contains(backup.formatVersion) else { throw JournalError.invalid("备份版本不受支持，未修改本机数据。") }
        guard backup.formatVersion == 7 || backup.extras == nil else {
            throw JournalError.invalid("旧版备份不能包含应用设置或模板，未修改本机数据。")
        }
        try backup.extras?.validate()
        guard Set(backup.entries.map(\.id)).count == backup.entries.count,
              Set(backup.reports.map(\.id)).count == backup.reports.count,
              Set((backup.summaries ?? []).map(\.id)).count == (backup.summaries ?? []).count else {
            throw JournalError.invalid("备份中存在重复 ID，未导入。")
        }
        // Validate even skipped rows, so corrupted files cannot look like successful imports.
        for entry in backup.entries {
            try Self.validateDay(entry.day)
            try RecordContent.validate(text: entry.text, images: entry.images)
            try RecurringTasks.validate(entry)
            guard entry.hasContent,
                  !entry.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw JournalError.invalid("备份包含空白记录或分类。")
            }
        }
        for report in backup.reports {
            try Self.validateDay(report.day)
            guard !report.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw JournalError.invalid("备份包含空白日报。") }
        }
        for summary in backup.summaries ?? [] { try Self.validateSummary(summary) }
        try NotebookValidation.validateStoredSnapshot(backup.notebook ?? NotebookSnapshot())
        if let notebook = backup.notebook { try NotebookHistoryPolicy.validate(notebook.history, notes: notebook.notes, assets: notebook.assets) }
        return backup
    }
    public static func backupPreview(_ data: Data) throws -> BackupPreview {
        let backup = try validatedBackup(data)
        return BackupPreview(entries: backup.entries.count, reports: backup.reports.count, summaries: backup.summaries?.count ?? 0, notes: backup.notebook?.notes.count ?? 0, folders: backup.notebook?.folders.count ?? 0, assets: backup.notebook?.assets.count ?? 0, versions: backup.notebook?.history.count ?? 0, hasPreferences: backup.extras != nil, customTemplates: backup.extras?.customTemplates.count ?? 0)
    }
    public static func backupExtras(_ data: Data) throws -> BackupExtras? {
        try validatedBackup(data).extras
    }
    public func importBackup(_ data: Data) throws -> ImportResult {
        let backup = try Self.validatedBackup(data)
        return try transaction {
            let existing = try read("entries", as: Entry.self)
            let entryIDs = Set(existing.map(\.id))
            let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            let incomingByID = Dictionary(uniqueKeysWithValues: backup.entries.map { ($0.id, $0) })
            // A series is one logical task. Local history/trash also claims it, so an older
            // backup cannot resurrect a completed series or fork it after an ancestor was erased.
            let localSeries = Set(existing.compactMap(\.recurrenceSeriesID))
            var skippedDescendants: Set<UUID> = []
            // Preserve local rows, and also skip incoming successors that would fork their chain.
            for incoming in backup.entries {
                guard let local = existingByID[incoming.id], local.nextOccurrenceID != incoming.nextOccurrenceID else { continue }
                var cursor = incoming.nextOccurrenceID
                var visited: Set<UUID> = []
                while let id = cursor, visited.insert(id).inserted {
                    if !entryIDs.contains(id) { skippedDescendants.insert(id) }
                    cursor = incomingByID[id]?.nextOccurrenceID
                }
            }
            let reportIDs = Set(try read("reports", as: Report.self).map(\.id))
            var result = ImportResult(entries: 0, reports: 0, skipped: 0)
            for entry in backup.entries {
                if entryIDs.contains(entry.id) || skippedDescendants.contains(entry.id)
                    || entry.recurrenceSeriesID.map({ localSeries.contains($0) }) == true { result.skipped += 1 }
                else { try persist(entry); result.entries += 1 }
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
            result.notebook = try mergeNotebook(backup.notebook ?? NotebookSnapshot())
            result.skipped += result.notebook.skipped
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
                try persist(entry)
            }
            return affected.count
        }
    }
    func transaction<T>(beginSQL: String = "BEGIN IMMEDIATE", _ body: () throws -> T) throws -> T {
        try execute(beginSQL)
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func exportBackup(extras: BackupExtras? = nil) throws -> Data {
        try extras?.validate()
        let value = try transaction(beginSQL: "BEGIN DEFERRED") {
            Backup(formatVersion: extras == nil ? 6 : 7, entries: try read("entries", as: Entry.self), reports: try read("reports", as: Report.self), summaries: try read("range_summaries", as: RangeSummary.self), notebook: try notebookSnapshot(), extras: extras?.canonicalized())
        }
        // Release the consistent-read transaction before large JSON serialization, so
        // the UI connection can commit autosaves while the background encoder works.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
    /// Changes made by other connections; the backup worker uses this to avoid repeated large exports.
    func backupChangeToken() throws -> Int { try scalar("PRAGMA data_version") }
    public func entries() throws -> [Entry] {
        try read("entries", as: Entry.self).filter { $0.deletedAt == nil }.sorted { $0.createdAt > $1.createdAt }
    }
    public func trashedEntries() throws -> [Entry] {
        try read("entries", as: Entry.self).filter { $0.deletedAt != nil }.sorted { $0.deletedAt! > $1.deletedAt! }
    }
    public func delete(id: UUID) throws {
        try transaction {
            guard var entry = try entries().first(where: { $0.id == id }) else { return }
            entry.deletedAt = Date(); entry.updatedAt = Date(); try persist(entry)
        }
    }
    public func restore(id: UUID) throws {
        try transaction {
            guard var entry = try trashedEntries().first(where: { $0.id == id }) else { return }
            entry.deletedAt = nil; entry.updatedAt = Date(); try persist(entry)
        }
    }
    public func permanentlyDelete(id: UUID) throws {
        try transaction {
            guard try trashedEntries().contains(where: { $0.id == id }) else { throw JournalError.invalid("只能永久删除回收站中的记录。") }
            try execute("DELETE FROM entries WHERE id=?", values: [id.uuidString])
        }
    }
    private static func validateSummary(_ summary: RangeSummary) throws {
        try Self.validateDay(summary.startDay); try Self.validateDay(summary.endDay)
        guard summary.startDay <= summary.endDay, !summary.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JournalError.invalid("总结日期范围或内容无效。")
        }
    }
    public func saveSummary(_ summary: RangeSummary) throws {
        try Self.validateSummary(summary)
        try execute("INSERT INTO range_summaries(id,payload) VALUES(?,?)", values: [summary.id.uuidString, try payload(summary)])
    }
    public func allSummaries() throws -> [RangeSummary] {
        try read("range_summaries", as: RangeSummary.self)
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString > $1.id.uuidString : $0.createdAt > $1.createdAt }
    }
    public func summaries(startDay: String, endDay: String) throws -> [RangeSummary] {
        try allSummaries().filter { $0.startDay == startDay && $0.endDay == endDay }
    }
    public func reportEntries(day: String) throws -> [Entry] { try entries().filter { $0.day == day && $0.inReport }.sorted { $0.createdAt < $1.createdAt } }
    private static func validateDay(_ day: String) throws {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: day), formatter.string(from: date) == day else { throw JournalError.invalid("日期格式应为 yyyy-MM-dd，例如 2026-10-30") }
    }
    public func saveReport(_ report: Report) throws {
        try Self.validateDay(report.day)
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
