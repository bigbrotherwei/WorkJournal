import Foundation
import Testing
@testable import JournalCore

struct ContentTemplateTests {
    @Test func builtInsCoverFourWorkflowsAndAppendPreservesExistingText() {
        #expect(ContentTemplates.builtIns.map(\.title) == ["代码 Review", "故障复盘", "会议纪要", "模块阅读"])
        #expect(Set(ContentTemplates.builtIns.map(\.id)).count == 4)
        #expect(ContentTemplates.appending("## 模板", to: "original\n") == "original\n\n## 模板")
        #expect(ContentTemplates.appending("## 模板", to: "") == "## 模板")
        #expect(ContentTemplates.appending("", to: "original\n") == "original\n")
    }
    @Test func customTemplatesSurviveReloadEditAndDeleteWithoutChangingBuiltIns() throws {
        let suite = "ContentTemplateTests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TemplateLibraryStore(defaults: defaults)
        let template = try store.save(ContentTemplate(title: "自定义", markdown: "## 记录"))
        #expect(try TemplateLibraryStore(defaults: defaults).load() == [template])
        var changed = template; changed.title = "改名"; changed.markdown += "\n正文"
        _ = try store.save(changed)
        #expect(try store.load() == [changed])
        #expect(throws: (any Error).self) { try store.save(ContentTemplates.builtIns[0]) }
        try store.delete(id: template.id)
        #expect(try store.load().isEmpty)
    }
    @Test func invalidStoredDataIsNotOverwrittenAndInvalidTemplateIsRejected() throws {
        let suite = "ContentTemplateTests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TemplateLibraryStore(defaults: defaults)
        #expect(throws: (any Error).self) { try store.save(ContentTemplate(title: " ", markdown: "text")) }
        defaults.set(Data("broken".utf8), forKey: TemplateLibraryStore.storageKey)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.save(ContentTemplate(title: "New", markdown: "Body")) }
        #expect(defaults.data(forKey: TemplateLibraryStore.storageKey) == Data("broken".utf8))
    }
}
