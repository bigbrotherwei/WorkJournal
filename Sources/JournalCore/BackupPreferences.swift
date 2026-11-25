import Foundation

/// Portable scheduling choices. The destination and library identity stay on this Mac.
public struct BackupSchedulePreferences: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var retentionCount: Int
    public init(enabled: Bool = true, retentionCount: Int = 14) {
        self.enabled = enabled; self.retentionCount = retentionCount
    }
}

/// An explicit allowlist: never encode a complete UserDefaults domain or unsaved drafts.
public struct BackupPreferences: Codable, Equatable, Sendable {
    public var model: String
    public var powerMode: PowerMode
    public var shortcut: ShortcutConfiguration
    public var reportOpening: String
    public var reportClosing: String
    public var notebookFontSize: Int
    public var mainSidebarHidden: Bool
    public var notebookFoldersHidden: Bool
    public var notebookListHidden: Bool
    public var recordActivityExpanded: Bool
    public var automaticBackup: BackupSchedulePreferences?

    public init(model: String = "", powerMode: PowerMode = .automatic, shortcut: ShortcutConfiguration = ShortcutConfiguration(),
                reportOpening: String = "", reportClosing: String = "", notebookFontSize: Int = 14,
                mainSidebarHidden: Bool = false, notebookFoldersHidden: Bool = false, notebookListHidden: Bool = false,
                recordActivityExpanded: Bool = false, automaticBackup: BackupSchedulePreferences? = nil) {
        self.model = model; self.powerMode = powerMode; self.shortcut = shortcut
        self.reportOpening = reportOpening; self.reportClosing = reportClosing; self.notebookFontSize = notebookFontSize
        self.mainSidebarHidden = mainSidebarHidden; self.notebookFoldersHidden = notebookFoldersHidden
        self.notebookListHidden = notebookListHidden; self.recordActivityExpanded = recordActivityExpanded
        self.automaticBackup = automaticBackup
    }
    static let fontSizes = [12, 14, 16, 18, 20, 24]
    func validate() throws {
        guard model.utf8.count <= 256, reportOpening.utf8.count <= 1024 * 1024,
              reportClosing.utf8.count <= 1024 * 1024, Self.fontSizes.contains(notebookFontSize),
              automaticBackup.map({ (1...365).contains($0.retentionCount) }) ?? true else {
            throw JournalError.invalid("备份设置无效：模型名不超过 256 字节，日报开头和结尾各不超过 1 MiB，字号和自动备份保留数量须在支持范围内。")
        }
        try shortcut.validate()
    }
}

public struct BackupExtras: Codable, Equatable, Sendable {
    public var preferences: BackupPreferences
    public var customTemplates: [ContentTemplate]
    public init(preferences: BackupPreferences, customTemplates: [ContentTemplate]) {
        self.preferences = preferences; self.customTemplates = customTemplates
    }
    func validate() throws {
        try preferences.validate()
        try TemplateLibraryStore.validate(customTemplates)
    }
    func canonicalized() -> BackupExtras {
        var value = self
        value.customTemplates.sort { $0.id.uuidString < $1.id.uuidString }
        return value
    }
    func fingerprint() throws -> String {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return BackupPolicy.fingerprint(try encoder.encode(canonicalized()))
    }
}

/// Constructed only by prepareRestore, after validation and all potentially throwing encoding.
public struct PreparedBackupPreferencesRestore: Sendable {
    public let preferences: BackupPreferences?
    public let addedTemplates: Int
    public let skippedTemplates: Int
    fileprivate let templatesData: Data
    fileprivate let shortcutData: Data?
}

public final class BackupPreferencesStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func capture(automaticBackup: AutomaticBackupSettings? = nil) throws -> BackupExtras {
        var shortcut = ShortcutConfiguration()
        if let data = defaults.data(forKey: "captureShortcut"),
           let stored = try? JSONDecoder().decode(ShortcutConfiguration.self, from: data),
           (try? stored.validate()) != nil { shortcut = stored }
        let savedSize = defaults.integer(forKey: "notebook.fontSize")
        let preferences = BackupPreferences(
            model: defaults.string(forKey: "model") ?? "",
            powerMode: PowerPolicy.mode(saved: defaults.string(forKey: "powerMode"), legacySaving: defaults.object(forKey: "powerSaving") as? Bool),
            shortcut: shortcut,
            reportOpening: defaults.string(forKey: "reportTemplate.opening") ?? "",
            reportClosing: defaults.string(forKey: "reportTemplate.closing") ?? "",
            notebookFontSize: BackupPreferences.fontSizes.contains(savedSize) ? savedSize : 14,
            mainSidebarHidden: defaults.bool(forKey: "main.sidebarHidden"),
            notebookFoldersHidden: defaults.bool(forKey: "notebook.foldersHidden"),
            notebookListHidden: defaults.bool(forKey: "notebook.listHidden"),
            recordActivityExpanded: defaults.bool(forKey: "recordActivityExpanded"),
            automaticBackup: automaticBackup.map { BackupSchedulePreferences(enabled: $0.enabled, retentionCount: $0.retentionCount) })
        let extras = BackupExtras(preferences: preferences, customTemplates: try TemplateLibraryStore(defaults: defaults).load()).canonicalized()
        try extras.validate()
        return extras
    }

    /// Merge in memory first, so capacity or malformed local data cannot fail after DB import.
    public func prepareRestore(_ extras: BackupExtras, restorePreferences: Bool) throws -> PreparedBackupPreferencesRestore {
        try extras.validate()
        let local = try TemplateLibraryStore(defaults: defaults).load()
        let localIDs = Set(local.map(\.id))
        let added = extras.customTemplates.filter { !localIDs.contains($0.id) }
        let merged = local + added
        try TemplateLibraryStore.validate(merged)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return PreparedBackupPreferencesRestore(
            preferences: restorePreferences ? extras.preferences : nil,
            addedTemplates: added.count, skippedTemplates: extras.customTemplates.count - added.count,
            templatesData: try encoder.encode(merged),
            shortcutData: restorePreferences ? try encoder.encode(extras.preferences.shortcut) : nil)
    }

    /// The caller registers the shortcut first; false preserves the local shortcut on conflict.
    /// Automatic backup settings are persisted separately by its coordinator, keeping local paths.
    public func apply(_ plan: PreparedBackupPreferencesRestore, restoreShortcut: Bool = true) {
        defaults.set(plan.templatesData, forKey: TemplateLibraryStore.storageKey)
        guard let preferences = plan.preferences else { return }
        defaults.set(preferences.model, forKey: "model")
        defaults.set(preferences.powerMode.rawValue, forKey: "powerMode")
        if restoreShortcut, let data = plan.shortcutData { defaults.set(data, forKey: "captureShortcut") }
        defaults.set(preferences.reportOpening, forKey: "reportTemplate.opening")
        defaults.set(preferences.reportClosing, forKey: "reportTemplate.closing")
        defaults.set(preferences.notebookFontSize, forKey: "notebook.fontSize")
        defaults.set(preferences.mainSidebarHidden, forKey: "main.sidebarHidden")
        defaults.set(preferences.notebookFoldersHidden, forKey: "notebook.foldersHidden")
        defaults.set(preferences.notebookListHidden, forKey: "notebook.listHidden")
        defaults.set(preferences.recordActivityExpanded, forKey: "recordActivityExpanded")
    }
}
