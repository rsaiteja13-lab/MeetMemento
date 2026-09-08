import EventKit
import Foundation

final class CalendarEventMatcher {
    private let eventStore = EKEventStore()

    func title(forMeetingAt date: Date) -> String? {
        guard Permissions.calendarAccessGranted else { return nil }
        let calendar = Calendar.current
        guard let searchStart = calendar.date(byAdding: .hour, value: -4, to: date),
              let searchEnd = calendar.date(byAdding: .hour, value: 4, to: date) else { return nil }

        let predicate = eventStore.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: nil)
        let tolerance: TimeInterval = 15 * 60
        let candidates = eventStore.events(matching: predicate).filter { event in
            !event.isAllDay
                && event.startDate <= date.addingTimeInterval(tolerance)
                && event.endDate >= date.addingTimeInterval(-tolerance)
                && !(event.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }

        let best = candidates.max { left, right in
            score(left, at: date) < score(right, at: date)
        }
        return best?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func score(_ event: EKEvent, at date: Date) -> Double {
        var value = 0.0
        if event.startDate <= date && event.endDate >= date { value += 20 }
        let searchable = [event.location, event.url?.absoluteString, event.notes]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if searchable.contains("zoom") { value += 10 }
        value -= abs(event.startDate.timeIntervalSince(date)) / 60
        return value
    }
}
