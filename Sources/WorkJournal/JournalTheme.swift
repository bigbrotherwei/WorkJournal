import SwiftUI
import AppKit

/// Semantic colors follow the Mac appearance without changing the user's preference.
enum JournalTheme {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
    static let accent = adaptive(0x7960B2, 0xC5B0F1)
    static let accentFill = Color(red: 0.48, green: 0.36, blue: 0.70)
    static let canvas = adaptive(0xFDFDFF, 0x252731)
    static let paper = adaptive(0xFFFFFF, 0x30333D)
    static let sidebar = adaptive(0xFCFBFF, 0x2B2D36)
    static let border = adaptive(0xEEEFF5, 0x454653)
    static let ink = adaptive(0x343446, 0xF1F0F7)
    static let secondary = adaptive(0x75788B, 0xBABACB)
    static let soft = adaptive(0xF3EFFF, 0x403750)

    enum Tone {
        case violet, blue, peach, mint, neutral
        var color: Color {
            switch self {
            case .violet: return JournalTheme.accent
            case .blue: return adaptive(0x507BAB, 0xA9CCF8)
            case .peach: return adaptive(0xA66D3E, 0xECC49D)
            case .mint: return adaptive(0x397E63, 0xA4DCC3)
            case .neutral: return JournalTheme.secondary
            }
        }
        var surface: Color {
            switch self {
            case .violet: return JournalTheme.soft
            case .blue: return adaptive(0xEEF6FF, 0x303F55)
            case .peach: return adaptive(0xFFF3E9, 0x4B3E31)
            case .mint: return adaptive(0xEBF8F1, 0x2C463C)
            case .neutral: return adaptive(0xF1F3F8, 0x3C414E)
            }
        }
    }
    static func category(_ name: String) -> (symbol: String, tone: Tone) {
        if name.localizedCaseInsensitiveContains("review") || name.contains("审查") { return ("text.magnifyingglass", .blue) }
        if name.contains("排查") || name.contains("故障") || name.contains("问题") { return ("lifepreserver", .peach) }
        if name.contains("阅读") || name.contains("学习") { return ("book", .blue) }
        if name.contains("开发") || name.contains("代码") { return ("curlybraces", .violet) }
        if name == "未分类" { return ("tray", .neutral) }
        return ("lightbulb", .mint)
    }
}

struct JournalPageBackground: View {
    var body: some View {
        JournalTheme.canvas.overlay(alignment: .top) {
            LinearGradient(colors: [JournalTheme.Tone.blue.surface.opacity(0.65), JournalTheme.soft.opacity(0.35), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(height: 200).allowsHitTesting(false)
        }
    }
}
struct JournalSymbol: View {
    let name: String
    var tone: JournalTheme.Tone = .violet
    var size: CGFloat = 34
    var body: some View {
        Image(systemName: name).font(.system(size: size * 0.49, weight: .medium, design: .rounded))
            .symbolRenderingMode(.hierarchical).foregroundStyle(tone.color)
            .frame(width: size, height: size)
            .background(tone.surface, in: RoundedRectangle(cornerRadius: size * 0.38, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension View {
    func journalCard(padding: CGFloat = 20) -> some View {
        self.padding(padding).background(JournalTheme.paper, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).strokeBorder(JournalTheme.border))
            .shadow(color: JournalTheme.accent.opacity(0.025), radius: 9, y: 3)
    }
}
struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 27, weight: .bold, design: .rounded)).foregroundStyle(JournalTheme.ink)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(JournalTheme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
struct JournalMetric: View {
    let title: String
    let value: Int
    let icon: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium))
            Text(title).font(.system(size: 12))
            Text(value.formatted()).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                .padding(.horizontal, 6).padding(.vertical, 3).background(JournalTheme.paper, in: RoundedRectangle(cornerRadius: 7))
        }.padding(.horizontal, 11).padding(.vertical, 7)
    }
}
struct JournalEmptyState: View {
    let filtered: Bool
    var capture: () -> Void
    var reset: () -> Void
    var body: some View {
        VStack(spacing: 17) {
            JournalSymbol(name: filtered ? "magnifyingglass" : "square.and.pencil", size: 62)
            Text(filtered ? "没有找到匹配的记录" : "从一句话，开始记录今天").font(.system(size: 19, weight: .semibold, design: .rounded))
            Text(filtered ? "试试其他关键词，或清除筛选条件。" : "进展、问题、灵感，都可以先记下来。\n需要汇总的内容，勾选「计入日报」即可。")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            Button(action: filtered ? reset : capture) {
                Label(filtered ? "清除筛选" : "记下第一笔", systemImage: filtered ? "line.3.horizontal.decrease.circle" : "plus")
            }.buttonStyle(JournalPrimaryButtonStyle())
        }.frame(maxWidth: .infinity).padding(.vertical, 44).journalCard()
    }
}
struct JournalPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 15).padding(.vertical, 10)
            .foregroundStyle(isEnabled ? .white : JournalTheme.secondary)
            .background(isEnabled ? JournalTheme.accentFill.opacity(configuration.isPressed ? 0.8 : hovering ? 0.94 : 1) : JournalTheme.border, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 13)).onHover { hovering = $0 }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
struct JournalSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(isEnabled ? JournalTheme.ink : JournalTheme.secondary)
            .background(configuration.isPressed || hovering ? JournalTheme.soft : JournalTheme.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(JournalTheme.border))
            .contentShape(RoundedRectangle(cornerRadius: 12)).opacity(isEnabled ? 1 : 0.5)
            .onHover { hovering = $0 }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let symbol: String
    var tone: JournalTheme.Tone = .violet
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) { JournalSymbol(name: symbol, tone: tone); Text(title).font(.system(size: 15, weight: .semibold)); Spacer() }
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).journalCard(padding: 22).textFieldStyle(.roundedBorder)
    }
}
