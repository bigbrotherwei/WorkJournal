import Foundation
public struct ShortcutConfiguration: Codable, Equatable {
    public var keyCode: UInt32
    public var control: Bool
    public var option: Bool
    public var command: Bool
    public var shift: Bool
    public init(keyCode: UInt32 = 49, control: Bool = true, option: Bool = true, command: Bool = false, shift: Bool = false) {
        self.keyCode = keyCode; self.control = control; self.option = option; self.command = command; self.shift = shift
    }
    public static let keys: [(code: UInt32, label: String)] = [
        (49, "Space"), (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"),
        (4, "H"), (34, "I"), (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"), (31, "O"),
        (35, "P"), (12, "Q"), (15, "R"), (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"),
        (7, "X"), (16, "Y"), (6, "Z")
    ]
    public var label: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + " " + (Self.keys.first { $0.code == keyCode }?.label ?? "?")
    }
    public func validate() throws {
        guard [control, option, command].filter({ $0 }).count >= 2 else {
            throw JournalError.invalid("请在 Control、Option、Command 中至少选择两个，避免占用常用编辑快捷键。")
        }
        guard Self.keys.contains(where: { $0.code == keyCode }) else { throw JournalError.invalid("不支持的快捷键按键。") }
    }
}
public struct ShortcutSelection {
    public private(set) var current: ShortcutConfiguration?
    public init(current: ShortcutConfiguration? = nil) { self.current = current }
    public mutating func apply(_ config: ShortcutConfiguration, register: (ShortcutConfiguration) throws -> Void) throws {
        try config.validate()
        if current == config { return }
        try register(config)
        current = config
    }
}
