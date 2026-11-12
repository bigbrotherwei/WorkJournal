import SwiftUI
import AppKit
import Carbon
import JournalCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var mainWindow: NSWindow?
    private var captureWindow: NSPanel?
    private var statusItem: NSStatusItem?
    private let shortcuts = ShortcutController()
    private var captureMenuItem: NSMenuItem?
    private var eventHandler: EventHandlerRef?
    private var previousApp: NSRunningApplication?
    private lazy var powerMonitor = PowerMonitor { [weak self] state in self?.model.updatePower(state) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        let menu = NSMenu()
        let root = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出工作随记", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = appMenu; menu.addItem(root)
        let editRoot = NSMenuItem(); editRoot.title = "编辑"; let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editRoot.submenu = editMenu; menu.addItem(editRoot); NSApp.mainMenu = menu
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "工作随记")
        let statusMenu = NSMenu()
        let capture = NSMenuItem(title: "记一笔  ⌃⌥ Space", action: #selector(showCapture), keyEquivalent: "")
        capture.target = self; statusMenu.addItem(capture); captureMenuItem = capture
        let main = NSMenuItem(title: "打开工作随记", action: #selector(showMain), keyEquivalent: "")
        main.target = self; statusMenu.addItem(main); statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = statusMenu; statusItem = status
        model.reminders.onOpenEntry = { [weak self] _ in self?.model.navigationTarget = "待办"; self?.showMain() }
        model.reminders.onSnoozeEntry = { [weak self] id, choice, timestamp in
            self?.model.snooze(id, until: choice.date(), expectedTimestamp: timestamp)
            self?.model.navigationTarget = "待办"; self?.showMain()
        }
        powerMonitor.start(); installShortcut(); showMain()
    }
    @objc func showMain() {
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "工作随记"; window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 900, height: 640); window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: MainView(app: model, capture: { [weak self] in self?.showCapture() }))
            window.center(); mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showCapture() {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = NSWorkspace.shared.frontmostApplication }
        model.prepareCapture()
        if captureWindow == nil {
            let panel = CapturePanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 550), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "记一笔"; panel.isReleasedWhenClosed = false; panel.level = .floating
            // A nonactivating overlay can join the foreground app's full-screen Space.
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.contentView = NSHostingView(rootView: CaptureView(app: model, close: { [weak self] in self?.closeCapture() }))
            panel.onEscape = { [weak self] in self?.closeCapture() }
            panel.center(); captureWindow = panel
        }
        guard let panel = captureWindow else { return }
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2,
                                         y: area.midY - panel.frame.height / 2))
        }
        // Do not activate the application: doing so may switch back to its desktop Space.
        panel.orderFrontRegardless()
        panel.makeKey()
    }
    func closeCapture() { captureWindow?.orderOut(nil); previousApp?.activate(options: []); previousApp = nil }
    func applicationDidBecomeActive(_ notification: Notification) { model.reminders.reconcile(entries: model.entries) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            do { try await model.notebook.flush(); sender.reply(toApplicationShouldTerminate: true) }
            catch {
                let alert = NSAlert(); alert.messageText = "笔记尚未保存，已取消退出"; alert.informativeText = error.localizedDescription + "\n请保留窗口并复制需要的内容后重试。"; alert.addButton(withTitle: "继续编辑"); alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { powerMonitor.stop(); shortcuts.stop(); if let eventHandler { RemoveEventHandler(eventHandler) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMain(); return true }
    private func installShortcut() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in app.showCapture() }; return noErr
        }, 1, &spec, pointer, &eventHandler)
        guard handlerStatus == noErr else {
            model.shortcutStatus = "快捷键事件服务不可用，请使用菜单栏"
            return
        }
        model.registerShortcut = { [weak self] config in
            guard let self else { throw JournalError.invalid("快捷键服务不可用") }
            try self.shortcuts.apply(config)
            self.captureMenuItem?.title = "记一笔  " + config.label
        }
        model.applyShortcut(model.shortcut)

    }
}
final class CapturePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
