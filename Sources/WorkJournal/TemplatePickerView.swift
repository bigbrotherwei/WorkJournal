import SwiftUI
import JournalCore

/// Shared by quick capture and notes. The caller decides where to append the returned Markdown.
struct TemplatePickerView: View {
    var onInsert: (String) -> Void
    @ObservedObject private var library = TemplateLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selectedID: UUID? = ContentTemplates.builtIns.first?.id
    @ViewState private var editing: ContentTemplate?
    private var selected: ContentTemplate? { library.all.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("内容模板").font(.title2.bold())
                Spacer()
                Button("新建模板") { editing = ContentTemplate(title: "", markdown: "") }
                Button("完成") { dismiss() }
            }
            Text("插入到现有内容末尾。自定义模板仅保存在这台 Mac 的偏好设置中。").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(library.all) { template in
                            Button { selectedID = template.id } label: {
                                HStack { Text(template.title); Spacer(); if template.isBuiltIn { Text("内置").font(.caption2).foregroundStyle(.secondary) } }
                                    .padding(10).contentShape(Rectangle())
                            }.buttonStyle(.plain).background(selectedID == template.id ? JournalTheme.soft : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }.frame(width: 185)
                Divider()
                ScrollView {
                    Text(selected?.markdown ?? "选择模板预览内容").font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.background(JournalTheme.paper, in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                if let selected {
                    Button("复制为自定义") { editing = ContentTemplate(title: selected.title + " 副本", markdown: selected.markdown) }
                    if !selected.isBuiltIn {
                        Button("编辑") { editing = selected }
                        Button("删除", role: .destructive) { library.delete(selected.id); selectedID = ContentTemplates.builtIns.first?.id }
                    }
                    Spacer()
                    Button("插入模板") { onInsert(selected.markdown); dismiss() }.buttonStyle(JournalPrimaryButtonStyle())
                }
            }
        }.padding(24).frame(width: 740, height: 550).background(JournalTheme.canvas)
            .onAppear { library.reload() }
            .sheet(item: $editing) { template in TemplateEditView(template: template) { value in if library.save(value) { selectedID = value.id; return true }; return false } }
            .alert("模板操作未完成", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) { Button("知道了") { library.error = nil } } message: { Text(library.error ?? "") }
    }
}

private struct TemplateEditView: View {
    @ViewState var template: ContentTemplate
    var save: (ContentTemplate) -> Bool
    @Environment(\.dismiss) private var dismiss
    @ViewState private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑自定义模板").font(.title2.bold())
            TextField("模板名称", text: $template.title).textFieldStyle(.roundedBorder)
            TextEditor(text: $template.markdown).font(.system(.body, design: .monospaced)).scrollContentBackground(.hidden).padding(8).background(JournalTheme.paper, in: RoundedRectangle(cornerRadius: 10))
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            HStack { Button("取消") { dismiss() }; Spacer(); Button("保存") { if save(template) { dismiss() } else { failure = TemplateLibrary.shared.error ?? "模板保存失败，请重试。" } }.buttonStyle(JournalPrimaryButtonStyle()).disabled(template.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || template.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 620, height: 480).background(JournalTheme.canvas)
    }
}
