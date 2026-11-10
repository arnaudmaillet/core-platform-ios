import UIKit

/// How the VERTICAL post lists draw a text post (#2243, the owner
/// 2026-11-10): today's white cards on the grey page, or flat rows on a white
/// page with a separator between posts — Threads', X's and Bluesky's
/// timeline.
///
/// ⚠️ AN A/B, NOT A DECISION. Flat reverses the 2026-09-24 one (#186, #187:
/// grey page, white cards) across the whole app, so the owner compares both
/// on his device first. `-post-list-style flat` turns it on (the debug
/// dashboard's "Flat post lists" switch persists it); without it, today's
/// cards, unchanged. A follow-up removes the flag and the losing style.
///
/// ⚠️ READ HERE, AND ONLY HERE. The pages and the cells TAKE a style — a
/// page is built with one (`ForYouGridPage.listStyle`) and hands it to its
/// layout and its rows — so nothing else asks the launch arguments, and a
/// test builds either style without touching them.
///
/// What goes flat: a text post in a vertical list (the Feed, the profile's
/// pages, the place page, a post set, a pushed list). What does not: a media
/// tile (the one tile contract, 2026-10-16), a horizontal shelf's cards, the
/// map's bubble, For You's preview, a shared post.
public enum PostListStyle: String, Sendable, CaseIterable {
    /// Today: white cards on the grouped grey page.
    case cards
    /// No card: rows on the plain page, a hairline between them (#2243).
    case flat

    /// The launch argument: `-post-list-style flat`. A VALUED argument, so
    /// it is read by position; a bare `-post-list-style` is flat, the
    /// dashboard switch's meaning.
    public static let argument = "-post-list-style"

    /// The style of this launch. Read once: a page is built with it, and the
    /// switch takes effect on the next launch (`DebugFlags.Flag.appliesAtLaunch`).
    public static let current: PostListStyle = resolve(
        arguments: ProcessInfo.processInfo.arguments,
        switchedOn: { DebugFlags.isOn("-post-list-style") }
    )

    /// The style `arguments` ask for: the argument's value when it is
    /// passed — so a QA run asks for either style whatever the dashboard
    /// says — else the persisted switch (DEBUG; `DebugFlags` reads nothing
    /// persisted in Release). Pure, for tests.
    static func resolve(arguments: [String], switchedOn: () -> Bool) -> PostListStyle {
        if let index = arguments.firstIndex(of: argument) {
            let value = arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
            // A bare flag (or a value that is another argument) means flat.
            return PostListStyle(rawValue: value) ?? .flat
        }
        return switchedOn() ? .flat : .cards
    }

    /// What a page of posts lies on: the grouped grey under cards, the plain
    /// background (white, black in the dark) under flat rows — see `Surface`.
    public var pageGround: UIColor {
        switch self {
        case .cards: Surface.page
        case .flat: Surface.plainPage
        }
    }

    /// A card's tone ON this style's page — a text tile, a shelf's text
    /// card. On the grey page it is the white card, lighter than its page;
    /// on the white page a white card would vanish, so it takes the plain
    /// page's grey step instead (#2243). Identical in the dark.
    public var cardFill: UIColor {
        switch self {
        case .cards: Surface.card
        case .flat: Surface.cardOnPlainPage
        }
    }
}
