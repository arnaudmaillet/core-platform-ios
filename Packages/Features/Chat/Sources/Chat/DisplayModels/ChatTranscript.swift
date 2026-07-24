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

/// A resolved reference to the message a reply answers — the quoted preview
/// shown at the top of a reply bubble, and the target of tap-to-scroll.
struct QuotedReply: Hashable, Sendable {
    /// The original message's id — the scroll/highlight target.
    let messageID: String
    /// Who wrote the quoted message: "You" or the correspondent's name.
    let author: String
    /// A single-line excerpt of the quoted body.
    let snippet: String
}

/// One view-ready transcript bubble.
struct MessageRowModel: Hashable, Sendable, Identifiable {
    let id: String
    let body: String
    /// Short localized clock time, rendered inside the bubble's trailing edge.
    let timeText: String
    let isMine: Bool
    let position: MessageRunPosition
    /// The quoted original when this bubble is a reply; `nil` otherwise.
    let quote: QuotedReply?
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
    /// `peerName` labels the author of quoted messages the viewer didn't send.
    static func build(
        from messages: [MessageDisplayModel],
        peerName: String = "",
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [TranscriptSection] {
        guard !messages.isEmpty else { return [] }

        // A reply can quote a message from any earlier day, so resolve against
        // the full set before splitting into day sections.
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

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
                rows: rows(for: dayMessages, formatter: timeFormatter, byID: byID, peerName: peerName)
            )
        }
    }

    private static func rows(
        for messages: [MessageDisplayModel],
        formatter: DateFormatter,
        byID: [String: MessageDisplayModel],
        peerName: String
    ) -> [MessageRowModel] {
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
                position: position,
                quote: quote(for: message, byID: byID, peerName: peerName)
            )
        }
    }

    /// The quoted preview for a reply — resolved from the referenced message,
    /// or `nil` if this isn't a reply or the original is gone (e.g. deleted).
    private static func quote(
        for message: MessageDisplayModel,
        byID: [String: MessageDisplayModel],
        peerName: String
    ) -> QuotedReply? {
        guard let replyToID = message.replyToID, let original = byID[replyToID] else { return nil }
        return QuotedReply(
            messageID: original.id,
            author: quoteAuthor(isMine: original.isMine, peerName: peerName),
            snippet: snippet(original.body)
        )
    }

    /// The display name for a quoted message's author: "You" for the viewer's
    /// own, the correspondent's name otherwise (a neutral fallback covers the
    /// brief window before the peer name resolves). Shared by the bubble quote
    /// and the compose bar's reply preview.
    static func quoteAuthor(isMine: Bool, peerName: String) -> String {
        isMine ? "You" : (peerName.isEmpty ? "Message" : peerName)
    }

    /// Collapses a body to a single tidy line for the quoted preview; the
    /// label handles visual truncation.
    static func snippet(_ body: String) -> String {
        body.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
