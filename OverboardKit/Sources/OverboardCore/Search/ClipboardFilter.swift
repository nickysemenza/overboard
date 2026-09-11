import Foundation

public struct ClipboardFilter: Sendable, Equatable {
    public enum Period: String, CaseIterable, Sendable {
        case all = "Any time", today = "Today", week = "Past week", month = "Past month"

        public func cutoff(now: Date = .now) -> Date? {
            switch self {
            case .all: nil
            case .today: Calendar.current.startOfDay(for: now)
            case .week: now.addingTimeInterval(-7 * 86400)
            case .month: now.addingTimeInterval(-30 * 86400)
            }
        }
    }

    public var kind: ItemKind?
    public var source: String?
    public var period: Period = .all
    public var pinnedOnly = false

    public init() {}
}
