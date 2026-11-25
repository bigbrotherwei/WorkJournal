import Foundation
import Testing
@testable import JournalCore

struct UnifiedSearchTests {
    @Test func chineseSearchCoversAllOwnersAndDistinguishesTasks() throws {
        let record = Entry(text: "处理中文检索", day: "2026-11-18")
        var task = Entry(text: "跟进中文检索", day: "2026-11-18"); task.status = .pending
        let report = Report(day: "2026-11-18", text: "## 中文检索完成")
        let summary = RangeSummary(startDay: "2026-11-16", endDay: "2026-11-22", text: "中文检索周报", sourceFingerprint: "test")
        let titleNote = NoteDocument(title: "中文检索设计", markdown: "另一个正文")
        let bodyNote = NoteDocument(title: "其他标题", markdown: "正文中的中文检索")
        let results = try UnifiedSearch.search(.init(text: "  中文检索  "), in: .init(entries: [record, task], reports: [report], summaries: [summary], notes: [titleNote, bodyNote]))
        #expect(results.count == 6)
        #expect(Set(results.map(\.kind)) == Set([.record, .task, .dailyReport, .rangeSummary, .note]))
        #expect(results.first(where: { $0.ownerID == titleNote.id })?.snippet.contains("中文检索") == true)
        #expect(results.allSatisfy { $0.query == "中文检索" })
    }

    @Test func excludesTrashAndAppliesDateKindAndDescendantFolderFilters() throws {
        let folder = NoteFolder(name: "工程")
        let child = NoteFolder(parentID: folder.id, name: "子目录")
        var trash = NoteFolder(name: "已删除"); trash.deletedAt = Date()
        let live = NoteDocument(folderID: child.id, title: "命中", updatedAt: Date(timeIntervalSince1970: 1_795_003_200))
        let deletedChild = NoteDocument(folderID: trash.id, title: "命中")
        var deleted = NoteDocument(title: "命中"); deleted.deletedAt = Date()
        var entry = Entry(text: "命中", day: "2026-11-18"); entry.deletedAt = Date()
        let summary = RangeSummary(startDay: "2026-11-16", endDay: "2026-11-22", text: "命中", sourceFingerprint: "test")
        let input = UnifiedSearchInput(entries: [entry], summaries: [summary], notes: [live, deletedChild, deleted], folders: [folder, child, trash])
        #expect(try UnifiedSearch.search(.init(text: "命中"), in: input).count == 2)
        #expect(try UnifiedSearch.search(.init(text: "命中", folderID: folder.id), in: input).map(\.ownerID) == [live.id])
        #expect(try UnifiedSearch.search(.init(text: "命中", kinds: [.rangeSummary], startDay: "2026-11-18", endDay: "2026-11-18"), in: input).map(\.ownerID) == [summary.id])
        #expect(try UnifiedSearch.search(.init(text: "命中", startDay: "2026-12-01"), in: input).isEmpty)
        #expect(try UnifiedSearch.search(.init(text: "命中", startDay: "2026-11-20", endDay: "2026-11-01"), in: input).isEmpty)
    }

    @Test func emptyQueryOnlyListsContentWithExplicitFilter() throws {
        let input = UnifiedSearchInput(entries: [Entry(text: "one", day: "2026-11-18"), Entry(text: "two", day: "2026-11-17")])
        #expect(try UnifiedSearch.search(.init(text: " \n "), in: input).isEmpty)
        #expect(try UnifiedSearch.search(.init(text: "", startDay: "2026-11-18"), in: input).map(\.day) == ["2026-11-18"])
    }

    @Test func snippetsAreBoundedAroundHitAndOrderingIsStable() throws {
        var a = Entry(text: String(repeating: "前", count: 500) + "检索命中" + String(repeating: "后", count: 500), day: "2026-11-18")
        a.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!; a.createdAt = .distantPast; a.updatedAt = .distantPast
        var b = a; b.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = try UnifiedSearch.search(.init(text: "检索命中"), in: .init(entries: [b, a]))
        let second = try UnifiedSearch.search(.init(text: "检索命中"), in: .init(entries: [a, b]))
        #expect(first == second)
        #expect(first.map(\.ownerID) == [a.id, b.id])
        #expect(first.allSatisfy { $0.snippet.count <= 180 && $0.snippet.contains("检索命中") })
    }

    @Test func cancellationDoesNotReturnPartialResults() throws {
        #expect(throws: CancellationError.self) {
            try UnifiedSearch.search(.init(text: "内容"), in: .init(entries: [Entry(text: "内容", day: "2026-11-18")]), cancelled: { true })
        }
    }
}

@MainActor struct UnifiedSearchSessionTests {
    @Test func supersededAndClosedSearchNeverPublishesOldResults() async throws {
        let session = UnifiedSearchSession(debounceNanoseconds: 0)
        let gate = SearchTestGate()
        let input = UnifiedSearchInput(entries: [Entry(text: "旧查询", day: "2026-11-18"), Entry(text: "新查询", day: "2026-11-18")])
        session.submit(.init(text: "旧查询"), in: input, loadOCR: { await gate.wait(); return [] })
        while !(await gate.started) { await Task.yield() }
        session.submit(.init(text: "新查询"), in: input)
        while session.isSearching { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(session.results.map(\.title) == ["新查询"])
        await gate.release()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(session.results.map(\.title) == ["新查询"])
        session.submit(.init(text: "旧查询"), in: input)
        session.cancel()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(session.results.isEmpty)
        #expect(!session.isSearching)
    }
}

private actor SearchTestGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

struct UnifiedSearchStoreTests {
    @Test func loadsAllReportVersionsAndNoTrashedOwners() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("search-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try JournalStore(url: directory.appendingPathComponent("journal.sqlite"))
        let entry = Entry(text: "已删除", day: "2026-11-18"); try store.save(entry); try store.delete(id: entry.id)
        try store.saveReport(Report(day: "2026-11-18", text: "第一版"))
        try store.saveReport(Report(day: "2026-11-18", text: "第二版"))
        let note = try store.saveNote(NoteDocument(title: "已删除")); try store.deleteNote(id: note.id)
        let input = try store.unifiedSearchInput()
        #expect(input.entries.isEmpty)
        #expect(input.notes.isEmpty)
        #expect(Set(input.reports.map(\.text)) == ["第一版", "第二版"])
    }
}
