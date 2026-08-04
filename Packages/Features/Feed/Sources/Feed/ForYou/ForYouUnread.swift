import Foundation
import PostGrid

/// "How much has arrived on this tab since you last looked at it" — the count
/// the top tab capsule badges.
///
/// **Derived, not stored as a count.** What persists is a *watermark* per
/// format: the publication time of the newest post the viewer had in front of
/// them the last time that tab was on screen. The badge is then a pure function
/// of the loaded corpus and that watermark, which means it cannot drift out of
/// step with what the grid is actually showing — there is no counter to
/// increment, decrement, or forget to clear.
///
/// **A first sight is never "all new".** With no watermark yet — a fresh
/// install, a new format — every post in the corpus is technically newer than
/// nothing, and badging "40 new" on first launch would be both useless and
/// wrong: the viewer has not missed anything, they have simply not been here.
/// `seedIfUnseen` writes the watermark on first sight and reports zero, so the
/// first count a viewer ever sees is genuinely "since your last visit".
enum ForYouUnread {
    /// Posts published strictly after the watermark. Strictly, so re-marking a
    /// tab with unchanged content lands on zero rather than one.
    ///
    /// Counted rather than capped here: the cap belongs to the badge, which
    /// renders "99+" past its own legibility limit. A caller that needs the
    /// real number (a test, a log) gets the real number.
    static func count(in posts: [GalleryPost], since watermarkMS: Int64) -> Int {
        posts.reduce(into: 0) { total, post in
            if post.publishedAtMS > watermarkMS { total += 1 }
        }
    }

    /// The watermark a tab adopts when it is read: the newest publication time
    /// currently loaded on it. `nil` for an empty page — a tab with nothing on
    /// it must not move its watermark forward, or content that arrives a moment
    /// later would be silently counted as already seen.
    static func watermark(of posts: [GalleryPost]) -> Int64? {
        posts.map(\.publishedAtMS).max()
    }
}

/// The per-format watermarks, persisted so "since you last looked" survives a
/// relaunch — which is the whole point of the badge.
///
/// Keyed under its own prefix rather than sharing `GalleryPreferences`': that
/// type owns the *filter* pair and its default prefix is the profile gallery's,
/// which For You must never write to (see its note on why the default is
/// load-bearing).
public final class ForYouUnreadStore {
    private let defaults: UserDefaults
    private let keyPrefix: String
    /// Formats whose count is currently being forced by a launch argument.
    /// Consumed by the first `markSeen` for that format, so a QA run can watch
    /// a badge render AND watch it clear.
    private var forced: [GalleryFilter.Format: Int]

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "foryou.unread",
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        forced = Self.forcedCounts(from: arguments)
    }

    /// Stages `count` unread items on `format`, so the badge shows that many.
    ///
    /// This is what `-foryou-mock-new-activity` drives, and it takes the
    /// truthful route whenever the corpus allows: back-date the watermark to
    /// just before the `count` newest posts, and let the ordinary derivation
    /// produce the number. That puts the whole path under test — watermark,
    /// comparison, publication, and the clearing that follows a read — rather
    /// than proving only that a pill can be drawn.
    ///
    /// When the corpus is smaller than the number asked for, the watermark
    /// cannot express it (there is no timestamp that leaves 99 posts above it
    /// in a corpus of 40), so the count is stated outright instead. The badge is
    /// then a claim about nothing, which is exactly what a QA argument asking
    /// for "99" wants: the pill at its widest, against the real layout. Either
    /// way it clears through the ordinary `markSeen` path when the tab is read.
    public func stageUnread(_ count: Int, for format: GalleryFilter.Format, in posts: [GalleryPost]) {
        guard count > 0 else { return }
        let times = posts.map(\.publishedAtMS).sorted(by: >)
        guard times.count > count else {
            // Not expressible as a watermark — state it. `forced` is the same
            // channel `-foryou-badges` uses, including its clear-on-tab-change
            // behaviour, so nothing new has to be taught to clear it.
            forced[format] = count
            return
        }
        // The (count+1)-th newest: strictly older than the `count` posts above
        // it, which is exactly the watermark that makes those `count` unread.
        forced[format] = nil
        defaults.set(times[count], forKey: key(for: format))
    }

    /// The badge for a format, given everything currently loaded on it.
    ///
    /// Seeds the watermark on first sight, so an unvisited format reports zero
    /// rather than its entire corpus.
    public func count(for format: GalleryFilter.Format, in posts: [GalleryPost]) -> Int {
        if let forcedCount = forced[format] { return forcedCount }
        guard let stored = watermark(for: format) else {
            seedIfUnseen(format, in: posts)
            return 0
        }
        return ForYouUnread.count(in: posts, since: stored)
    }

    /// The viewer is looking at this tab: everything on it is now seen.
    ///
    /// `clearingOverride` separates the two callers. A tab CHANGE is a person
    /// reading a tab, and retires any `-foryou-badges` value on it. The
    /// automatic advance that happens whenever content lands on the tab already
    /// showing must not: it runs on the very first publish, and would wipe a
    /// forced badge before it had rendered a single frame.
    public func markSeen(
        _ format: GalleryFilter.Format,
        in posts: [GalleryPost],
        clearingOverride: Bool = false
    ) {
        if clearingOverride { forced[format] = nil }
        guard let newest = ForYouUnread.watermark(of: posts) else { return }
        // Never move a watermark BACKWARDS. A source change re-filters the
        // corpus, and a narrower ordering can leave a tab whose newest loaded
        // post is older than one already seen — rewinding there would resurrect
        // a badge for posts the viewer has read.
        guard newest > (watermark(for: format) ?? .min) else { return }
        defaults.set(newest, forKey: key(for: format))
    }

    /// Records a watermark for a format that has never had one, without
    /// reporting anything as unread.
    private func seedIfUnseen(_ format: GalleryFilter.Format, in posts: [GalleryPost]) {
        guard watermark(for: format) == nil, let newest = ForYouUnread.watermark(of: posts) else { return }
        defaults.set(newest, forKey: key(for: format))
    }

    private func watermark(for format: GalleryFilter.Format) -> Int64? {
        // `object(forKey:)` rather than `integer(forKey:)`: the absent case is
        // the one that decides whether a format has ever been seen, and
        // `integer` folds it into 0 — which would read as "seen, at the epoch"
        // and badge the whole corpus.
        guard defaults.object(forKey: key(for: format)) != nil else { return nil }
        return Int64(defaults.integer(forKey: key(for: format)))
    }

    private func key(for format: GalleryFilter.Format) -> String {
        keyPrefix + "." + Self.name(for: format)
    }

    private static func name(for format: GalleryFilter.Format) -> String {
        switch format {
        case .activity: "activity"
        case .media: "media"
        case .short: "short"
        }
    }

    /// `-foryou-badges 3,0,1` — counts for Activity, Gallery and Short in pager
    /// order.
    ///
    /// Exists because the honest derivation is very hard to *see* on demand: it
    /// needs posts published between two visits, which against a fixed mock
    /// corpus means editing fixtures and relaunching. This forces the render so
    /// the capsule's badge geometry (which re-pins segment widths and moves the
    /// lens) can be checked in both appearances, and clears through the real
    /// `markSeen` path so the clearing is exercised too.
    private static func forcedCounts(from arguments: [String]) -> [GalleryFilter.Format: Int] {
        #if DEBUG
        guard let position = arguments.firstIndex(of: "-foryou-badges"),
              position + 1 < arguments.count
        else { return [:] }
        let counts = arguments[position + 1].split(separator: ",").compactMap { Int($0) }
        // Pager order: Discover, then Following. Taken from `ForYouViewModel`
        // rather than `ForYouPagerView.pageOrder` because that one is
        // `@MainActor` by inference (a `UIView` subclass's statics are) and this
        // store is deliberately un-isolated so its logic stays testable off the
        // main actor. `ForYouUnreadTests` pins the two orders together.
        return zip(ForYouViewModel.tabs, counts).reduce(into: [:]) { result, pair in
            if pair.1 > 0 { result[pair.0] = pair.1 }
        }
        #else
        return [:]
        #endif
    }
}
