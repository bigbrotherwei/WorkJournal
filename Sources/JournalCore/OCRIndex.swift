import Foundation
import CryptoKit
import Vision

public enum OCRSourceOwner: String, Codable, Sendable { case record, note }

public struct OCRImageSource: Sendable {
    public let ownerKind: OCRSourceOwner
    public let ownerID: UUID
    public let imageID: UUID
    public let name: String
    public let data: Data
    public let ownerFingerprint: String
    public var key: String { ownerKind.rawValue + ":" + ownerID.uuidString + ":" + imageID.uuidString }
    public let fingerprint: String
    init(ownerKind: OCRSourceOwner, ownerID: UUID, imageID: UUID, name: String, data: Data, ownerFingerprint: String) {
        self.ownerKind = ownerKind; self.ownerID = ownerID; self.imageID = imageID; self.name = name; self.data = data; self.ownerFingerprint = ownerFingerprint
        var hash = SHA256(); hash.update(data: Data(ownerFingerprint.utf8)); hash.update(data: Data(imageID.uuidString.utf8)); hash.update(data: data)
        fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct OCRSearchText: Equatable, Sendable {
    public let ownerKind: OCRSourceOwner
    public let ownerID: UUID
    public let imageID: UUID
    public let ownerFingerprint: String
    public let text: String
}

public enum OCRSourceBuilder {
    private static func hash(_ parts: [String]) -> String {
        SHA256.hash(data: (try? JSONEncoder().encode(parts)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    public static func ownerFingerprint(_ entry: Entry) -> String {
        let images = entry.images.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            $0.id.uuidString + ":" + SHA256.hash(data: $0.data).map { String(format: "%02x", $0) }.joined()
        }
        return hash([entry.id.uuidString, entry.text, entry.deletedAt.map { String($0.timeIntervalSince1970) } ?? ""] + images)
    }
    public static func ownerFingerprint(_ note: NoteDocument) -> String {
        hash([note.id.uuidString, note.title, note.markdown, String(note.revision), note.deletedAt.map { String($0.timeIntervalSince1970) } ?? ""])
    }
    public static func sources(entries: [Entry] = [], notes: [NoteDocument] = [], folders: [NoteFolder] = [], assets: [NoteAsset] = [], cancelled: () -> Bool = { false }) throws -> [OCRImageSource] {
        var sources: [OCRImageSource] = []
        for entry in entries where entry.deletedAt == nil && !entry.images.isEmpty {
            try checkNotebookCancellation(cancelled)
            let fingerprint = ownerFingerprint(entry)
            for image in entry.images {
                try checkNotebookCancellation(cancelled)
                sources.append(OCRImageSource(ownerKind: .record, ownerID: entry.id, imageID: image.id, name: image.name, data: image.data, ownerFingerprint: fingerprint))
            }
        }
        let liveFolders = UnifiedSearch.liveFolderIDs(folders)
        let assetsByOwner = Dictionary(grouping: assets.filter { $0.kind == .image }, by: \.ownerNoteID)
        for note in notes where note.deletedAt == nil && (note.folderID.map(liveFolders.contains) ?? true) {
            try checkNotebookCancellation(cancelled)
            let fingerprint = ownerFingerprint(note)
            for asset in assetsByOwner[note.id] ?? [] where note.markdown.range(of: asset.reference, options: .caseInsensitive) != nil {
                try checkNotebookCancellation(cancelled)
                sources.append(OCRImageSource(ownerKind: .note, ownerID: note.id, imageID: asset.id, name: asset.fileName, data: asset.data, ownerFingerprint: fingerprint))
            }
        }
        return sources.sorted { $0.key < $1.key }
    }
}

public struct OCRIndex: Codable, Equatable, Sendable {
    private struct Record: Codable, Equatable, Sendable {
        let fingerprint: String
        let text: String
    }
    public let version: Int
    private var records: [String: Record]
    public init() { version = 1; records = [:] }
    public var count: Int { records.count }
    public func contains(_ source: OCRImageSource) -> Bool { records[source.key]?.fingerprint == source.fingerprint }
    public mutating func record(source: OCRImageSource, text: String) {
        records[source.key] = Record(fingerprint: source.fingerprint, text: String(text.prefix(100_000)))
    }
    public mutating func prune(currentSources: [OCRImageSource]) {
        let fingerprints = Dictionary(currentSources.map { ($0.key, $0.fingerprint) }, uniquingKeysWith: { _, last in last })
        records = records.filter { fingerprints[$0.key] == $0.value.fingerprint }
    }
    public func validatedTexts(currentSources: [OCRImageSource]) -> [OCRSearchText] {
        currentSources.compactMap { source in
            guard let record = records[source.key], record.fingerprint == source.fingerprint, !record.text.isEmpty else { return nil }
            return OCRSearchText(ownerKind: source.ownerKind, ownerID: source.ownerID, imageID: source.imageID, ownerFingerprint: source.ownerFingerprint, text: record.text)
        }
    }
}

public struct OCRCacheStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> OCRIndex {
        guard FileManager.default.fileExists(atPath: url.path) else { return OCRIndex() }
        let index = try JSONDecoder().decode(OCRIndex.self, from: Data(contentsOf: url))
        guard index.version == 1 else { throw JournalError.invalid("图片文字索引版本不受支持，请重新识别。") }
        return index
    }
    public func save(_ index: OCRIndex) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(index).write(to: url, options: .atomic)
    }
}

public struct OCRBatchProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let name: String
    public init(completed: Int = 0, total: Int = 0, name: String = "") { self.completed = completed; self.total = total; self.name = name }
}
public struct OCRBatchOutput: Sendable {
    public let index: OCRIndex
    public let errors: [String]
    public let recognized: Int
    public let reused: Int
}

public enum OCRBatchProcessor {
    public static func process(sources: [OCRImageSource], index: OCRIndex, recognize: (Data) throws -> String, cancelled: () -> Bool = { false }, progress: (OCRBatchProgress) -> Void = { _ in }, checkpoint: (OCRIndex) throws -> Void = { _ in }) throws -> OCRBatchOutput {
        var result = index; result.prune(currentSources: sources)
        var errors: [String] = []; var recognized = 0; var reused = 0
        progress(OCRBatchProgress(total: sources.count))
        for (offset, source) in sources.enumerated() {
            try checkNotebookCancellation(cancelled)
            progress(OCRBatchProgress(completed: offset, total: sources.count, name: source.name))
            if result.contains(source) { reused += 1 }
            else {
                do {
                    let text = try recognize(source.data)
                    try checkNotebookCancellation(cancelled)
                    result.record(source: source, text: text); recognized += 1
                } catch is CancellationError { throw CancellationError() }
                catch { try checkNotebookCancellation(cancelled); errors.append(source.name + "：" + error.localizedDescription) }
            }
            try checkpoint(result)
            progress(OCRBatchProgress(completed: offset + 1, total: sources.count, name: source.name))
        }
        try checkNotebookCancellation(cancelled)
        return OCRBatchOutput(index: result, errors: errors, recognized: recognized, reused: reused)
    }
}

/// Vision requests are cancelled from another executor, so guard their lifetime with a lock.
private final class OCRVisionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var cancelled = false
    func install(_ request: VNRequest?) {
        lock.lock(); self.request = request; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { request?.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let current = request; lock.unlock()
        current?.cancel()
    }
}

/// The connection, image bytes, Vision execution and cache I/O never run on the main actor.
public actor LocalOCRWorker {
    private let databaseURL: URL
    private let cache: OCRCacheStore
    private var store: JournalStore?
    public init(databaseURL: URL, cacheURL: URL) { self.databaseURL = databaseURL; cache = OCRCacheStore(url: cacheURL) }
    private func database() throws -> JournalStore {
        try Task.checkCancellation()
        if let store { return store }
        let opened = try JournalStore(url: databaseURL); store = opened; return opened
    }
    private func currentSources() throws -> [OCRImageSource] {
        let db = try database()
        return try db.transaction(beginSQL: "BEGIN DEFERRED") {
        let entries = try db.entries()
        let notes = try db.notes()
        let folders = try db.noteFolders()
        var assets: [NoteAsset] = []
        for note in notes {
            try Task.checkCancellation()
            assets.append(contentsOf: try db.noteAssets(noteID: note.id).filter { $0.kind == .image })
        }
        return try OCRSourceBuilder.sources(entries: entries, notes: notes, folders: folders, assets: assets, cancelled: { Task.isCancelled })
        }
    }
    public func validatedTexts() throws -> [OCRSearchText] {
        let index = try cache.load()
        guard index.count > 0 else { return [] }
        return index.validatedTexts(currentSources: try currentSources())
    }
    public func run(progress: @escaping @Sendable (OCRBatchProgress) -> Void = { _ in }) async throws -> OCRBatchOutput {
        let cancellation = OCRVisionCancellation()
        return try await withTaskCancellationHandler {
            let sources = try currentSources()
            // A manual rebuild can recover a damaged derived cache without changing original data.
            let existing = (try? cache.load()) ?? OCRIndex()
            var output = try OCRBatchProcessor.process(sources: sources, index: existing, recognize: { data in
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                request.usesLanguageCorrection = true
                cancellation.install(request); defer { cancellation.install(nil) }
                try Task.checkCancellation()
                try VNImageRequestHandler(data: data, options: [:]).perform([request])
                try Task.checkCancellation()
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            }, cancelled: { Task.isCancelled }, progress: progress, checkpoint: { try cache.save($0) })
            var refreshed = output.index
            refreshed.prune(currentSources: try currentSources())
            try Task.checkCancellation()
            try cache.save(refreshed)
            output = OCRBatchOutput(index: refreshed, errors: output.errors, recognized: output.recognized, reused: output.reused)
            return output
        } onCancel: { cancellation.cancel() }
    }
}
