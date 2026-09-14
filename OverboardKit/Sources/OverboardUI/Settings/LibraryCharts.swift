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
/// ramp as the rest of the app. Screen Time-style hover selection dims the
/// other days and calls out the selected day's date and total.
struct ActivityTimelineChart: View {
    let activity: DailyActivity

    /// The day currently under `chartXSelection`. `init`'s default keeps
    /// ordinary call sites unselected; previews and snapshot tests can pin
    /// one to render the annotation deterministically.
    @State private var selectedDate: Date?
    @Environment(\.calendar) private var calendar

    init(activity: DailyActivity, selectedDate: Date? = nil) {
        self.activity = activity
        self._selectedDate = State(initialValue: selectedDate)
    }

    private static let height: CGFloat = 140

    /// Kinds captured anywhere in the window, in `ItemKind`'s declaration
    /// order, so the stack and legend colors line up with the ramp used
    /// everywhere else rather than with first-appearance order.
    private var presentKinds: [ItemKind] {
        let present = Set(self.activity.days.flatMap(\.counts.keys))
        return ItemKind.allCases.filter { present.contains($0) }
    }

    /// The tallest day plus ~40% headroom for the selection callout; at
    /// least 1 so an all-zero window still draws an axis.
    private var yAxisCeiling: Int {
        let tallest = self.activity.days.map(\.total).max() ?? 0
        return max(1, Int((Double(tallest) * 1.4).rounded(.up)))
    }

    /// The `activity.days` entry matching `selectedDate`, resolved with the
    /// environment calendar since selection arrives as a raw `Date`.
    private var selectedDay: DailyActivity.Day? {
        guard let selectedDate else { return nil }
        return self.activity.days.first { self.calendar.isDate($0.date, inSameDayAs: selectedDate) }
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
                    if let selectedDay = self.selectedDay {
                        // Declared before the bars so the day-wide band sits behind
                        // the selected stack rather than covering it. `Color`, not the
                        // `.secondary` shape style: inside a chart with a foreground
                        // scale the latter resolves to a tinted accent.
                        RuleMark(x: .value("Selected", selectedDay.date, unit: .day))
                            .foregroundStyle(Color.primary.opacity(0.08))
                    }
                    ForEach(self.activity.days) { day in
                        ForEach(self.presentKinds, id: \.self) { kind in
                            if let count = day.counts[kind] {
                                BarMark(
                                    x: .value("Day", day.date, unit: .day),
                                    y: .value("Clips", count)
                                )
                                .foregroundStyle(by: .value("Kind", kind.displayName))
                                .opacity(self.selectedDay == nil || self.selectedDay?.id == day.id ? 1 : 0.4)
                            }
                        }
                    }
                    if let selectedDay = self.selectedDay {
                        // The callout rides an invisible point at the stack's top so it
                        // sits just above the selected bar instead of covering it; it's
                        // declared after the bars because marks annotate in order.
                        PointMark(
                            x: .value("Selected", selectedDay.date, unit: .day),
                            y: .value("Clips", selectedDay.total)
                        )
                        .symbolSize(0)
                        .annotation(
                            position: .top,
                            spacing: 4,
                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(selectedDay.date, format: .dateTime.month(.abbreviated).day())
                                    .font(.caption.weight(.semibold))
                                Text("\(selectedDay.total.formatted()) clips")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(6)
                            // DESIGN.md rounded.compact-control.
                            .background(.background, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
                        }
                    }
                }
                .chartForegroundStyleScale(
                    domain: self.presentKinds.map(\.displayName),
                    range: self.presentKinds.map { Color($0.tintName) }
                )
                .chartXSelection(value: self.$selectedDate)
                // Headroom above the tallest stack so the selection callout fits
                // inside the plot without covering the bar it describes. Applied
                // whether or not a day is selected, so hovering never rescales.
                .chartYScale(domain: 0 ... self.yAxisCeiling)
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

/// Proportional storage breakdown by content kind, iPhone-Storage style: one
/// stacked horizontal bar plus a custom legend with sizes — Charts' built-in
/// legend can only show the kind name, not its byte total. `bytesByKind` is
/// already sorted largest first.
struct StorageBreakdownBar: View {
    let bytesByKind: [LibraryStats.KindBytes]

    private var total: Int {
        self.bytesByKind.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(self.bytesByKind) { entry in
                BarMark(x: .value("Bytes", entry.bytes))
                    .foregroundStyle(by: .value("Kind", entry.kind.displayName))
            }
            .chartForegroundStyleScale(
                domain: self.bytesByKind.map(\.kind.displayName),
                range: self.bytesByKind.map { Color($0.kind.tintName) }
            )
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartXScale(domain: 0 ... max(self.total, 1))
            .chartPlotStyle { $0.clipShape(RoundedRectangle(cornerRadius: 4)) }
            .frame(height: 14)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 100), spacing: 12, alignment: .leading)],
                alignment: .leading,
                spacing: 4
            ) {
                ForEach(self.bytesByKind) { entry in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(entry.kind.tintName))
                            .frame(width: 8, height: 8)
                        Text("\(entry.kind.displayName) \(Self.byteCountLabel(entry.bytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.accessibilityLabel)
    }

    private var accessibilityLabel: String {
        self.bytesByKind
            .map { "\($0.kind.displayName) \(Self.byteCountLabel($0.bytes))" }
            .joined(separator: ", ")
    }

    private static func byteCountLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
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

    #Preview("Storage breakdown") {
        StorageBreakdownBar(bytesByKind: [
            .init(kind: .image, bytes: 48_000_000),
            .init(kind: .text, bytes: 1_200_000),
            .init(kind: .link, bytes: 300_000),
            .init(kind: .file, bytes: 120_000),
            .init(kind: .color, bytes: 2000),
        ])
        .padding()
        .frame(width: 480)
    }
#endif
