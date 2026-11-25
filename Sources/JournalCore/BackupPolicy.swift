import Foundation
import CryptoKit

public struct BackupPreview: Equatable, Sendable {
    public var entries: Int
    public var reports: Int
    public var summaries: Int
    public var notes: Int
    public var folders: Int
    public var assets: Int
    public var versions: Int
    public var hasPreferences: Bool = false
    public var customTemplates: Int = 0
}

public struct AutomaticBackupState: Codable, Equatable, Sendable {
    public var libraryID: UUID
    public var lastSuccess: Date?
    public var fingerprint: String?
    public var lastResult: String?
    public init(libraryID: UUID = UUID(), lastSuccess: Date? = nil, fingerprint: String? = nil, lastResult: String? = nil) {
        self.libraryID = libraryID; self.lastSuccess = lastSuccess; self.fingerprint = fingerprint; self.lastResult = lastResult
    }
}

public struct AutomaticBackupSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var retentionCount: Int
    public var directory: URL
    public init(directory: URL, enabled: Bool = true, retentionCount: Int = 14) {
        self.enabled = enabled; self.retentionCount = min(365, max(1, retentionCount)); self.directory = directory
    }
}

public enum BackupPolicy {
    public static func shouldWrite(enabled: Bool, force: Bool, now: Date, fingerprint: String, state: AutomaticBackupState, calendar: Calendar = .current) -> Bool {
        if force { return true }
        guard enabled, state.fingerprint != fingerprint else { return false }
        return state.lastSuccess.map { !calendar.isDate($0, inSameDayAs: now) } ?? true
    }
    public static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public struct LocalBackupFile: Identifiable, Equatable, Sendable {
    public var id: URL { url }
    public var url: URL
    public var createdAt: Date
    public var byteCount: Int
    public var preview: BackupPreview
}
public struct BackupWriteResult: Sendable {
    public var file: LocalBackupFile
    public var warning: String?
}

/// Complete backup JSON remains directly importable by JournalStore. The private marker
/// limits retention to verified archives created for this specific local library.
public enum LocalBackupArchive {
    private struct Marker: Codable {
        var producer = "workjournal.automatic.v1"
        var libraryID: UUID
        var createdAt: Date
        var contentHash: String
    }
    private struct MarkerEnvelope: Decodable { var automaticBackup: Marker? }

    public static func write(data: Data, directory: URL, libraryID: UUID, retentionCount: Int, now: Date = Date(), remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws -> BackupWriteResult {
        guard now.timeIntervalSinceReferenceDate.isFinite, directory.isFileURL else { throw JournalError.invalid("备份日期或本地目录无效。") }
        _ = try JournalStore.backupPreview(data)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw JournalError.invalid("备份内容无效。") }
        object.removeValue(forKey: "automaticBackup")
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let marker = Marker(libraryID: libraryID, createdAt: now, contentHash: BackupPolicy.fingerprint(canonical))
        object["automaticBackup"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(marker))
        let archive = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "workjournal-auto-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.lowercased()).json"
        let destination = directory.appendingPathComponent(name)
        // Atomic replacement is complete before verification or deletion of any previous file.
        try archive.write(to: destination, options: .atomic)
        let file: LocalBackupFile
        do { file = try verifiedFile(destination, libraryID: libraryID) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        var warnings: [String] = []
        let files = try list(directory: directory, libraryID: libraryID)
        for obsolete in files.dropFirst(min(365, max(1, retentionCount))) where obsolete.url != destination {
            do { _ = try verifiedFile(obsolete.url, libraryID: libraryID); try remove(obsolete.url) }
            catch { warnings.append("\(obsolete.url.lastPathComponent)：\(error.localizedDescription)") }
        }
        return BackupWriteResult(file: file, warning: warnings.isEmpty ? nil : "新备份已保存，但旧备份清理失败：" + warnings.joined(separator: "；"))
    }
    public static func list(directory: URL, libraryID: UUID) throws -> [LocalBackupFile] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .filter { $0.lastPathComponent.hasPrefix("workjournal-auto-") && $0.pathExtension == "json" }
            .compactMap { try? verifiedFile($0, libraryID: libraryID) }
            .sorted { $0.createdAt == $1.createdAt ? $0.url.lastPathComponent > $1.url.lastPathComponent : $0.createdAt > $1.createdAt }
    }
    private static func verifiedFile(_ url: URL, libraryID: UUID) throws -> LocalBackupFile {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw JournalError.invalid("备份不是普通本地文件。") }
        let data = try Data(contentsOf: url)
        let marker = try JSONDecoder().decode(MarkerEnvelope.self, from: data).automaticBackup
        guard let marker, marker.producer == "workjournal.automatic.v1", marker.libraryID == libraryID,
              marker.createdAt.timeIntervalSinceReferenceDate.isFinite,
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw JournalError.invalid("文件不属于本机自动备份。") }
        object.removeValue(forKey: "automaticBackup")
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard marker.contentHash == BackupPolicy.fingerprint(canonical) else { throw JournalError.invalid("自动备份校验不通过，保留文件以供检查。") }
        return LocalBackupFile(url: url, createdAt: marker.createdAt, byteCount: data.count, preview: try JournalStore.backupPreview(data))
    }
}

/// All database reads, archive serialization, file verification and retention run off the UI actor.
public actor AutomaticBackupWorker {
    private struct Configuration: Codable { var settings: AutomaticBackupSettings; var state: AutomaticBackupState }
    private let dataDirectory: URL
    private let databaseURL: URL
    private var store: JournalStore?
    private var lastObservedToken: Int?
    private var lastCheckedDay: String?
    private var lastObservedExtrasFingerprint: String?
    public init(dataDirectory: URL, databaseURL: URL) { self.dataDirectory = dataDirectory; self.databaseURL = databaseURL }
    private var configurationURL: URL { dataDirectory.appendingPathComponent("automatic-backup.json") }
    public func load() throws -> (AutomaticBackupSettings, AutomaticBackupState) {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            return (AutomaticBackupSettings(directory: dataDirectory.appendingPathComponent("Backups/Automatic")), AutomaticBackupState())
        }
        let value = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configurationURL))
        guard value.settings.directory.isFileURL, (1...365).contains(value.settings.retentionCount) else { throw JournalError.invalid("自动备份设置无效，原文件已保留。") }
        return (value.settings, value.state)
    }
    public func save(settings: AutomaticBackupSettings, state: AutomaticBackupState) throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Configuration(settings: settings, state: state)).write(to: configurationURL, options: .atomic)
    }
    public func files(settings: AutomaticBackupSettings, state: AutomaticBackupState) throws -> [LocalBackupFile] {
        try LocalBackupArchive.list(directory: settings.directory, libraryID: state.libraryID)
    }
    public func preview(url: URL) throws -> BackupPreview { try JournalStore.backupPreview(Data(contentsOf: url)) }
    public func run(settings: AutomaticBackupSettings, state: AutomaticBackupState, force: Bool = false, now: Date = Date(), extras: BackupExtras? = nil) throws -> AutomaticBackupState {
        guard force || settings.enabled else { return state }
        if !force, let date = state.lastSuccess, Calendar.current.isDate(date, inSameDayAs: now) { return state }
        if store == nil { store = try JournalStore(url: databaseURL) }
        guard let store else { throw JournalError.invalid("备份数据库无法打开。") }
        let token = try store.backupChangeToken()
        let day = Days.key(now)
        let extrasFingerprint = try extras?.fingerprint()
        if !force, state.fingerprint != nil, lastObservedToken == token, lastCheckedDay == day, lastObservedExtrasFingerprint == extrasFingerprint { return state }
        let data = try store.exportBackup(extras: extras)
        let fingerprint = BackupPolicy.fingerprint(data)
        guard BackupPolicy.shouldWrite(enabled: settings.enabled, force: force, now: now, fingerprint: fingerprint, state: state) else {
            lastObservedToken = token; lastCheckedDay = day; lastObservedExtrasFingerprint = extrasFingerprint
            return state
        }
        let result = try LocalBackupArchive.write(data: data, directory: settings.directory, libraryID: state.libraryID, retentionCount: settings.retentionCount, now: now)
        var next = state
        next.lastSuccess = now; next.fingerprint = fingerprint; next.lastResult = result.warning ?? "备份已完成：\(result.file.url.lastPathComponent)"
        try save(settings: settings, state: next)
        lastObservedToken = token; lastCheckedDay = day; lastObservedExtrasFingerprint = extrasFingerprint
        return next
    }
}
