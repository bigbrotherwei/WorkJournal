import SwiftUI
import AppKit

/// Shared semantic colors keep the native window legible in light and dark appearances.
enum JournalTheme {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.43, green: 0.76, blue: 0.67, alpha: 1)
            : NSColor(red: 0.16, green: 0.43, blue: 0.37, alpha: 1)
    })
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.10, green: 0.12, blue: 0.12, alpha: 1)
            : NSColor(red: 0.96, green: 0.97, blue: 0.96, alpha: 1)
    })
    static let paper = Color(nsColor: .controlBackgroundColor)
}

extension View {
    func journalCard(padding: CGFloat = 18) -> some View {
        self.padding(padding).background(JournalTheme.paper, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 27, weight: .bold, design: .rounded))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

struct JournalMetric: View {
    let title: String
    let value: Int
    let icon: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16, weight: .medium))
                .foregroundStyle(JournalTheme.accent).frame(width: 36, height: 36)
                .background(JournalTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(value.formatted()).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.journalCard(padding: 15)
    }
}

struct JournalEmptyState: View {
    let filtered: Bool
    var capture: () -> Void
    var reset: () -> Void
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 18) {
            Spacer(minLength: 20)
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(JournalTheme.accent.opacity(0.06))
                    .frame(width: 106, height: 106).rotationEffect(.degrees(-9))
                RoundedRectangle(cornerRadius: 16).fill(JournalTheme.paper)
                    .frame(width: 82, height: 92).shadow(color: .black.opacity(0.06), radius: 12, y: 6)
                Image(systemName: filtered ? "magnifyingglass" : "text.badge.plus")
                    .font(.system(size: 31, weight: .light)).foregroundStyle(JournalTheme.accent)
            }.accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(filtered ? "没有找到匹配的记录" : "从一句话，开始记录今天")
                    .font(.system(size: 19, weight: .semibold))
                Text(filtered ? "试试其他关键词，或清除筛选条件。" : "进展、问题、灵感，都可以先记下来。\n需要汇总的内容，勾选「计入日报」即可。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            }
            Button(action: filtered ? reset : capture) {
                Label(filtered ? "清除筛选" : "记下第一笔", systemImage: filtered ? "line.3.horizontal.decrease.circle" : "plus")
            }.buttonStyle(JournalPrimaryButtonStyle()).controlSize(.large)
            Spacer(minLength: 20)
            Label("内容只保存在这台 Mac 上", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 16)
                }.frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }.journalCard(padding: 20)
    }
}

struct JournalPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .background(isEnabled ? Color(red: 0.16, green: 0.43, blue: 0.37).opacity(configuration.isPressed ? 0.8 : 1) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}
