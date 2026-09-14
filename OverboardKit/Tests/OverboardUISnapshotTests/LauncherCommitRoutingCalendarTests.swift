import Foundation
import OverboardCore
import OverboardMac
@testable import OverboardUI
import Testing

/// Pure logic, no snapshots — runs on CI too. Routing for the
/// calendar-event actions (join, copy link, open in Calendar), split out of
/// `LauncherCommitRoutingTests` by routed result kind, same shape as
/// `LauncherCommitRoutingHistoryTests`.
@Suite(.serialized)
@MainActor
struct LauncherCommitRoutingCalendarTests {
    private func event(url: URL? = nil) -> CalendarEvent {
        CalendarEvent(
            eventIdentifier: "evt1",
            title: "Standup",
            start: Date(),
            end: Date().addingTimeInterval(1800),
            url: url
        )
    }

    /// ↩ on a calendar event with a detected join link runs it.
    @Test func joinMeetingRoutesOnPlainReturn() async throws {
        let url = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        let event = self.event(url: url)
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.calendarEvent(event)])

        var joined: [(event: CalendarEvent, url: URL)] = []
        viewModel.onJoinMeeting = { joined.append(($0, $1)) }

        viewModel.commit()

        #expect(joined.map(\.event) == [event])
        #expect(joined.map(\.url) == [url])
    }

    /// ⌘↩ on a calendar event with a detected join link copies it.
    @Test func copyMeetingLinkRoutesOnCommandReturn() async throws {
        let url = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        let event = self.event(url: url)
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.calendarEvent(event)])

        var copied: [URL] = []
        viewModel.onCopyMeetingLink = { _, url in copied.append(url) }

        viewModel.commit(modifier: .command)

        #expect(copied == [url])
    }

    /// ⌥↩ opens Calendar.app on the event, even when it has a join link.
    @Test func openInCalendarRoutesOnOptionReturn() async throws {
        let url = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        let event = self.event(url: url)
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.calendarEvent(event)])

        var opened: [CalendarEvent] = []
        viewModel.onOpenInCalendar = { opened.append($0) }

        viewModel.commit(modifier: .option)

        #expect(opened == [event])
    }

    /// With no join link, Open in Calendar is the only action — plain ↩ runs it.
    @Test func linklessEventOpensCalendarOnPlainReturn() async {
        let event = self.event()
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.calendarEvent(event)])

        var opened: [CalendarEvent] = []
        viewModel.onOpenInCalendar = { opened.append($0) }

        viewModel.commit()

        #expect(opened == [event])
    }

    /// `pinnedResults` puts the calendar row before the now-playing row, and
    /// on an empty query that order is preserved verbatim (no re-sort). The
    /// empty field also lists recent searches from the process-wide
    /// `Defaults[.launcherSearchHistory]`, which other suites write, so only
    /// the pinned suffix is asserted.
    @Test func calendarPinsBeforeNowPlayingOnEmptyQuery() async {
        let event = self.event()
        let track = LauncherCommitRoutingFixtures.track
        let viewModel = LauncherViewModel(instantProviders: [], secondaryProviders: [])
        viewModel.pinnedResults = { [.calendarEvent(event), .nowPlaying(track)] }

        viewModel.query = ""
        viewModel.scheduleSearch()
        await viewModel.settle()

        #expect(viewModel.results.suffix(2) == [.calendarEvent(event), .nowPlaying(track)])
    }

    /// A calendar event surfaced by both the instant provider (matching the
    /// query) and `pinnedResults` (the up-next row) appears once, not twice.
    @Test func pinnedCalendarDedupsAgainstProviderRow() async {
        let event = self.event()
        let viewModel = LauncherViewModel(
            instantProviders: [StubProvider(rows: [.calendarEvent(event)])],
            secondaryProviders: []
        )
        viewModel.pinnedResults = { [.calendarEvent(event)] }

        viewModel.query = "cal"
        viewModel.scheduleSearch()
        await viewModel.settle()

        #expect(viewModel.results.filter { $0.id == LauncherResult.calendarEvent(event).id }.count == 1)
    }
}
