import SwiftUI
import JournalCore

struct RecordActivityView: View {
    let entries: [Entry]
    let selectedDay: String?
    let select: (String) -> Void
    private let cell: CGFloat = 14
    private let gap: CGFloat = 4
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let activity = RecordActivity(entries: entries, now: context.date)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("记录总览", systemImage: "square.grid.3x3.fill").font(.system(size: 13, weight: .semibold))
                    Text("最近 12 周").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(activity.total) 条记录 · \(activity.activeDays) 天有记录")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .center, spacing: 24) {
                    HStack(alignment: .top, spacing: gap) {
                        VStack(spacing: gap) {
                            Color.clear.frame(width: 18, height: 12)
                            ForEach(0..<7, id: \.self) { row in
                                Text(row % 2 == 0 ? weekdays[row] : "").font(.system(size: 9))
                                    .foregroundStyle(.secondary).frame(width: 18, height: cell)
                            }
                        }
                        ForEach(0..<12, id: \.self) { week in
                            VStack(spacing: gap) {
                                Text(monthLabel(activity.days, week: week)).font(.system(size: 9))
                                    .foregroundStyle(.secondary).fixedSize(horizontal: true, vertical: false)
                                    .frame(width: cell, height: 12, alignment: .leading)
                                ForEach(0..<7, id: \.self) { row in
                                    let day = activity.days[week * 7 + row]
                                    Button { select(day.day) } label: {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(day.isFuture ? Color.clear : color(RecordActivity.level(day.count)))
                                            .frame(width: cell, height: cell)
                                            .overlay(RoundedRectangle(cornerRadius: 3)
                                                .strokeBorder(selectedDay == day.day ? Color.primary : Color.primary.opacity(day.isFuture ? 0 : 0.05), lineWidth: selectedDay == day.day ? 2 : 0.5))
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain).disabled(day.isFuture)
                                        .help("\(day.day) · \(day.count) 条记录")
                                        .accessibilityLabel("\(day.day)，\(day.count) 条记录")
                                        .accessibilityValue(selectedDay == day.day ? "已选中" : "未选中")
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(selectedDay.map { "查看 \($0)" } ?? "每天一点，积累看得见")
                            .font(.system(size: 13, weight: .medium))
                        Text("颜色越深，当天记录越多。\n点击日期查看记录，再次点击取消。")
                            .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 4) {
                            Text("少").font(.caption2).foregroundStyle(.secondary)
                            ForEach(0..<5, id: \.self) { level in
                                RoundedRectangle(cornerRadius: 2).fill(color(level)).frame(width: 12, height: 12)
                                    .help(["0 条", "1 条", "2–3 条", "4–5 条", "6 条及以上"][level])
                            }
                            Text("多").font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("按归属日期统计，含补记").font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.journalCard(padding: 14)
        }
    }
    private func color(_ level: Int) -> Color {
        level == 0 ? Color.primary.opacity(0.055) : JournalTheme.accent.opacity([0, 0.25, 0.45, 0.7, 1][level])
    }
    private func monthLabel(_ days: [RecordActivity.Day], week: Int) -> String {
        let month = String(days[week * 7].day.dropFirst(5).prefix(2))
        let previous = week > 0 ? String(days[(week - 1) * 7].day.dropFirst(5).prefix(2)) : ""
        return month != previous ? "\(Int(month) ?? 1)月" : ""
    }
}
