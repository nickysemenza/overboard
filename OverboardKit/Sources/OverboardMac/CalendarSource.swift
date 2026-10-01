import AppKit
import EventKit
import Foundation
import os
import OverboardCore

/// Tracks upcoming EventKit events for the launcher's calendar row.
///
/// Modeled on `SpotifyNowPlayingMonitor`: an event-driven observer
/// (`.EKEventStoreChanged`) plus a debounced fetch that also runs at launch
/// and on every launcher summon, so a missed notification (or a restart)
/// still catches up. `EKEvent`/`EKEventStore` aren't `Sendable`, so the fetch
/// itself is a `nonisolated static` function that builds its own store and
/// converts every event to a `CalendarEvent` value before returning —
/// nothing EventKit-shaped ever crosses the queue hop.
public final class CalendarSource {
    /// Held only to register for `.EKEventStoreChanged`; fetches use a fresh
    /// instance (see `fetchUpcomingEvents`) rather than crossing this one to
    /// the fetch queue.
    private let store = EKEventStore()

    public private(set) var upcomingEvents: [CalendarEvent] = []
    /// Thread-safe mirror of `upcomingEvents`, read by the launcher
    /// provider's `@Sendable` closure without hopping to the main actor.
    public nonisolated let snapshot = OSAllocatedUnfairLock<[CalendarEvent]>(initialState: [])
    /// Fired on every change so a visible launcher can refresh its rows.
    public var onChange: () -> Void = {}

    private var changeObserver: NSObjectProtocol?
    private var generation = 0
    public private(set) var isRunning = false
    /// Debounces fetches so a burst of change notifications (or launcher
    /// reopens) doesn't hammer EventKit.
    private var lastRefreshAt: Date?
    private nonisolated static let fetchQueue = DispatchQueue(label: "com.nickysemenza.overboard.calendar-fetch")
    private let access: () -> PermissionState
    private let now: () -> Date
    private let readEvents: @Sendable (Date, Date) async -> [CalendarEvent]
    private let sleep: @Sendable (Duration) async throws -> Void
    private var needsRefresh = false
    private(set) var fetchTask: Task<Void, Never>?
    private(set) var cooldownTask: Task<Void, Never>?

    /// Today plus tomorrow is the widest window any launcher query needs.
    private nonisolated static let fetchWindowDays = 2
    private nonisolated static let fetchCap = 32

    public convenience init() {
        self.init(access: { Self.authorization }, readEvents: Self.readEvents)
    }

    init(
        access: @escaping () -> PermissionState,
        readEvents: @escaping @Sendable (Date, Date) async -> [CalendarEvent],
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.access = access
        self.readEvents = readEvents
        self.now = now
        self.sleep = sleep
    }

    /// Maps EventKit's authorization status to Overboard's tri-state
    /// permission model. `fullAccess` is the only state that lets Overboard
    /// actually read events; `writeOnly` (granted by a system prompt variant
    /// this feature never asks for) can't read either, so it's treated as denied.
    public nonisolated static var authorization: PermissionState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .denied, .restricted, .writeOnly: .denied
        case .notDetermined: .unknown
        @unknown default: .unknown
        }
    }

    /// Shows the system consent dialog. Only ever called from an explicit
    /// user action (Settings → Permissions, or the Welcome window) — never
    /// from the launcher itself.
    ///
    /// Returns the status TCC actually recorded afterward rather than
    /// trusting the call's Bool: a request that throws or returns `false`
    /// without ever showing a dialog (a signing or entitlement hiccup, say)
    /// must leave the state at "not asked" — reporting it as denied would hide
    /// the Request button for good, since macOS never re-prompts once denied.
    public static func requestAccess() async -> PermissionState {
        _ = try? await EKEventStore().requestFullAccessToEvents()
        return self.authorization
    }

    public func start() {
        guard !self.isRunning, self.access() == .granted else { return }
        self.isRunning = true
        self.generation += 1
        self.lastRefreshAt = nil
        self.fetchTask?.cancel()
        self.cooldownTask?.cancel()
        self.cooldownTask = nil
        self.needsRefresh = false
        self.changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: self.store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSnapshot()
            }
        }
        self.refreshSnapshot()
    }

    public func stop() {
        self.isRunning = false
        self.generation += 1
        self.lastRefreshAt = nil
        self.fetchTask?.cancel()
        self.cooldownTask?.cancel()
        self.cooldownTask = nil
        self.needsRefresh = false
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
        self.changeObserver = nil
        self.apply([])
    }

    /// The next event that hasn't ended yet — nil once every fetched event is over.
    public func nextEvent(now: Date = .now) -> CalendarEvent? {
        self.upcomingEvents.first { $0.end > now }
    }

    /// Debounced EventKit fetch: no-ops when a fetch ran within the last
    /// second, skips EventKit entirely (and clears the row) when access isn't
    /// granted, otherwise fetches off the main actor and applies the result
    /// back on it.
    public func refreshSnapshot() {
        guard self.isRunning else { return }
        guard self.access() == .granted else {
            self.clearUnavailableEvents()
            return
        }
        self.needsRefresh = true
        self.scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard self.isRunning, self.needsRefresh, self.fetchTask == nil else { return }
        let now = self.now()
        if let last = self.lastRefreshAt, now.timeIntervalSince(last) < 1 {
            self.scheduleCooldown(for: .seconds(max(0, 1 - now.timeIntervalSince(last))))
            return
        }
        self.cooldownTask?.cancel()
        self.cooldownTask = nil
        self.needsRefresh = false
        self.lastRefreshAt = now
        let generation = self.generation
        let calendar = Calendar.autoupdatingCurrent
        guard let end = calendar.date(
            byAdding: .day, value: Self.fetchWindowDays, to: calendar.startOfDay(for: now)
        ) else { return }
        let readEvents = self.readEvents
        self.fetchTask = Task { [weak self] in
            let events = await readEvents(now, end)
            guard let self else { return }
            self.fetchTask = nil
            guard self.isRunning else { return }
            guard self.access() == .granted else {
                self.clearUnavailableEvents()
                return
            }
            if !Task.isCancelled, self.generation == generation {
                self.apply(events)
            }
            self.scheduleRefresh()
        }
    }

    private func scheduleCooldown(for delay: Duration) {
        guard self.cooldownTask == nil else { return }
        let generation = self.generation
        let sleep = self.sleep
        self.cooldownTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled, self.isRunning, self.generation == generation else { return }
            self.cooldownTask = nil
            self.refreshSnapshot()
        }
    }

    private func clearUnavailableEvents() {
        self.generation += 1
        self.fetchTask?.cancel()
        self.cooldownTask?.cancel()
        self.cooldownTask = nil
        self.needsRefresh = false
        self.lastRefreshAt = nil
        self.apply([])
    }

    private nonisolated static func readEvents(start: Date, end: Date) async -> [CalendarEvent] {
        await withCheckedContinuation { continuation in
            self.fetchQueue.async {
                guard self.authorization == .granted else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: self.fetchUpcomingEvents(start: start, end: end))
            }
        }
    }

    /// Runs entirely off the main actor, on `fetchQueue`. A fresh
    /// `EKEventStore` is created here (rather than reusing the persistent
    /// `store` above) purely so no non-`Sendable` EventKit type has to cross
    /// the queue hop — only the `Sendable` `CalendarEvent` values this
    /// returns do.
    private nonisolated static func fetchUpcomingEvents(start: Date, end: Date) -> [CalendarEvent] {
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled && !Self.isDeclinedByOwner($0) }
            .map(Self.convert)
            .sorted { $0.start < $1.start }
            .prefix(Self.fetchCap)
        return Array(events)
    }

    private nonisolated static func isDeclinedByOwner(_ event: EKEvent) -> Bool {
        guard let attendees = event.attendees else { return false }
        return attendees.contains { $0.isCurrentUser && $0.participantStatus == .declined }
    }

    private nonisolated static func convert(_ event: EKEvent) -> CalendarEvent {
        CalendarEvent(
            eventIdentifier: event.eventIdentifier,
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            location: event.location,
            notes: event.notes,
            url: event.url,
            calendarTitle: event.calendar?.title,
            isAllDay: event.isAllDay
        )
    }

    private func apply(_ events: [CalendarEvent]) {
        guard events != self.upcomingEvents else { return }
        self.upcomingEvents = events
        self.snapshot.withLock { $0 = events }
        self.onChange()
    }

    // MARK: - Open in Calendar

    private static let icalDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Opens Calendar.app on this event via its private `ical://` deep link:
    /// first with the start time (disambiguates a recurring event's
    /// occurrence), then without it, then just activating Calendar.app if
    /// neither URL is handled.
    public static func openInCalendar(_ event: CalendarEvent) {
        let encodedID = event.eventIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? event.eventIdentifier
        let startStamp = self.icalDateFormatter.string(from: event.start)
        let candidates = [
            "ical://ekevent/\(startStamp)/\(encodedID)?method=show&options=more",
            "ical://ekevent/\(encodedID)?method=show&options=more",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
        if let calendarURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: calendarURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
