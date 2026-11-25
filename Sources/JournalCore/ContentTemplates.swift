import Foundation

public struct ContentTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var markdown: String
    public init(id: UUID = UUID(), title: String, markdown: String) {
        self.id = id; self.title = title; self.markdown = markdown
    }
    public var isBuiltIn: Bool { ContentTemplates.builtIns.contains { $0.id == id } }
}

public enum ContentTemplates {
    public static let builtIns: [ContentTemplate] = [
        ContentTemplate(id: UUID(uuidString: "32F72C84-2131-4DA7-AC01-000000000001")!, title: "代码 Review", markdown: "# 代码 Review\n\n## 背景与范围\n\n- 变更目标：\n- 相关链接：\n\n## 检查要点\n\n- [ ] 正确性与边界条件\n- [ ] 安全与数据一致性\n- [ ] 测试与回归风险\n\n## 问题与建议\n\n## 后续行动\n\n- [ ] "),
        ContentTemplate(id: UUID(uuidString: "32F72C84-2131-4DA7-AC01-000000000002")!, title: "故障复盘", markdown: "# 故障复盘\n\n## 影响范围\n\n## 时间线\n\n- 发现：\n- 缓解：\n- 恢复：\n\n## 根因与证据\n\n## 处理过程\n\n## 改进措施\n\n- [ ] 行动 / 负责人 / 截止日期\n\n## 验证结果"),
        ContentTemplate(id: UUID(uuidString: "32F72C84-2131-4DA7-AC01-000000000003")!, title: "会议纪要", markdown: "# 会议纪要\n\n- 时间：\n- 参会人：\n- 主题：\n\n## 讨论内容\n\n## 决定\n\n## 待办事项\n\n- [ ] 行动 / 负责人 / 截止日期\n\n## 待确认问题"),
        ContentTemplate(id: UUID(uuidString: "32F72C84-2131-4DA7-AC01-000000000004")!, title: "模块阅读", markdown: "# 模块阅读\n\n## 职责与边界\n\n## 入口与调用关系\n\n## 数据结构与流程\n\n## 关键实现\n\n## 疑问与风险\n\n## 后续探索\n\n- [ ] ")
    ]
    /// Append without trimming or replacing any existing characters.
    public static func appending(_ markdown: String, to current: String) -> String {
        guard !markdown.isEmpty else { return current }
        guard !current.isEmpty else { return markdown }
        let separator = current.hasSuffix("\n\n") ? "" : (current.hasSuffix("\n") ? "\n" : "\n\n")
        return current + separator + markdown
    }
}

/// Preferences store for user-authored reusable content; malformed data is retained for recovery.
public final class TemplateLibraryStore {
    public static let storageKey = "contentTemplates.custom.v1"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() throws -> [ContentTemplate] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        let values = try JSONDecoder().decode([ContentTemplate].self, from: data)
        try Self.validate(values)
        return values
    }
    @discardableResult public func save(_ template: ContentTemplate) throws -> ContentTemplate {
        try Self.validate(template)
        var values = try load()
        if let index = values.firstIndex(where: { $0.id == template.id }) { values[index] = template }
        else { guard values.count < 500 else { throw JournalError.invalid("自定义模板最多保留 500 个。") }; values.append(template) }
        defaults.set(try JSONEncoder().encode(values), forKey: Self.storageKey)
        return template
    }
    public func delete(id: UUID) throws {
        var values = try load(); values.removeAll { $0.id == id }
        defaults.set(try JSONEncoder().encode(values), forKey: Self.storageKey)
    }
    static func validate(_ templates: [ContentTemplate]) throws {
        guard templates.count <= 500, Set(templates.map(\.id)).count == templates.count else {
            throw JournalError.invalid("模板库格式无效或合并后超过 500 个，原数据已保留。")
        }
        for template in templates { try validate(template) }
    }
    private static func validate(_ template: ContentTemplate) throws {
        guard !template.isBuiltIn, !template.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              template.title.count <= 100, !template.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              template.markdown.utf8.count <= 1024 * 1024 else { throw JournalError.invalid("模板需要名称和正文，名称不超过 100 字、正文不超过 1 MiB；内置模板请先创建副本。") }
    }
}
