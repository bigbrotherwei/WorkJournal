import Foundation
import Testing
@testable import JournalCore

struct BackupPreferencesTests {
    private func fixture(_ body: (UserDefaults, JournalStore, URL) throws -> Void) throws {
        let suite = "BackupPreferencesTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try body(defaults, JournalStore(url: root.appendingPathComponent("journal.sqlite")), root)
    }

    private var portableArchive: Data {
        Data(##"{"formatVersion":7,"entries":[],"reports":[],"extras":{"preferences":{"model":"local-model","powerMode":"自动","shortcut":{"keyCode":49,"control":true,"option":true,"command":false,"shift":false},"reportOpening":"开头","reportClosing":"结尾","notebookFontSize":16,"mainSidebarHidden":true,"notebookFoldersHidden":false,"notebookListHidden":false,"recordActivityExpanded":true,"automaticBackup":{"enabled":true,"retentionCount":14}},"customTemplates":[{"id":"6B293324-AC81-46AE-B8B3-793D736733C2","title":"自定义","markdown":"# 正文"}]}}"##.utf8)
    }

    @Test func versionSevenPortableArchiveCanImportContent() throws {
        try fixture { _, store, _ in
            #expect(throws: Never.self) { _ = try store.importBackup(portableArchive) }
        }
    }

    @Test func legacyArchiveCannotSmuggleUnvalidatedExtras() throws {
        try fixture { _, store, _ in
            let data = Data(##"{"formatVersion":6,"entries":[],"reports":[],"extras":{"preferences":"broken","customTemplates":[]}}"##.utf8)
            #expect(throws: (any Error).self) { try store.importBackup(data) }
        }
    }

    @Test func captureIncludesEffectiveDefaultsAndOnlyPortableKeys() throws {
        try fixture { defaults, _, root in
            defaults.set("secret draft", forKey: "draft")
            defaults.set("secret OCR", forKey: "ocr.cache")
            defaults.set(root.path, forKey: "automaticBackup.directory")
            let store = BackupPreferencesStore(defaults: defaults)
            let value = try store.capture(automaticBackup: AutomaticBackupSettings(directory: root, enabled: false, retentionCount: 23))
            #expect(value.preferences.model == "")
            #expect(value.preferences.powerMode == .automatic)
            #expect(value.preferences.shortcut == ShortcutConfiguration())
            #expect(value.preferences.notebookFontSize == 14)
            #expect(!value.preferences.mainSidebarHidden && !value.preferences.notebookFoldersHidden && !value.preferences.notebookListHidden && !value.preferences.recordActivityExpanded)
            #expect(value.preferences.automaticBackup == BackupSchedulePreferences(enabled: false, retentionCount: 23))
            let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            for excluded in ["secret draft", "secret OCR", root.path, "directory", "libraryID"] { #expect(!text.contains(excluded)) }
            #expect(value.customTemplates.isEmpty)
        }
    }

    @Test func captureUsesLegacyPowerPolicyAndEffectiveShortcutAndFontFallbacks() throws {
        try fixture { defaults, _, _ in
            defaults.set(true, forKey: "powerSaving")
            defaults.set(Data("broken".utf8), forKey: "captureShortcut")
            defaults.set(999, forKey: "notebook.fontSize")
            let captured = try BackupPreferencesStore(defaults: defaults).capture()
            #expect(captured.preferences.powerMode == .saving)
            #expect(captured.preferences.shortcut == ShortcutConfiguration())
            #expect(captured.preferences.notebookFontSize == 14)
        }
    }

    @Test func roundTripIncludesPreviewExtrasAndRestoresAllowlistedPreferences() throws {
        try fixture { defaults, store, root in
            let extras = try #require(try JournalStore.backupExtras(portableArchive))
            let data = try store.exportBackup(extras: extras)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["formatVersion"] as? Int == 7)
            #expect(try JournalStore.backupExtras(data) == extras)
            let preview = try JournalStore.backupPreview(data)
            #expect(preview.hasPreferences && preview.customTemplates == 1)
            defaults.set("keep draft", forKey: "draft")
            defaults.set(true, forKey: "notebook.foldersHidden")
            defaults.set(true, forKey: "notebook.listHidden")
            defaults.set(PowerMode.saving.rawValue, forKey: "powerMode")
            defaults.set(root.path, forKey: "automaticBackup.directory")
            let preferences = BackupPreferencesStore(defaults: defaults)
            let plan = try preferences.prepareRestore(extras, restorePreferences: true)
            #expect(defaults.string(forKey: "model") == nil)
            #expect(plan.preferences == extras.preferences && plan.addedTemplates == 1 && plan.skippedTemplates == 0)
            preferences.apply(plan)
            #expect(try preferences.capture().preferences.model == "local-model")
            #expect(defaults.string(forKey: "reportTemplate.opening") == "开头")
            #expect(defaults.string(forKey: "reportTemplate.closing") == "结尾")
            #expect(defaults.integer(forKey: "notebook.fontSize") == 16)
            #expect(!defaults.bool(forKey: "notebook.foldersHidden") && !defaults.bool(forKey: "notebook.listHidden"))
            #expect(defaults.string(forKey: "powerMode") == "自动")
            #expect(defaults.bool(forKey: "main.sidebarHidden") && defaults.bool(forKey: "recordActivityExpanded"))
            #expect(defaults.string(forKey: "draft") == "keep draft")
            #expect(defaults.string(forKey: "automaticBackup.directory") == root.path)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("automatic-backup.json").path))
        }
    }

    @Test func optionalSettingsRestoreStillMergesTemplatesAndKeepsLocalDuplicates() throws {
        try fixture { defaults, _, _ in
            var extras = try #require(try JournalStore.backupExtras(portableArchive))
            var local = extras.customTemplates[0]; local.markdown = "本地编辑"
            let new = ContentTemplate(title: "新增", markdown: "内容")
            extras.customTemplates.append(new)
            let library = TemplateLibraryStore(defaults: defaults)
            try library.save(local)
            defaults.set("keep-model", forKey: "model")
            let store = BackupPreferencesStore(defaults: defaults)
            let plan = try store.prepareRestore(extras, restorePreferences: false)
            #expect(plan.preferences == nil && plan.addedTemplates == 1 && plan.skippedTemplates == 1)
            #expect(try library.load() == [local])
            store.apply(plan)
            #expect(try library.load() == [local, new])
            #expect(defaults.string(forKey: "model") == "keep-model")
        }
    }

    @Test func shortcutConflictCanKeepCurrentShortcutWhileApplyingOtherPreferences() throws {
        try fixture { defaults, _, _ in
            let current = ShortcutConfiguration(keyCode: 0, control: true, option: false, command: true)
            defaults.set(try JSONEncoder().encode(current), forKey: "captureShortcut")
            let store = BackupPreferencesStore(defaults: defaults)
            let extras = try #require(try JournalStore.backupExtras(portableArchive))
            store.apply(try store.prepareRestore(extras, restorePreferences: true), restoreShortcut: false)
            let after = try store.capture()
            #expect(after.preferences.shortcut == current)
            #expect(after.preferences.model == "local-model")
        }
    }

    @Test func combinedTemplateCapacityIsCheckedWithoutAnyPreferenceWrites() throws {
        try fixture { defaults, _, _ in
            let templates = (0..<500).map { ContentTemplate(title: "模板 \($0)", markdown: "内容") }
            let data = try JSONEncoder().encode(templates)
            defaults.set(data, forKey: TemplateLibraryStore.storageKey)
            let store = BackupPreferencesStore(defaults: defaults)
            let extras = try #require(try JournalStore.backupExtras(portableArchive))
            #expect(throws: (any Error).self) { try store.prepareRestore(extras, restorePreferences: true) }
            #expect(defaults.data(forKey: TemplateLibraryStore.storageKey) == data)
            #expect(defaults.string(forKey: "model") == nil)
            var duplicate = extras; duplicate.customTemplates = [templates[0]]
            let plan = try store.prepareRestore(duplicate, restorePreferences: false)
            #expect(plan.addedTemplates == 0 && plan.skippedTemplates == 1)
        }
    }

    @Test func invalidPreferenceFieldsAndTemplatesFailBeforeContentImport() throws {
        try fixture { _, target, root in
            let source = try JournalStore(url: root.appendingPathComponent("source.sqlite"))
            try source.save(Entry(text: "不应导入", day: "2026-11-25"))
            let extras = try #require(try JournalStore.backupExtras(portableArchive))
            let original = try #require(JSONSerialization.jsonObject(with: source.exportBackup(extras: extras)) as? [String: Any])
            let invalidValues: [(String, Any)] = [
                ("model", String(repeating: "a", count: 257)),
                ("powerMode", "invalid"), ("notebookFontSize", 999),
                ("reportOpening", String(repeating: "a", count: 1024 * 1024 + 1)),
                ("reportClosing", String(repeating: "a", count: 1024 * 1024 + 1)),
                ("mainSidebarHidden", "true"),
                ("automaticBackup", ["enabled": true, "retentionCount": 366]),
                ("shortcut", ["keyCode": 999, "control": true, "option": true, "command": false, "shift": false]),
                ("shortcut", ["keyCode": 49, "control": false, "option": true, "command": false, "shift": false])
            ]
            for (key, invalid) in invalidValues {
                var object = original
                var payload = try #require(object["extras"] as? [String: Any])
                var preferences = try #require(payload["preferences"] as? [String: Any])
                preferences[key] = invalid; payload["preferences"] = preferences; object["extras"] = payload
                let data = try JSONSerialization.data(withJSONObject: object)
                #expect(throws: (any Error).self) { try target.importBackup(data) }
                #expect(try target.entries().isEmpty)
            }
            for templates in [[extras.customTemplates[0], extras.customTemplates[0]], [ContentTemplates.builtIns[0]], [ContentTemplate(title: " ", markdown: "text")], [ContentTemplate(title: "正文过大", markdown: String(repeating: "x", count: 1024 * 1024 + 1))], (0..<501).map { ContentTemplate(title: "\($0)", markdown: "正文") }] {
                var object = original
                var payload = try #require(object["extras"] as? [String: Any])
                payload["customTemplates"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(templates))
                object["extras"] = payload
                #expect(throws: (any Error).self) { try target.importBackup(JSONSerialization.data(withJSONObject: object)) }
                #expect(try target.entries().isEmpty)
            }
        }
    }

    @Test func invalidLocalTemplateDataIsPreservedAndDoesNotProduceBackup() throws {
        try fixture { defaults, _, _ in
            let invalid = Data("broken".utf8)
            defaults.set(invalid, forKey: TemplateLibraryStore.storageKey)
            let store = BackupPreferencesStore(defaults: defaults)
            #expect(throws: (any Error).self) { try store.capture() }
            #expect(throws: (any Error).self) { try store.prepareRestore(JournalStore.backupExtras(portableArchive)!, restorePreferences: false) }
            #expect(defaults.data(forKey: TemplateLibraryStore.storageKey) == invalid)
        }
    }

    @Test func legacyVersionsLeaveExtrasAbsentAndDefaultExportRemainsCompatible() throws {
        try fixture { defaults, store, _ in
            defaults.set("local", forKey: "model")
            for version in 1...6 {
                let data = Data("{\"formatVersion\":\(version),\"entries\":[],\"reports\":[]}".utf8)
                #expect(try JournalStore.backupExtras(data) == nil)
                let preview = try JournalStore.backupPreview(data)
                #expect(!preview.hasPreferences && preview.customTemplates == 0)
                _ = try store.importBackup(data)
                #expect(defaults.string(forKey: "model") == "local")
            }
            #expect(try JournalStore.backupExtras(store.exportBackup()) == nil)
        }
    }

    @Test func captureAndExportSortTemplateIDsForStableFingerprints() throws {
        try fixture { defaults, store, _ in
            let first = ContentTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "一", markdown: "内容")
            let second = ContentTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "二", markdown: "内容")
            defaults.set(try JSONEncoder().encode([second, first]), forKey: TemplateLibraryStore.storageKey)
            let captured = try BackupPreferencesStore(defaults: defaults).capture()
            #expect(captured.customTemplates == [first, second])
            var reordered = captured; reordered.customTemplates.reverse()
            #expect(try store.exportBackup(extras: captured) == store.exportBackup(extras: reordered))
        }
    }

    @Test func automaticBackupNoticesPreferenceAndTemplateChangesAfterNoChangeCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-extras-worker-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.sqlite")
        let database = try JournalStore(url: url)
        try database.save(Entry(text: "相同记录", day: "2026-11-25"))
        let worker = AutomaticBackupWorker(dataDirectory: root, databaseURL: url)
        let (settings, initial) = try await worker.load()
        var extras = try #require(try JournalStore.backupExtras(portableArchive))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await worker.run(settings: settings, state: initial, now: start, extras: extras)
        let nextDay = start.addingTimeInterval(86400)
        let unchanged = try await worker.run(settings: settings, state: first, now: nextDay, extras: extras)
        #expect(unchanged == first)
        extras.preferences.reportOpening = "仅设置变化"
        let changed = try await worker.run(settings: settings, state: unchanged, now: nextDay.addingTimeInterval(1), extras: extras)
        #expect(changed.lastSuccess == nextDay.addingTimeInterval(1))
        #expect(changed.fingerprint != first.fingerprint)
        extras.customTemplates.append(ContentTemplate(title: "新增模板", markdown: "正文"))
        let sameDay = try await worker.run(settings: settings, state: changed, now: nextDay.addingTimeInterval(2), extras: extras)
        #expect(sameDay == changed)
        let third = try await worker.run(settings: settings, state: sameDay, now: start.addingTimeInterval(172800), extras: extras)
        #expect(third.fingerprint != changed.fingerprint)
        let files = try await worker.files(settings: settings, state: third)
        #expect(files.map(\.preview.customTemplates) == [2, 1, 1])
        #expect(files.allSatisfy { $0.preview.hasPreferences })
    }

    @Test func typedInvalidExtrasAreRejectedEvenWhenSettingsRestoreIsDisabled() throws {
        try fixture { defaults, store, _ in
            var extras = try #require(try JournalStore.backupExtras(portableArchive))
            extras.preferences.notebookFontSize = 999
            let preferences = BackupPreferencesStore(defaults: defaults)
            #expect(throws: (any Error).self) { try preferences.prepareRestore(extras, restorePreferences: false) }
            #expect(throws: (any Error).self) { try store.exportBackup(extras: extras) }
            #expect(defaults.data(forKey: TemplateLibraryStore.storageKey) == nil)
        }
    }

    @Test func validExtrasCannotBeSilentlyIgnoredByLegacyVersions() throws {
        try fixture { _, store, _ in
            var object = try #require(JSONSerialization.jsonObject(with: portableArchive) as? [String: Any])
            for version in 1...6 {
                object["formatVersion"] = version
                let data = try JSONSerialization.data(withJSONObject: object)
                #expect(throws: (any Error).self) { try store.importBackup(data) }
            }
        }
    }
}
