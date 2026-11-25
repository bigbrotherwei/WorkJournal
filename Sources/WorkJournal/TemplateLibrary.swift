import Foundation
import SwiftUI
import JournalCore

@MainActor final class TemplateLibrary: ObservableObject {
    static let shared = TemplateLibrary()
    @Published private(set) var custom: [ContentTemplate] = []
    @Published var error: String?
    private let store: TemplateLibraryStore
    var all: [ContentTemplate] { ContentTemplates.builtIns + custom }
    init(store: TemplateLibraryStore = TemplateLibraryStore()) { self.store = store; reload() }
    func reload() { do { custom = try store.load(); error = nil } catch { self.error = "模板库无法读取，现有数据已保留：" + error.localizedDescription } }
    @discardableResult func save(_ template: ContentTemplate) -> Bool {
        do { try store.save(template); reload(); return true } catch { self.error = error.localizedDescription; return false }
    }
    func delete(_ id: UUID) { do { try store.delete(id: id); reload() } catch { self.error = error.localizedDescription } }
}
