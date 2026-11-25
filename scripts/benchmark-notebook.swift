import Foundation
import JournalCore

// Synthetic fixtures only. Each library is created in a fresh temporary directory and removed.
func measure(_ name: String, count: Int, repeats: Int = 3, _ action: () throws -> Int) rethrows {
    var milliseconds: [Double] = []
    var result = 0
    for _ in 0..<repeats {
        let start = ContinuousClock.now
        result = try action()
        let elapsed = start.duration(to: .now).components
        milliseconds.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
    }
    let median = milliseconds.sorted()[milliseconds.count / 2]
    print("\(name),notes=\(count),median_ms=\(String(format: "%.3f", median)),result=\(result)")
}

for count in [1_000, 10_000] {
    let date = Date(timeIntervalSince1970: 1_795_003_200)
    let content = String(repeating: "synthetic notebook paragraph without result. ", count: 100)
    let notes = (0..<count).map { NoteDocument(title: "Synthetic \($0)", markdown: content, updatedAt: date.addingTimeInterval(Double($0))) }
    let input = UnifiedSearchInput(entries: [Entry(text: "needle", day: "2026-11-18")], notes: notes)
    try measure("search-record-filter", count: count) { try UnifiedSearch.search(.init(text: "needle", kinds: [.record]), in: input).count }
    try measure("search-miss", count: count) { try UnifiedSearch.search(.init(text: "needle"), in: input).count }
    measure("preview-rebuild", count: count) { Dictionary(uniqueKeysWithValues: notes.map { ($0.id, NotebookListPreview.text($0.markdown)) }).count }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-benchmark-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try JournalStore(url: directory.appendingPathComponent("journal.sqlite"))
    _ = try store.importNotebook(NotebookSnapshot(notes: notes))
    var note = try store.notes().first!
    note.markdown = "Synthetic saved change"
    try measure("save-first-after-import", count: count, repeats: 1) {
        note = try store.saveNote(note, expectedRevision: note.revision)
        return note.revision
    }
    try measure("save-consecutive", count: count) {
        note.markdown += " edited"
        note = try store.saveNote(note, expectedRevision: note.revision)
        return note.revision
    }
    try measure("reload-plus-previews", count: count) { Dictionary(uniqueKeysWithValues: try store.notes().map { ($0.id, NotebookListPreview.text($0.markdown)) }).count }
    measure("preview-current-only", count: count) { NotebookListPreview.text(note.markdown).count }
}
