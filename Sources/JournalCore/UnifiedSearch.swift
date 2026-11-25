import Foundation

public enum UnifiedSearchKind: String, CaseIterable, Codable, Hashable, Sendable {
    case record, task, dailyReport, rangeSummary, note
    public var title: String {
        switch self {
        case .record: return "记录"
        case .task: return "待办"
        case .dailyReport: return "日报"
        case .rangeSummary: return "周报 / 范围总结"
        case .note: return "笔记"
        }
    }
    public var symbol: String {
        switch self {
        case .record: return "text.alignleft"
        case .task: return "checkmark.circle"
        case .dailyReport: return "doc.text"
        case .rangeSummary: return "calendar"
        case .note: return "book.closed"
        }
    }
}

public struct UnifiedSearchQuery: Equatable, Hashable, Sendable {
    public var text: String
    public var kinds: Set<UnifiedSearchKind>
    public var startDay: String?
    public var endDay: String?
    public var folderID: UUID?
    public init(text: String = "", kinds: Set<UnifiedSearchKind> = [], startDay: String? = nil, endDay: String? = nil, folderID: UUID? = nil) {
        self.text = text; self.kinds = kinds; self.startDay = startDay; self.endDay = endDay; self.folderID = folderID
    }
    public var hasFilters: Bool { !kinds.isEmpty || startDay != nil || endDay != nil || folderID != nil }
}

public struct UnifiedSearchInput: Equatable, Sendable {
    public var entries: [Entry]
    public var reports: [Report]
    public var summaries: [RangeSummary]
    public var notes: [NoteDocument]
    public var folders: [NoteFolder]
    public var ocrTexts: [OCRSearchText]
    public init(entries: [Entry] = [], reports: [Report] = [], summaries: [RangeSummary] = [], notes: [NoteDocument] = [], folders: [NoteFolder] = [], ocrTexts: [OCRSearchText] = []) {
        self.entries = entries; self.reports = reports; self.summaries = summaries; self.notes = notes; self.folders = folders; self.ocrTexts = ocrTexts
    }
}

public struct UnifiedSearchResult: Identifiable, Equatable, Sendable {
    public var id: String { kind.rawValue + ":" + ownerID.uuidString }
    public let kind: UnifiedSearchKind
    public let ownerID: UUID
    public let title: String
    public let snippet: String
    public let day: String
    public let endDay: String
    public let updatedAt: Date
    public let folderID: UUID?
    public let query: String
    public let isOCRMatch: Bool
}

public enum UnifiedSearch {
    public static func search(_ query: UnifiedSearchQuery, in input: UnifiedSearchInput, cancelled: () -> Bool = { false }) throws -> [UnifiedSearchResult] {
        try checkNotebookCancellation(cancelled)
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || query.hasFilters else { return [] }
        if let first = query.startDay, let last = query.endDay, first > last { return [] }
        let liveFolders = liveFolderIDs(input.folders)
        let selectedFolders = query.folderID.map { descendantFolders(of: $0, folders: input.folders).intersection(liveFolders) }
        let ocrByOwner = Dictionary(grouping: input.ocrTexts, by: { $0.ownerID })
        var results: [UnifiedSearchResult] = []
        func acceptsKind(_ kind: UnifiedSearchKind) -> Bool {
            (query.kinds.isEmpty || query.kinds.contains(kind)) && (selectedFolders == nil || kind == .note)
        }
        func add(kind: UnifiedSearchKind, ownerID: UUID, title: String, body: String, day: String, endDay: String? = nil, updatedAt: Date, folderID: UUID? = nil, ownerFingerprint: () -> String = { "" }) {
            let lastDay = endDay ?? day
            guard query.kinds.isEmpty || query.kinds.contains(kind),
                  query.startDay.map({ lastDay >= $0 }) ?? true,
                  query.endDay.map({ day <= $0 }) ?? true else { return }
            if let selectedFolders { guard kind == .note, folderID.map(selectedFolders.contains) == true else { return } }
            var matchedText = body
            var isOCR = false
            if !text.isEmpty {
                if contains(body, text) { matchedText = body }
                else if contains(title, text) { matchedText = title }
                else {
                    let candidateTexts = ocrByOwner[ownerID] ?? []
                    guard !candidateTexts.isEmpty else { return }
                    let fingerprint = ownerFingerprint()
                    guard let match = candidateTexts.first(where: { $0.ownerFingerprint == fingerprint && $0.ownerKind == (kind == .note ? .note : .record) && contains($0.text, text) }) else { return }
                    matchedText = match.text; isOCR = true
                }
            }
            results.append(UnifiedSearchResult(kind: kind, ownerID: ownerID, title: String(title.prefix(100)), snippet: snippet(matchedText, matching: text), day: day, endDay: lastDay, updatedAt: updatedAt, folderID: folderID, query: text, isOCRMatch: isOCR))
        }
        for entry in input.entries where entry.deletedAt == nil {
            try checkNotebookCancellation(cancelled)
            let kind: UnifiedSearchKind = entry.status == .none ? .record : .task
            guard acceptsKind(kind) else { continue }
            let body = entry.plainText
            let title = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? "图片记录"
            add(kind: kind, ownerID: entry.id, title: title, body: body, day: entry.day, updatedAt: entry.updatedAt, ownerFingerprint: { OCRSourceBuilder.ownerFingerprint(entry) })
        }
        for report in input.reports where acceptsKind(.dailyReport) {
            try checkNotebookCancellation(cancelled)
            add(kind: .dailyReport, ownerID: report.id, title: report.day + " 日报", body: report.text, day: report.day, updatedAt: report.createdAt)
        }
        for summary in input.summaries where acceptsKind(.rangeSummary) {
            try checkNotebookCancellation(cancelled)
            add(kind: .rangeSummary, ownerID: summary.id, title: summary.startDay + " — " + summary.endDay + " 总结", body: summary.text, day: summary.startDay, endDay: summary.endDay, updatedAt: summary.createdAt)
        }
        // DateFormatter setup is much more expensive than formatting one day. Reuse it
        // within this background scan, with the same calendar/locale/timezone as Days.key.
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = .current; dayFormatter.dateFormat = "yyyy-MM-dd"
        for note in input.notes where acceptsKind(.note) && note.deletedAt == nil && (note.folderID.map(liveFolders.contains) ?? true) {
            try checkNotebookCancellation(cancelled)
            add(kind: .note, ownerID: note.id, title: note.title, body: note.markdown, day: dayFormatter.string(from: note.updatedAt), updatedAt: note.updatedAt, folderID: note.folderID, ownerFingerprint: { OCRSourceBuilder.ownerFingerprint(note) })
        }
        try checkNotebookCancellation(cancelled)
        return results.sorted {
            if $0.day != $1.day { return $0.day > $1.day }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    static func contains(_ body: String, _ query: String) -> Bool {
        body.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_CN")) != nil
    }

    /// Slices near the match before whitespace cleanup so large notes do not allocate a second full body.
    static func snippet(_ text: String, matching query: String, limit: Int = 180) -> String {
        let match = query.isEmpty ? nil : text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_CN"))
        let anchor = match?.lowerBound ?? text.startIndex
        let start = text.index(anchor, offsetBy: -45, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: limit - 2, limitedBy: text.endIndex) ?? text.endIndex
        let clean = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + clean + (end < text.endIndex ? "…" : "")
    }

    static func liveFolderIDs(_ folders: [NoteFolder]) -> Set<UUID> {
        var live = Set(folders.filter { $0.deletedAt == nil }.map(\.id))
        var changed = true
        while changed {
            changed = false
            for folder in folders where live.contains(folder.id) {
                if let parent = folder.parentID, !live.contains(parent) { live.remove(folder.id); changed = true }
            }
        }
        return live
    }

    static func descendantFolders(of root: UUID, folders: [NoteFolder]) -> Set<UUID> {
        var found: Set<UUID> = [root]
        var changed = true
        while changed {
            changed = false
            for folder in folders where folder.parentID.map(found.contains) == true {
                if found.insert(folder.id).inserted { changed = true }
            }
        }
        return found
    }
}

extension JournalStore {
    /// Read all saved report versions and live owners within one SQLite snapshot.
    public func unifiedSearchInput(ocrTexts: [OCRSearchText] = []) throws -> UnifiedSearchInput {
        try transaction(beginSQL: "BEGIN DEFERRED") {
            UnifiedSearchInput(entries: try entries(), reports: try read("reports", as: Report.self, cancelled: { Task.isCancelled }), summaries: try allSummaries(), notes: try notes(), folders: try noteFolders(), ocrTexts: ocrTexts)
        }
    }
}

import Combine

@MainActor public final class UnifiedSearchSession: ObservableObject {
    @Published public private(set) var results: [UnifiedSearchResult] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var error: String?
    private let debounceNanoseconds: UInt64
    private var generation = UUID()
    private var operation: Task<Void, Never>?
    public init(debounceNanoseconds: UInt64 = 150_000_000) { self.debounceNanoseconds = debounceNanoseconds }
    public func submit(_ query: UnifiedSearchQuery, in input: UnifiedSearchInput, loadOCR: (@Sendable () async throws -> [OCRSearchText])? = nil) {
        cancel()
        guard !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || query.hasFilters else { return }
        let token = UUID(); generation = token; isSearching = true
        operation = Task {
            do {
                if debounceNanoseconds > 0 { try await Task.sleep(nanoseconds: debounceNanoseconds) }
                var snapshot = input
                var warning: String?
                if let loadOCR, !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do { snapshot.ocrTexts = try await loadOCR() }
                    catch is CancellationError { throw CancellationError() }
                    catch { warning = "图片文字索引暂不可用：" + error.localizedDescription }
                }
                try Task.checkCancellation()
                let searchInput = snapshot
                let scan = Task.detached(priority: .userInitiated) {
                    try UnifiedSearch.search(query, in: searchInput, cancelled: { Task.isCancelled })
                }
                let found = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
                try Task.checkCancellation()
                guard generation == token else { return }
                results = found; error = warning; isSearching = false; operation = nil
            } catch is CancellationError {
                if generation == token { isSearching = false; operation = nil }
            } catch {
                guard generation == token else { return }
                self.error = error.localizedDescription; results = []; isSearching = false; operation = nil
            }
        }
    }
    public func cancel() {
        generation = UUID(); operation?.cancel(); operation = nil; results = []; error = nil; isSearching = false
    }
}
