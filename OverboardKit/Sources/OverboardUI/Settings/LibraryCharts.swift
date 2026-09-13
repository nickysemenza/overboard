import Charts
import OverboardCore
import SwiftUI

/// Vertical room per bar in the two breakdown charts — a list-row's worth,
/// so a chart with N entries is as tall as the N `LabeledContent` rows it
/// replaced and the Form doesn't reflow around it.
private let rowHeight: CGFloat = 22

/// Horizontal bar chart of live-item counts per content kind, most-frequent
/// first (`LibraryStats.byKind` is already sorted that way).
struct KindBreakdownChart: View {
    let byKind: [LibraryStats.KindCount]

    private var height: CGFloat {
        max(rowHeight, CGFloat(self.byKind.count) * rowHeight)
    }

    var body: some View {
        Chart(self.byKind) { entry in
            BarMark(
                x: .value("Items", entry.count),
                y: .value("Kind", entry.kind.displayName)
            )
            // The one place the kind-identity ramp is the subject rather than
            // incidental decoration (DESIGN.md § Colors).
            .foregroundStyle(Color(entry.kind.tintName))
            .cornerRadius(3)
            .annotation(position: .trailing) {
                Text(entry.count.formatted())
                    .font(.caption)
                    .monospacedDigit()
            }
        }
        .chartLegend(.hidden)
        // The trailing count annotation is the value; a numeric axis under
        // it would say the same thing twice.
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(preset: .extended, position: .leading) { _ in
                AxisValueLabel()
            }
        }
        .frame(height: self.height)
        .accessibilityElement()
        .accessibilityLabel(self.accessibilityLabel)
    }

    private var accessibilityLabel: String {
        self.byKind.map { $0.kind.countLabel($0.count) }.joined(separator: ", ")
    }
}

/// Horizontal bar chart of live-item counts per source app, most-frequent
/// first (`LibraryStats.bySource` is already sorted that way). One neutral
/// fill for every bar — source apps aren't part of the kind-identity ramp, so
/// nothing here borrows its colors.
struct SourceBreakdownChart: View {
    let bySource: [LibraryStats.SourceCount]

    private var height: CGFloat {
        max(rowHeight, CGFloat(self.bySource.count) * rowHeight)
    }

    var body: some View {
        Chart(self.bySource) { entry in
            BarMark(
                x: .value("Items", entry.count),
                y: .value("Source", entry.app)
            )
            .foregroundStyle(Color.accentColor.opacity(0.6))
            .cornerRadius(3)
            .annotation(position: .trailing) {
                Text(entry.count.formatted())
                    .font(.caption)
                    .monospacedDigit()
            }
        }
        .chartLegend(.hidden)
        // The trailing count annotation is the value; a numeric axis under
        // it would say the same thing twice.
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(preset: .extended, position: .leading) { _ in
                AxisValueLabel()
            }
        }
        .frame(height: self.height)
        .accessibilityElement()
        .accessibilityLabel(self.accessibilityLabel)
    }

    private var accessibilityLabel: String {
        self.bySource
            .map { "\($0.app): \(CountPhrase.string($0.count, of: String(localized: "item")))" }
            .joined(separator: ", ")
    }
}

/// Stacked daily bar chart of captures over the window `DailyActivity`
/// covers, colored by content kind so the stack obeys the same kind-identity
/// ramp as the rest of the app.
struct ActivityTimelineChart: View {
    let activity: DailyActivity

    private static let height: CGFloat = 140

    /// Kinds captured anywhere in the window, in `ItemKind`'s declaration
    /// order, so the stack and legend colors line up with the ramp used
    /// everywhere else rather than with first-appearance order.
    private var presentKinds: [ItemKind] {
        let present = Set(self.activity.days.flatMap(\.counts.keys))
        return ItemKind.allCases.filter { present.contains($0) }
    }

    var body: some View {
        Group {
            if self.activity.total == 0 {
                // The default label style wants more vertical room than the
                // chart's own fixed height — `minHeight` keeps this slot at
                // least as tall as the chart without clipping the icon.
                ContentUnavailableView(
                    String(localized: "No activity yet"),
                    systemImage: "chart.bar",
                    description: Text("Clips you capture will show up here.")
                )
                .frame(minHeight: Self.height)
            } else {
                Chart {
                    ForEach(self.activity.days) { day in
                        ForEach(self.presentKinds, id: \.self) { kind in
                            if let count = day.counts[kind] {
                                BarMark(
                                    x: .value("Day", day.date, unit: .day),
                                    y: .value("Clips", count)
                                )
                                .foregroundStyle(by: .value("Kind", kind.displayName))
                            }
                        }
                    }
                }
                .chartForegroundStyleScale(
                    domain: self.presentKinds.map(\.displayName),
                    range: self.presentKinds.map { Color($0.tintName) }
                )
                .chartLegend(position: .bottom)
                .chartXAxis {
                    // Weekly marks, let Charts pick which fit rather than
                    // forcing one at the right edge that only has room for "…".
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3))
                }
                // Headroom so the top y-axis label isn't cut by the frame.
                .padding(.top, 4)
                .frame(height: Self.height)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(self.accessibilityLabel)
    }

    private var accessibilityLabel: String {
        String(localized: "\(self.activity.total.formatted()) clips in the last \(self.activity.days.count) days")
    }
}

#if DEBUG
    #Preview("Kind breakdown") {
        KindBreakdownChart(byKind: [
            .init(kind: .text, count: 812),
            .init(kind: .link, count: 96),
            .init(kind: .image, count: 41),
            .init(kind: .file, count: 12),
            .init(kind: .color, count: 4),
        ])
        .padding()
        .frame(width: 400)
    }

    #Preview("Source breakdown") {
        SourceBreakdownChart(bySource: [
            .init(app: "Safari", count: 320),
            .init(app: "Xcode", count: 210),
            .init(app: "Messages", count: 88),
        ])
        .padding()
        .frame(width: 400)
    }

    #Preview("Activity timeline") {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_757_721_600)
        let days: [DailyActivity.Day] = (0 ..< 30).map { offset in
            let date = calendar.date(byAdding: .day, value: -(29 - offset), to: calendar.startOfDay(for: now))!
            let counts: [ItemKind: Int] = offset.isMultiple(of: 4)
                ? [:]
                : [.text: 3 + offset % 5, .link: offset % 3]
            return DailyActivity.Day(date: date, counts: counts)
        }
        ActivityTimelineChart(activity: DailyActivity(days: days, total: days.reduce(0) { $0 + $1.total }))
            .padding()
            .frame(width: 480)
    }

    #Preview("Activity timeline — empty") {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_757_721_600)
        let days: [DailyActivity.Day] = (0 ..< 30).map { offset in
            let date = calendar.date(byAdding: .day, value: -(29 - offset), to: calendar.startOfDay(for: now))!
            return DailyActivity.Day(date: date, counts: [:])
        }
        ActivityTimelineChart(activity: DailyActivity(days: days, total: 0))
            .padding()
            .frame(width: 480)
    }
#endif
