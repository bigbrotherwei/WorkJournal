import Foundation
public enum PowerMode: String, Codable, CaseIterable { case automatic = "自动", saving = "始终省电", unrestricted = "允许后台分类" }
public enum PowerSource: String { case battery = "电池供电", external = "外接电源", unknown = "电源状态未知" }
public struct PowerSnapshot: Equatable {
    public var source: PowerSource
    public var lowPower: Bool
    public var hot: Bool
    public init(source: PowerSource = .unknown, lowPower: Bool = false, hot: Bool = false) { self.source = source; self.lowPower = lowPower; self.hot = hot }
}
public enum PowerPolicy {
    public static func mode(saved: String?, legacySaving: Bool?) -> PowerMode {
        if let saved, let mode = PowerMode(rawValue: saved) { return mode }
        if let legacySaving { return legacySaving ? .saving : .unrestricted }
        return .automatic
    }
    public static func pausesBackground(mode: PowerMode, state: PowerSnapshot) -> Bool {
        switch mode {
        case .saving: return true
        case .unrestricted: return false
        case .automatic: return state.source != .external || state.lowPower || state.hot
        }
    }
}
