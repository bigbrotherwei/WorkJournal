import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ImageIO
import JournalCore

struct NoteEditorUpdate: Equatable, Sendable {
    let noteID: UUID
    let sessionID: UUID
    let sequence: Int
    let markdown: String
}

enum NoteEditorError: LocalizedError {
    case unavailable, changedSession, timeout, invalidMessage, imageUnavailable
    var errorDescription: String? {
        switch self {
        case .unavailable: return "笔记编辑器尚未准备好。"
        case .changedSession: return "笔记编辑会话已变化，请重试。"
        case .timeout: return "编辑器仍在等待输入完成，请完成输入法组合后重试保存。"
        case .invalidMessage: return "编辑器返回了无效内容，现有草稿已保留。"
        case .imageUnavailable: return "图片无法读取，或图片格式不受支持。"
        }
    }
}

/// Own one controller per notebook surface. Await flush before changing selection/unmounting.
/// Ordinary load calls for the same note intentionally ignore save echoes; force reload is explicit.
@MainActor
final class NoteEditorController: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var isReady = false
    private(set) var sessionID = UUID()
    private(set) var latestUpdate: NoteEditorUpdate?
    var onChange: ((NoteEditorUpdate) -> Void)?
    var onError: ((String) -> Void)?
    var onSaveRequested: (() -> Void)?
    var assetProvider: ((UUID, UUID) -> NoteAsset?)?
    var importImage: ((UUID, Data, String, String) async throws -> NoteAsset)?
    var openAsset: ((UUID, UUID) -> Void)?
    var openNote: ((UUID) -> Void)?

    private var editorWebView: WKWebView?
    private var resourceURL: URL?
    private var booted = false
    private var initializing = false
    private var pendingImports = Set<String>()
    private var flushTasks: [UUID: CheckedContinuation<NoteEditorUpdate, Error>] = [:]
    private let maxTextBytes = 8 * 1024 * 1024
    private let maxSequence = 9_007_199_254_740_990

    override init() { super.init() }

    func load(noteID: UUID, markdown: String, revision: Int, force: Bool = false) {
        guard force || latestUpdate?.noteID != noteID else { return }
        guard markdown.utf8.count <= maxTextBytes else { onError?("笔记超过 8 MiB，无法载入编辑器。"); return }
        cancelFlushes(NoteEditorError.changedSession)
        sessionID = UUID()
        isReady = false
        initializing = false
        pendingImports.removeAll()
        latestUpdate = NoteEditorUpdate(noteID: noteID, sessionID: sessionID, sequence: max(0, min(revision, maxSequence - 1)), markdown: markdown)
        initializeIfPossible()
    }

    /// Waits for ready and IME composition, then obtains the authoritative complete document.
    /// A bounded failure leaves the current session/draft intact instead of reporting success.
    func flush() async throws -> NoteEditorUpdate {
        guard let expected = latestUpdate else { throw NoteEditorError.unavailable }
        let deadline = Date().addingTimeInterval(10)
        while !isReady {
            guard sessionID == expected.sessionID else { throw NoteEditorError.changedSession }
            guard Date() < deadline else { throw NoteEditorError.timeout }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        guard let webView = editorWebView else { throw NoteEditorError.unavailable }
        let requestID = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            flushTasks[requestID] = continuation
            webView.callAsyncJavaScript("return await window.notebook.flush(payload)", arguments: ["payload": identity(expected)], in: nil, in: .page) { [weak self] result in
                guard let self, let completion = self.flushTasks.removeValue(forKey: requestID) else { return }
                guard self.sessionID == expected.sessionID else { completion.resume(throwing: NoteEditorError.changedSession); return }
                switch result {
                case .success(let value):
                    guard let body = value as? [String: Any], let update = self.decodeUpdate(body) else { completion.resume(throwing: NoteEditorError.invalidMessage); return }
                    self.accept(update)
                    completion.resume(returning: update)
                case .failure(let error): completion.resume(throwing: error)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, let completion = self.flushTasks.removeValue(forKey: requestID) else { return }
                completion.resume(throwing: NoteEditorError.timeout)
            }
        }
    }

    func command(_ name: String) {
        guard isReady, ["source", "document", "bold", "italic", "underline", "strike", "code", "subscript", "superscript", "bulletList", "orderedList", "taskList", "blockquote", "codeBlock", "horizontalRule", "undo", "redo", "image", "link", "clear", "imageEdit"].contains(name) else { return }
        editorWebView?.callAsyncJavaScript("return await window.notebook.command(name)", arguments: ["name": name], in: nil, in: .page, completionHandler: nil)
    }

    fileprivate func makeWebView() -> WKWebView {
        if let editorWebView { return editorWebView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(NoteAssetSchemeHandler(owner: self), forURLScheme: "workjournal-asset")
        configuration.userContentController.add(NoteEditorMessageProxy(owner: self), name: "notebook")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = false
        view.setValue(false, forKey: "drawsBackground")
        editorWebView = view
        resourceURL = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "NotebookEditor")
        if let url = resourceURL { view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        else { onError?("安装包中缺少离线笔记编辑器，请重新安装应用。"); }
        return view
    }

    private func identity(_ update: NoteEditorUpdate) -> [String: Any] {
        ["noteID": update.noteID.uuidString.lowercased(), "sessionID": update.sessionID.uuidString.lowercased(), "sequence": update.sequence]
    }

    private func initializeIfPossible() {
        guard booted, !initializing, let update = latestUpdate else { return }
        initializing = true
        var payload = identity(update)
        payload["markdown"] = update.markdown
        editorWebView?.callAsyncJavaScript("window.notebook.initialize(payload)", arguments: ["payload": payload], in: nil, in: .page) { [weak self] result in
            guard let self, self.sessionID == update.sessionID else { return }
            self.initializing = false
            if case .failure(let error) = result { self.onError?("笔记编辑器载入失败：\(error.localizedDescription)") }
        }
    }

    fileprivate func received(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.standardizedFileURL == resourceURL?.standardizedFileURL,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "boot" { booted = true; initializeIfPossible(); return }
        guard validIdentity(body), let current = latestUpdate else { return }
        switch type {
        case "ready": isReady = true
        case "change": if let update = decodeUpdate(body) { accept(update) }
        case "error": if let text = body["message"] as? String, text.utf8.count <= 4096 { onError?(text) }
        case "saveRequested": onSaveRequested?()
        case "openURL":
            guard let value = body["url"] as? String, value.count <= 4096, let url = URL(string: value) else { return }
            if let linkedNoteID = noteIdentity(url) { openNote?(linkedNoteID) }
            else if let ids = assetIdentity(url), ids.0 == current.noteID { openAsset?(ids.0, ids.1) }
            else if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil { NSWorkspace.shared.open(url) }
        case "pickImage", "importImage":
            guard let token = body["token"] as? String, UUID(uuidString: token) != nil, pendingImports.count < 20, !pendingImports.contains(token) else { return }
            pendingImports.insert(token)
            if type == "pickImage" { pickImage(token: token, update: current) }
            else {
                guard let encoded = body["data"] as? String, encoded.utf8.count <= 24 * 1024 * 1024,
                      let bytes = Data(base64Encoded: encoded), bytes.count <= 16 * 1024 * 1024,
                      let name = body["fileName"] as? String, name.utf8.count <= 1024 else {
                    imageResult(token: token, update: current, error: NoteEditorError.imageUnavailable.localizedDescription); return
                }
                importBytes(bytes, name: name, token: token, update: current)
            }
        default: break
        }
    }

    private func validIdentity(_ body: [String: Any]) -> Bool {
        guard let current = latestUpdate,
              let note = body["noteID"] as? String, UUID(uuidString: note) == current.noteID,
              let session = body["sessionID"] as? String, UUID(uuidString: session) == sessionID,
              let number = body["sequence"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        let sequence = number.doubleValue
        return sequence.isFinite && sequence.rounded() == sequence && sequence >= Double(current.sequence) && sequence <= Double(maxSequence)
    }

    private func decodeUpdate(_ body: [String: Any]) -> NoteEditorUpdate? {
        guard validIdentity(body), let current = latestUpdate, let sequence = body["sequence"] as? Int,
              let markdown = body["markdown"] as? String, markdown.utf8.count <= maxTextBytes else { return nil }
        // A sequence identifies exactly one immutable document, including flush echoes.
        guard sequence > current.sequence || markdown == current.markdown else { return nil }
        return NoteEditorUpdate(noteID: current.noteID, sessionID: sessionID, sequence: sequence, markdown: markdown)
    }

    private func accept(_ update: NoteEditorUpdate) {
        let changed = latestUpdate != update
        latestUpdate = update
        if changed { onChange?(update) }
    }

    private func pickImage(token: String, update: NoteEditorUpdate) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "图片会保存在本笔记中，不会上传。"
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { self.imageResult(token: token, update: update, error: ""); return }
            Task {
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                        guard values.isRegularFile == true, let size = values.fileSize, size <= 128 * 1024 * 1024 else { throw NoteEditorError.imageUnavailable }
                        return try Data(contentsOf: url, options: .mappedIfSafe)
                    }.value
                    self.importBytes(data, name: url.lastPathComponent, token: token, update: update)
                } catch { self.imageResult(token: token, update: update, error: error.localizedDescription) }
            }
        }
    }

    private func importBytes(_ data: Data, name: String, token: String, update: NoteEditorUpdate) {
        guard sessionID == update.sessionID else { pendingImports.remove(token); return }
        Task {
            do {
                let normalized = try await Task.detached(priority: .userInitiated) { () throws -> Data in
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                          width > 0, height > 0, width <= 30_000, height <= 30_000, width * height <= 100_000_000,
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 6000, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
                          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw NoteEditorError.imageUnavailable }
                    return png
                }.value
                guard sessionID == update.sessionID, let importer = importImage else { throw NoteEditorError.changedSession }
                let cleanName = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent + ".png"
                let asset = try await importer(update.noteID, normalized, cleanName, "image/png")
                guard asset.ownerNoteID == update.noteID else { throw NoteEditorError.imageUnavailable }
                imageResult(token: token, update: update, reference: asset.reference, alt: cleanName)
            } catch { imageResult(token: token, update: update, error: error.localizedDescription) }
        }
    }

    private func imageResult(token: String, update: NoteEditorUpdate, reference: String? = nil, alt: String = "", error: String? = nil) {
        pendingImports.remove(token)
        guard sessionID == update.sessionID else { return }
        var payload = identity(update)
        payload["token"] = token
        payload["reference"] = reference
        payload["alt"] = alt
        payload["error"] = error
        editorWebView?.callAsyncJavaScript("window.notebook.imageResult(payload)", arguments: ["payload": payload], in: nil, in: .page, completionHandler: nil)
    }

    private func noteIdentity(_ url: URL) -> UUID? {
        guard url.scheme?.lowercased() == "workjournal-note", let host = url.host, let noteID = UUID(uuidString: host),
              url.absoluteString.lowercased() == "workjournal-note://\(noteID.uuidString.lowercased())" else { return nil }
        return noteID
    }

    fileprivate func assetIdentity(_ url: URL) -> (UUID, UUID)? {
        guard url.scheme == "workjournal-asset", url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              let host = url.host, let noteID = UUID(uuidString: host),
              url.pathComponents.count == 2, let assetID = UUID(uuidString: url.lastPathComponent),
              url.absoluteString.lowercased() == "workjournal-asset://\(noteID.uuidString.lowercased())/\(assetID.uuidString.lowercased())" else { return nil }
        return (noteID, assetID)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = navigationAction.targetFrame?.isMainFrame == true && navigationAction.request.url?.standardizedFileURL == resourceURL?.standardizedFileURL
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        cancelFlushes(NoteEditorError.unavailable)
        isReady = false
        booted = false
        initializing = false
        pendingImports.removeAll()
        if let previous = latestUpdate {
            sessionID = UUID()
            latestUpdate = NoteEditorUpdate(noteID: previous.noteID, sessionID: sessionID, sequence: previous.sequence, markdown: previous.markdown)
        }
        onError?("编辑器已重新启动，已恢复最近接收到的草稿。请检查最后输入的文字。")
        if let resourceURL { webView.loadFileURL(resourceURL, allowingReadAccessTo: resourceURL.deletingLastPathComponent()) }
    }

    private func cancelFlushes(_ error: Error) {
        let tasks = flushTasks.values
        flushTasks.removeAll()
        for task in tasks { task.resume(throwing: error) }
    }
}

private final class NoteEditorMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: NoteEditorController?
    init(owner: NoteEditorController) { self.owner = owner }
    @MainActor func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.received(message) }
}

@MainActor
private final class NoteAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var owner: NoteEditorController?
    init(owner: NoteEditorController) { self.owner = owner }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let owner, let url = urlSchemeTask.request.url, let (noteID, assetID) = owner.assetIdentity(url),
              noteID == owner.latestUpdate?.noteID, let asset = owner.assetProvider?(noteID, assetID),
              asset.ownerNoteID == noteID, asset.id == assetID, asset.kind == .image,
              ["image/png", "image/jpeg", "image/gif", "image/webp", "image/tiff", "image/heic", "image/heif"].contains(asset.mimeType),
              asset.data.count <= 128 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(asset.data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let sourceType = CGImageSourceGetType(source), UTType(sourceType as String)?.preferredMIMEType == asset.mimeType,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 30_000, height <= 30_000, width * height <= 100_000_000 else {
            urlSchemeTask.didFailWithError(NoteEditorError.imageUnavailable); return
        }
        let response = URLResponse(url: url, mimeType: asset.mimeType, expectedContentLength: asset.data.count, textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(asset.data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

struct NoteEditorView: NSViewRepresentable {
    let controller: NoteEditorController
    func makeNSView(context: Context) -> WKWebView { controller.makeWebView() }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
