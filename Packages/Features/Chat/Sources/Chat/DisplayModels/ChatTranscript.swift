import Foundation

/// Where a message sits inside a run of consecutive same-sender messages.
/// Drives Telegram-style bubble grouping: reduced corner radii on the sides
/// facing run neighbors, and tighter spacing inside a run than between runs.
enum MessageRunPosition: Hashable, Sendable {
    case single
    case first
    case middle
    case last
}

/// One view-ready transcript bubble.
struct MessageRowModel: Hashable, Sendable, Identifiable {
    let id: String
    let body: String
    /// Short localized clock time, rendered inside the bubble's trailing edge.
    let timeText: String
    let isMine: Bool
    let position: MessageRunPosition
}

/// One day of the transcript; doubles as the diffable section identifier, so
/// it must stay stable across renders of the same content.
struct TranscriptDay: Hashable, Sendable {
    /// Start of day — the identity.
    let date: Date
    /// The pinned chip text: "Today", "Yesterday", or a localized date.
    let title: String
}

struct TranscriptSection: Equatable, Sendable {
    let day: TranscriptDay
    let rows: [MessageRowModel]
}

/// Pure assembly of the thread transcript from display models: splits into
/// day sections, groups same-sender messages sent within `runGap` into runs,
/// and formats bubble times. No UIKit — unit-tested directly.
enum ChatTranscript {
    /// Messages from the same sender at most this far apart share a run.
    static let runGap: TimeInterval = 5 * 60

    /// `messages` must be sorted oldest-first (the repository's contract).
    static func build(
        from messages: [MessageDisplayModel],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [TranscriptSection] {
        guard !messages.isEmpty else { return [] }

        var byDay: [(date: Date, messages: [MessageDisplayModel])] = []
        for message in messages {
            let day = calendar.startOfDay(for: message.sentAt)
            if byDay.last?.date == day {
                byDay[byDay.count - 1].messages.append(message)
            } else {
                byDay.append((day, [message]))
            }
        }

        let timeFormatter = makeFormatter(calendar)
        timeFormatter.timeStyle = .short
        return byDay.map { day, dayMessages in
            TranscriptSection(
                day: TranscriptDay(date: day, title: title(for: day, calendar: calendar, now: now)),
                rows: rows(for: dayMessages, formatter: timeFormatter)
            )
        }
    }

    private static func rows(for messages: [MessageDisplayModel], formatter: DateFormatter) -> [MessageRowModel] {
        messages.enumerated().map { index, message in
            let joinsPrevious = index > 0 && sharesRun(messages[index - 1], message)
            let joinsNext = index < messages.count - 1 && sharesRun(message, messages[index + 1])
            let position: MessageRunPosition = switch (joinsPrevious, joinsNext) {
            case (false, false): .single
            case (false, true): .first
            case (true, true): .middle
            case (true, false): .last
            }
            return MessageRowModel(
                id: message.id,
                body: message.body,
                timeText: formatter.string(from: message.sentAt),
                isMine: message.isMine,
                position: position
            )
        }
    }

    private static func sharesRun(_ earlier: MessageDisplayModel, _ later: MessageDisplayModel) -> Bool {
        earlier.senderID == later.senderID && later.sentAt.timeIntervalSince(earlier.sentAt) <= runGap
    }

    private static func title(for day: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = makeFormatter(calendar)
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMMd" : "MMMMdyyyy")
        return formatter.string(from: day)
    }

    private static func makeFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        return formatter
    }
}
