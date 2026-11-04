import Foundation
import Carbon
import JournalCore

@MainActor final class ShortcutController {
    private var hotKey: EventHotKeyRef?
    private var sequence: UInt32 = 0
    private var selection = ShortcutSelection()
    func apply(_ config: ShortcutConfiguration) throws {
        try selection.apply(config) { [self] config in
            var modifiers: UInt32 = 0
            if config.control { modifiers |= UInt32(controlKey) }
            if config.option { modifiers |= UInt32(optionKey) }
            if config.command { modifiers |= UInt32(cmdKey) }
            if config.shift { modifiers |= UInt32(shiftKey) }
            var candidate: EventHotKeyRef?
            sequence &+= 1
            let id = EventHotKeyID(signature: 0x574A4E4C, id: sequence)
            let result = RegisterEventHotKey(config.keyCode, modifiers, id, GetApplicationEventTarget(), 0, &candidate)
            guard result == noErr, let candidate else {
                throw JournalError.invalid("此组合无法注册，可能被其他应用占用。原快捷键保持不变。（错误 \(result)）")
            }
            // Register first: a conflicting new combination never destroys the old one.
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = candidate
        }
    }
    func stop() { if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil; selection = ShortcutSelection() }
}
