import SwiftUI
import AppKit
import JournalCore

@MainActor final class AppModel: ObservableObject {
    @Published var entries: [Entry] = []
    @Published var trash: [Entry] = []
    @Published var navigationTarget: String?
    let reminders = ReminderCoordinator()
    @Published var draftRecurrence = TaskRecurrence(rawValue: UserDefaults.standard.string(forKey: "draftRecurrence") ?? "") ?? .none {
        didSet { UserDefaults.standard.set(draftRecurrence.rawValue, forKey: "draftRecurrence") }
    }
    @Published var draftDueAt = UserDefaults.standard.object(forKey: "draftDueAt") as? Date {
        didSet { UserDefaults.standard.set(draftDueAt, forKey: "draftDueAt") }
    }
    @Published var draftReminderEnabled = UserDefaults.standard.bool(forKey: "draftReminderEnabled") {
        didSet { UserDefaults.standard.set(draftReminderEnabled, forKey: "draftReminderEnabled") }
    }
    @Published var shortcut: ShortcutConfiguration = {
        guard let data = UserDefaults.standard.data(forKey: "captureShortcut"),
              let value = try? JSONDecoder().decode(ShortcutConfiguration.self, from: data),
              (try? value.validate()) != nil else { return ShortcutConfiguration() }
        return value
    }()
    @Published var shortcutStatus = "尚未注册"
    var registerShortcut: ((ShortcutConfiguration) throws -> Void)?
    func applyShortcut(_ value: ShortcutConfiguration) {
        do {
            guard let registerShortcut else { throw JournalError.invalid("快捷键服务尚未准备好") }
            try registerShortcut(value)
            shortcut = value
            UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: "captureShortcut")
            shortcutStatus = "已启用：" + value.label
        } catch { self.error = error.localizedDescription }
    }
    @Published var error: String?
    @Published var notice = "所有记录仅保存在此 Mac"
    @Published var busy = false
    @Published var generationProgress = ""
    @Published var isClassifying = false
    @Published var reportQueued = false
    @Published var models: [String] = []
    @Published var checkingModels = false
    @Published var serviceStatus = "尚未检查本地服务"
    @Published var modelTrial: ModelTrialResult?
    @Published var model: String = UserDefaults.standard.string(forKey: "model") ?? "" {
        didSet { UserDefaults.standard.set(model, forKey: "model"); progress.reset(); if !checkingModels { queuePaused = false }; scheduleClassification() }
    }
    @Published var reportOpening = UserDefaults.standard.string(forKey: "reportTemplate.opening") ?? "" {
        didSet { UserDefaults.standard.set(reportOpening, forKey: "reportTemplate.opening") }
    }
    @Published var reportClosing = UserDefaults.standard.string(forKey: "reportTemplate.closing") ?? "" {
        didSet { UserDefaults.standard.set(reportClosing, forKey: "reportTemplate.closing") }
    }
    @Published var powerMode: PowerMode = PowerPolicy.mode(saved: UserDefaults.standard.string(forKey: "powerMode"), legacySaving: UserDefaults.standard.object(forKey: "powerSaving") as? Bool) {
        didSet {
            UserDefaults.standard.set(powerMode.rawValue, forKey: "powerMode")
            if !powerSaving { queuePaused = false }
            scheduleClassification()
        }
    }
    @Published private(set) var powerState = PowerSnapshot()
    var powerSaving: Bool { PowerPolicy.pausesBackground(mode: powerMode, state: powerState) }
    func updatePower(_ state: PowerSnapshot) {
        guard state != powerState else { return }
        powerState = state
        // A hardware event must not override a user's cancel or retry a failed model.
        scheduleClassification()
    }
    @Published var draft: String = UserDefaults.standard.string(forKey: "draft") ?? "" {
        didSet {
            draftDate = CaptureDatePolicy.onInput(previous: draftImages.isEmpty ? oldValue : "图片", text: draft, selected: draftDate, manual: draftDateManual, now: Date())
            UserDefaults.standard.set(draft, forKey: "draft")
        }
    }
    @Published private(set) var draftDateManual = UserDefaults.standard.bool(forKey: "draftDateManual") {
        didSet { UserDefaults.standard.set(draftDateManual, forKey: "draftDateManual") }
    }
    func selectDraftDate(_ date: Date) { draftDateManual = true; draftDate = date }
    func useTodayForDraft() { draftDateManual = false; draftDate = Date() }
    func prepareCapture() {
        draftDate = CaptureDatePolicy.onOpen(text: draftImages.isEmpty ? draft : "图片", selected: draftDate, manual: draftDateManual, now: Date())
    }
    @Published var draftDate = (UserDefaults.standard.object(forKey: "draftDate") as? Date) ?? Date() {
        didSet { UserDefaults.standard.set(draftDate, forKey: "draftDate") }
    }
    @Published var draftInReport = UserDefaults.standard.bool(forKey: "draftInReport") {
        didSet { UserDefaults.standard.set(draftInReport, forKey: "draftInReport") }
    }
    @Published var draftStatus: FollowUp = FollowUp(rawValue: UserDefaults.standard.string(forKey: "draftStatus") ?? "") ?? .none {
        didSet { UserDefaults.standard.set(draftStatus.rawValue, forKey: "draftStatus") }
    }
    @Published private(set) var draftImages: [ImageAttachment] = []
    private var draftImageStore: DraftImageStore?
    func replaceDraftContent(_ text: String, images: [ImageAttachment]) {
        do {
            guard let draftImageStore else { throw JournalError.invalid("图文草稿存储尚未就绪") }
            try draftImageStore.save(RecordDraft(text: text, images: images))
            draft = text
            draftImages = images
        } catch { self.error = error.localizedDescription }
    }
    private var store: JournalStore?
    private let client = OllamaClient()
    private var operation: Task<Void, Never>?
    private var deleted: Entry?
    private var progress = ClassificationProgress()
    private var queuePaused = false
    private var scheduled: Task<Void, Never>?
    private var waitingReport: (() -> Void)?
    private var manualClassificationRequested = false
    var canUndo: Bool { deleted != nil }
    var categories: [String] { Array(Set(entries.map(\.category))).sorted() }
    init() {
        do {
            let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            store = try JournalStore(url: dir.appendingPathComponent("WorkJournal/journal.sqlite"))
            try reload()
            let draftStore = DraftImageStore(url: dir.appendingPathComponent("WorkJournal/draft-content.json"))
            do {
                if let content = try draftStore.load() { draft = content.text; draftImages = content.images }
            } catch {
                let preserved = draftStore.url.deletingLastPathComponent().appendingPathComponent("damaged-draft-" + UUID().uuidString + ".json")
                try FileManager.default.moveItem(at: draftStore.url, to: preserved)
                self.error = "草稿未能读取，原文件已保留：" + preserved.lastPathComponent
            }
            draftImageStore = draftStore
            if let backup = store?.migrationBackupURL { notice = "数据格式已升级，原始备份：" + backup.lastPathComponent }
            scheduleClassification()
        } catch { self.error = error.localizedDescription }
    }
    private func database() throws -> JournalStore {
        guard let store else { throw JournalError.invalid("数据库未打开，请重启应用；原有数据不会被覆盖。") }
        return store
    }
    private func reload() throws {
        entries = try database().entries(); trash = try database().trashedEntries()
        reminders.reconcile(entries: entries)
    }
    @discardableResult func save(_ entry: Entry) -> Bool {
        do { try database().save(entry); try reload(); scheduleClassification()
            if entry.status == .pending && entry.dueAt != nil && entry.reminderEnabled {
                Task { await reminders.requestAuthorization() }
            }
            return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func saveEdited(original: Entry, edited: Entry) -> Bool {
        guard let current = entries.first(where: { $0.id == original.id }) else {
            error = "这条记录已被删除，未保存编辑内容。请复制需要保留的文字后关闭窗口。"
            return false
        }
        do { return save(try EntryEditing.merge(original: original, edited: edited, current: current)) }
        catch { self.error = error.localizedDescription; return false }
    }
    func setFollowUp(id: UUID, status: FollowUp) {
        guard var current = entries.first(where: { $0.id == id }) else { return }
        guard current.status != status else { return }
        current.status = status; current.updatedAt = Date()
        if save(current) { notice = "跟进状态已更新：" + status.rawValue }
    }
    func saveDraft() -> Bool {
        var entry = Entry(text: draft, day: Days.key(draftDate))
        entry.inReport = draftInReport; entry.status = draftStatus; entry.images = draftImages
        entry.dueAt = draftDueAt; entry.reminderEnabled = draftReminderEnabled; entry.recurrence = draftRecurrence
        guard save(entry) else { return false }
        do { try draftImageStore?.save(RecordDraft()); draftImages = [] }
        catch { self.error = "记录已保存，但图片草稿清理失败：" + error.localizedDescription; return false }
        draft = ""; draftDateManual = false; draftDate = Date(); draftInReport = false; draftStatus = .none; draftDueAt = nil; draftReminderEnabled = false; draftRecurrence = .none
        notice = "已保存 · \(entry.day)"
        return true
    }
    func snooze(_ id: UUID, until date: Date, expectedTimestamp: TimeInterval? = nil) {
        do {
            if let expectedTimestamp {
                guard let current = entries.first(where: { $0.id == id }),
                      ReminderPolicy.isActive(current),
                      ReminderPolicy.scheduledDate(for: current)?.timeIntervalSince1970 == expectedTimestamp else {
                    notice = "这条提醒已变化，请在待办中查看最新状态。"; return
                }
            }
            try database().snooze(id: id, until: date); try reload()
            notice = "将在 " + date.formatted(date: .abbreviated, time: .shortened) + " 提醒，截止时间不变"
            Task { await reminders.requestAuthorization() }
        } catch { self.error = error.localizedDescription }
    }
    func delete(_ entry: Entry) {
        do { try database().delete(id: entry.id); deleted = entry; try reload(); notice = "已移入回收站，可恢复" }
        catch { self.error = error.localizedDescription }
    }
    func undoDelete() { if let deleted { restoreEntry(deleted.id) } }
    func restoreEntry(_ id: UUID) {
        do {
            try database().restore(id: id); try reload(); scheduleClassification()
            if deleted?.id == id { deleted = nil }; notice = "已恢复记录"
        } catch { self.error = error.localizedDescription }
    }
    func permanentlyDeleteEntry(_ id: UUID) {
        do {
            try database().permanentlyDelete(id: id); try reload()
            if deleted?.id == id { deleted = nil }; notice = "已永久删除记录"
        } catch { self.error = error.localizedDescription }
    }
    func summaryVersions(range: SummaryRange) -> [RangeSummary] {
        do { return try database().summaries(startDay: range.startDay, endDay: range.endDay) }
        catch { self.error = error.localizedDescription; return [] }
    }
    func summaryHistory(drafts: [String: RangeSummary]) throws -> [SummaryHistoryItem] {
        SummaryHistoryItem.build(saved: try database().allSummaries(), drafts: drafts)
    }
    func saveSummary(_ summary: RangeSummary) -> Bool {
        do { try database().saveSummary(summary); notice = "周报已保存为新版本"; return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func generateSummary(range: SummaryRange, includeAllRecords: Bool, completion: @escaping (RangeSummary) -> Void) {
        guard !busy && !checkingModels else { return }
        let sources = entries, selectedModel = model
        let template = ReportTemplate(opening: reportOpening, closing: reportClosing)
        run { [self] in
            let summary = try await RangeSummaryGenerator(client: client).generate(range: range, entries: sources, model: selectedModel, template: template, includeAllRecords: includeAllRecords) { [self] progress in
                await MainActor.run { self.generationProgress = progress }
            }
            try Task.checkCancellation()
            guard RangeSummaryGenerator.sameSources(range: range, original: sources, current: entries, includeAllRecords: includeAllRecords) else {
                throw JournalError.invalid("生成期间范围内的素材发生变化，请重新生成总结。")
            }
            completion(summary); notice = "周报已生成，请核对并保存"
        }
    }
    func reportArchive() throws -> [ReportArchiveDay] { try database().reportArchive() }
    func versions(day: String) -> [Report] {
        do { return try database().reports(day: day) } catch { self.error = error.localizedDescription; return [] }
    }
    func saveReport(day: String, text: String, sourceFingerprint: String?) -> Bool {
        do { try database().saveReport(Report(day: day, text: text, sourceFingerprint: sourceFingerprint)); notice = "日报已保存为新版本"; return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func refreshModels() async {
        guard !busy && !checkingModels else { return }
        checkingModels = true; serviceStatus = "正在检查本机 Ollama…"
        defer { checkingModels = false; scheduleClassification() }
        do {
            let available = try await client.models()
            models = available.filter(\.isLocal).map(\.name).sorted()
            if !models.contains(model) { model = models.first ?? "" }
            if models.isEmpty {
                serviceStatus = available.isEmpty ? "服务已连接，但尚未下载本地模型" : "服务已连接，仅发现远端模型；请下载本地文本模型"
            } else { serviceStatus = "服务已连接 · \(models.count) 个本地模型" }
            notice = serviceStatus
        } catch {
            models = []; serviceStatus = error.localizedDescription
        }
    }
    func runModelTrial() {
        guard !busy && !checkingModels && !model.isEmpty else { return }
        let selected = model
        modelTrial = nil
        run { [self] in
            let result = try await ModelTrial.run(client: client, model: selected) { [self] detail in
                await MainActor.run { self.generationProgress = detail }
            }
            try Task.checkCancellation()
            modelTrial = result
            notice = "示例试运行完成，没有写入工作记录或日报"
        }
    }
    func cancel() {
        queuePaused = true; scheduled?.cancel(); waitingReport = nil; reportQueued = false; manualClassificationRequested = false
        operation?.cancel()
    }
    func generate(day: String, completion: @escaping (Report) -> Void) {
        guard !checkingModels else { return }
        if busy {
            if isClassifying && !reportQueued {
                waitingReport = { [weak self] in self?.generate(day: day, completion: completion) }
                reportQueued = true; notice = "日报已排队，当前分类完成后优先生成"
            }
            return
        }
        do {
            let sources = try database().reportEntries(day: day)
            guard !sources.isEmpty else { throw JournalError.invalid("该日期没有日报素材，请先勾选“计入日报”。") }
            let selectedModel = model
            let template = ReportTemplate(opening: reportOpening, closing: reportClosing)
            run { [self] in
                let text = try await ReportGenerator(client: client).generate(day: day, entries: sources, model: selectedModel, template: template) { [self] progress in
                    await MainActor.run { self.generationProgress = progress }
                }
                try Task.checkCancellation()
                guard Prompts.sameReportSources(day: day, original: sources, current: try database().reportEntries(day: day)) else {
                    throw JournalError.invalid("生成期间日报素材发生了变化，旧结果已作废，请重新生成。")
                }
                completion(Report(day: day, text: text, sourceFingerprint: ReportFreshness.fingerprint(day: day, entries: sources)))
                notice = "候选日报已生成，请检查后保存"
            }
        } catch { self.error = error.localizedDescription; resumeWork() }
    }
    private func resumeWork() {
        guard !busy else { return }
        let hasCandidates = progress.next(in: entries) != nil
        if !hasCandidates { manualClassificationRequested = false }
        switch ContinuationPolicy.next(reportWaiting: waitingReport != nil, manualRequested: manualClassificationRequested,
                                       paused: queuePaused, powerSaving: powerSaving, hasCandidates: hasCandidates) {
        case .report:
            let report = waitingReport; waitingReport = nil; reportQueued = false; report?()
        case .manualClassification: drainClassification(manual: true)
        case .backgroundClassification: scheduleClassification()
        case .idle: break
        }
    }
    private func run(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        operation = Task { [weak self] in
            defer {
                self?.busy = false; self?.generationProgress = ""; self?.isClassifying = false; self?.operation = nil
                self?.resumeWork()
            }
            do { try await action() }
            catch is CancellationError { self?.notice = "已取消" }
            catch let error as URLError where error.code == .cancelled { self?.notice = "已取消" }
            catch { self?.queuePaused = true; self?.error = error.localizedDescription }
        }
    }
    private func scheduleClassification() {
        scheduled?.cancel()
        guard !powerSaving, !busy, !checkingModels, !queuePaused, !model.isEmpty else { return }
        scheduled = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }
            guard let self, !self.powerSaving, !self.busy, !self.checkingModels, !self.queuePaused, !self.model.isEmpty else { return }
            self.drainClassification(manual: false)
        }
    }
    func classifyPending() {
        guard !busy, !checkingModels else { return }
        progress.reset(); queuePaused = false; manualClassificationRequested = true
        drainClassification(manual: true)
    }
    private func drainClassification(manual: Bool) {
        guard !busy, !checkingModels, progress.next(in: entries) != nil else { return }
        isClassifying = true
        let selectedModel = model
        run { [self] in
            while let original = progress.next(in: entries) {
                try Task.checkCancellation()
                if waitingReport != nil || (!manual && powerSaving) { break }
                progress.markAttempted(original)
                let category = try await client.classify(model: selectedModel, entry: original, categories: categories)
                try Task.checkCancellation()
                guard var current = entries.first(where: { $0.id == original.id }), current == original else { continue }
                // Remember unchanged "未分类" results without updating the timestamp.
                if category != current.category {
                    current.category = category; current.updatedAt = Date()
                    try database().save(current); try reload()
                }
                progress.markAttempted(current)
            }
            notice = powerSaving && !manual ? "省电模式已暂停后续分类" : "本轮分类完成"
        }
    }
    func renameCategory(from: String, to: String) -> Bool {
        do {
            let count = try database().renameCategory(from: from, to: to)
            try reload(); notice = "已更新 \(count) 条记录的分类"; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func importBackup() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "选择工作随记导出的 JSON 备份。同 ID 的本机记录及日报版本将保留。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let alert = NSAlert()
            alert.messageText = "合并此备份到本机？"
            alert.informativeText = "只补回缺失记录和日报版本，不覆盖本机同 ID 内容；同一重复待办系列保留本机版本，避免重复。导入前会自动保存一份本机备份。"
            alert.addButton(withTitle: "合并导入"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let backupDir = root.appendingPathComponent("WorkJournal/Backups")
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            try database().exportBackup().write(to: backupDir.appendingPathComponent("before-import-\(UUID()).json"), options: .atomic)
            let result = try database().importBackup(data)
            try reload(); scheduleClassification()
            notice = "已恢复 \(result.entries) 条记录、\(result.reports) 个日报版本、\(result.summaries) 个范围总结；保留本机重复项 \(result.skipped) 个"
        } catch { self.error = "导入失败：\(error.localizedDescription)" }
    }
    func exportBackup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "工作随记备份-\(Days.key(Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try database().exportBackup()
            try data.write(to: url, options: .atomic); notice = "备份已导出"
        } catch { self.error = error.localizedDescription }
    }
}
