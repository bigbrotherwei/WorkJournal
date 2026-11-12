private final class HarnessSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var received = Data()
    var failed = false
    var finished = false
    init(url: URL) { request = URLRequest(url: url) }
    func didReceive(_ response: URLResponse) {}
    func didReceive(_ data: Data) { received.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { failed = true }
}
// Appended to an unmodified controller copy (except module imports/resource accessor) by native-test.sh.
@main struct NativeEditorHarness {
    @MainActor static func evaluate(_ view: WKWebView, _ script: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in continuation.resume(with: result) }
        }
    }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let controller = NoteEditorController()
        let noteID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let original = "# Exact  \n\n  * 合成内容\n\n"
        controller.onError = { print("EDITOR NOTICE: \($0)") }
        controller.load(noteID: noteID, markdown: original, revision: 3)
        let view = controller.makeWebView()
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 900)
        Task { @MainActor in
            do {
                let first = try await controller.flush()
                for width in [720, 520] {
                    view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                    try await Task.sleep(nanoseconds: 30_000_000)
                    let layout = try await evaluate(view, "return {width:innerWidth,overflow:document.documentElement.scrollWidth>innerWidth,height:document.getElementById('toolbar').getBoundingClientRect().height,svg:document.querySelectorAll('#toolbar-main button svg').length};") as! [String: Any]
                    precondition(layout["overflow"] as? Bool == false && (layout["height"] as? Double ?? 1000) <= 90 && (layout["svg"] as? Int ?? 0) >= 11, "Compact SVG toolbar must fit in at most two rows without horizontal overflow")
                }

                precondition(first.markdown == original && first.sequence == 3)
                let session = controller.sessionID
                controller.load(noteID: noteID, markdown: "save echo must not replace", revision: 4)
                precondition(controller.sessionID == session)
                _ = try await evaluate(view, "await window.notebook.command('source');const t=document.getElementById('source');t.value='Changed 中文';t.dispatchEvent(new Event('input'));return true;")
                let updated = try await controller.flush()
                precondition(updated.markdown == "Changed 中文" && updated.sequence > first.sequence)
                _ = try await evaluate(view, "await window.notebook.command('document');return true;")
                let roundtrip = try await controller.flush()
                precondition(roundtrip.markdown == "Changed 中文")
                let stale = controller.sessionID
                controller.load(noteID: UUID(), markdown: "Second", revision: 0)
                let second = try await controller.flush()
                precondition(second.sessionID != stale && second.markdown == "Second")
                let assetID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
                bitmap.setColor(.white, atX: 0, y: 0)
                let png = bitmap.representation(using: .png, properties: [:])!
                var asset = NoteAsset(id: assetID, ownerNoteID: second.noteID, fileName: "synthetic.png", mimeType: "image/png", kind: .image, data: png)
                controller.assetProvider = { _, _ in asset }
                let scheme = NoteAssetSchemeHandler(owner: controller)
                let validTask = HarnessSchemeTask(url: URL(string: asset.reference)!)
                scheme.webView(view, start: validTask)
                precondition(validTask.finished && validTask.received == png)
                let crossTask = HarnessSchemeTask(url: URL(string: "workjournal-asset://11111111-1111-4111-8111-111111111111/44444444-4444-4444-8444-444444444444")!)
                scheme.webView(view, start: crossTask)
                precondition(crossTask.failed && crossTask.received.isEmpty)
                asset.mimeType = "image/jpeg"
                let wrongMIME = HarnessSchemeTask(url: URL(string: asset.reference)!)
                scheme.webView(view, start: wrongMIME)
                precondition(wrongMIME.failed && wrongMIME.received.isEmpty, "MIME must match decoded raster type")
                let beforeCrash = controller.sessionID
                controller.webViewWebContentProcessDidTerminate(view)
                let recovered = try await controller.flush()
                precondition(recovered.sessionID != beforeCrash && recovered.markdown == "Second")
                let csp = try await evaluate(view, "return document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]').content;") as? String
                precondition(csp?.contains("connect-src 'none'") == true && csp?.contains("img-src workjournal-asset:") == true)
                let relatedID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
                var openedNotes: [UUID] = []
                controller.openNote = { openedNotes.append($0) }
                _ = try await evaluate(view, "const p = await window.notebook.flush({noteID: '\(recovered.noteID.uuidString.lowercased())', sessionID: '\(recovered.sessionID.uuidString.lowercased())'});window.webkit.messageHandlers.notebook.postMessage({...p,type:'openURL',url:'workjournal-note://55555555-5555-4555-8555-555555555555'});return true;")
                try await Task.sleep(nanoseconds: 30_000_000)
                precondition(openedNotes == [relatedID], "Internal note URL must invoke the native selection callback")
                _ = try await evaluate(view, "const p = await window.notebook.flush({noteID: '\(recovered.noteID.uuidString.lowercased())', sessionID: '\(recovered.sessionID.uuidString.lowercased())'});for(const suffix of ['/', '?x=1', '#x'])window.webkit.messageHandlers.notebook.postMessage({...p,type:'openURL',url:'workjournal-note://55555555-5555-4555-8555-555555555555'+suffix});return true;")
                try await Task.sleep(nanoseconds: 30_000_000)
                precondition(openedNotes == [relatedID], "Malformed internal note URLs must be rejected")
                print("PASS: internal note callbacks, native offline boot, exact-source flush, same-note echo, source edits, mode roundtrip, fresh identity, asset ownership and MIME, recovery delegate, CSP")
                exit(0)
            } catch { print("FAIL: \(error)"); exit(1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { print("FAIL: native harness deadline"); exit(2) }
        app.run()
    }
}
