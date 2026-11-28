import CoreModels
import LaunchArguments
import MediaCore
import MediaUI
import PostGrid
import ThreadKit
import UIKit

/// Something that draws an author's relation badge: the bar's pill (#1972),
/// a text page's caption row and a list card's author band (#2300).
@MainActor
public protocol AuthorBadgeDrawing: AnyObject {
    /// Draws `badge`; `animated` is the binding's answer to "can it be seen
    /// to change now".
    func drawAuthorBadge(_ badge: PersonPill.Badge, animated: Bool)
    /// Whether a change drawn now would be seen: in a window.
    var drawsAuthorBadgeOnScreen: Bool { get }
}

/// Something that also draws the author's Follow beside its badge: a list
/// row's author band and a text page's caption row (#2419), from the same
/// answer as the badge, so the two never disagree.
@MainActor
public protocol AuthorFollowDrawing: AuthorBadgeDrawing {
    func drawAuthorFollow(_ offer: AuthorFollowOffer, animated: Bool)
}

/// ONE RELATION BINDING FOR EVERY AUTHOR PILL (#1972, the owner 2026-10-31):
/// the page's author on Shots showed no badge on its first pass, only once
/// the page was drawn again — while the bar's pill, re-read at every page
/// change, always caught up.
///
/// A pill is bound to the author it shows; the binding owns the rule end to
/// end:
/// - **on bind** (a configure, a reuse, a new author): the badge known now,
///   drawn at once; an unknown relation is asked for;
/// - **on an answer** for that author: EVERY pill bound to it is redrawn,
///   on screen or not — a page configured ahead of time (prefetched) wore
///   its bare face until a reconfigure, because only `visibleCells` heard;
/// - **on a viewer change**: every bound pill is redrawn, and every author
///   still unknown is asked again — an answer that stayed unknown through
///   the change reported nothing, and nothing asked again.
///
/// Its one source is `SnapAuthorFollowStore`, which reads the `EntityStore`
/// (#896). Pills are held weakly: a released cell needs no call.
@MainActor
final public class AuthorBadgeBinding {
    private let store: SnapAuthorFollowStore
    /// The bound pills by identity, held weakly.
    private var bound: [ObjectIdentifier: Bound] = [:]

    public init(store: SnapAuthorFollowStore) {
        self.store = store
    }

    /// Binds `pill` to `author` — nil unbinds it, drawing no badge — and
    /// draws what is known now, without animation. `offersFollow`: the pill
    /// also draws the author's Follow (#2419), where it can
    /// (`AuthorFollowDrawing`); otherwise it is told none.
    public func bind(_ pill: any AuthorBadgeDrawing, to author: ProfileID?, offersFollow: Bool = false) {
        guard let author else {
            bound[ObjectIdentifier(pill)] = nil
            pill.drawAuthorBadge(.none, animated: false)
            (pill as? any AuthorFollowDrawing)?.drawAuthorFollow(.none, animated: false)
            return
        }
        let entry = Bound(pill: pill, author: author, offersFollow: offersFollow)
        bound[ObjectIdentifier(pill)] = entry
        draw(entry, animated: false)
        trace("bind \(author.rawValue) known=\(store.relation(for: author) != nil) onScreen=\(pill.drawsAuthorBadgeOnScreen)")
        if store.relation(for: author) == nil { store.resolve(for: author) }
    }

    /// The author `pill` is bound to, if any.
    public func author(of pill: any AuthorBadgeDrawing) -> ProfileID? {
        guard let entry = bound[ObjectIdentifier(pill)], entry.pill === pill else { return nil }
        return entry.author
    }

    /// Draws `pill`'s badge again as known now, without animation: a page
    /// scrolling in shows the truth whatever it was configured with.
    public func reapply(_ pill: any AuthorBadgeDrawing) {
        guard let entry = bound[ObjectIdentifier(pill)], entry.pill === pill else { return }
        draw(entry, animated: false)
    }

    /// `author`'s answer changed: every pill bound to it, redrawn —
    /// animated where it can be seen.
    public func relationDidChange(for author: ProfileID) {
        prune()
        let entries = bound.values.filter { $0.author == author && $0.pill != nil }
        trace("answer \(author.rawValue) badge=\(store.badge(for: author)) pills=\(entries.count)")
        for entry in entries {
            draw(entry, animated: entry.pill?.drawsAuthorBadgeOnScreen == true)
        }
    }

    /// The viewer changed (a sign-in, a sign-out): every pill redrawn, and
    /// every author still unknown asked again.
    public func viewerDidChange() {
        prune()
        trace("viewer changed: \(bound.count) pills")
        var asked: Set<ProfileID> = []
        for entry in bound.values {
            guard let pill = entry.pill else { continue }
            let author = entry.author
            draw(entry, animated: pill.drawsAuthorBadgeOnScreen)
            if store.relation(for: author) == nil, asked.insert(author).inserted {
                store.resolve(for: author)
            }
        }
    }

    /// The live pills bound to `author`. Tests read it too.
    func pills(boundTo author: ProfileID) -> [any AuthorBadgeDrawing] {
        prune()
        return bound.values.compactMap { $0.author == author ? $0.pill : nil }
    }

    /// Draws `entry`'s badge, and its Follow where it offers one, as known now.
    private func draw(_ entry: Bound, animated: Bool) {
        guard let pill = entry.pill else { return }
        pill.drawAuthorBadge(store.badge(for: entry.author), animated: animated)
        guard let follows = pill as? any AuthorFollowDrawing else { return }
        follows.drawAuthorFollow(entry.offersFollow ? store.followOffer(for: entry.author) : .none, animated: animated)
    }

    /// Forgets the pills that went away.
    private func prune() {
        bound = bound.filter { $0.value.pill != nil }
    }

    /// `-author-badge-trace` (DEBUG): binds, answers and viewer changes.
    private func trace(_ line: @autoclosure () -> String) {
        #if DEBUG
        guard LaunchArgument.authorBadgeTrace.isPassed() else { return }
        print("[author-badge] \(line())")
        #endif
    }

    private struct Bound {
        weak var pill: (any AuthorBadgeDrawing)?
        let author: ProfileID
        let offersFollow: Bool
    }
}

/// A text page's author face (#2300) and its Follow left of the ♥ count
/// (#2419): its caption's row, as the screen's binding draws it — bound at
/// configure, redrawn on every answer.
extension CaptionBubbleCell: AuthorFollowDrawing {
    public func drawAuthorBadge(_ badge: PersonPill.Badge, animated: Bool) {
        setAuthorMark(badge, animated: animated)
    }

    public func drawAuthorFollow(_ offer: AuthorFollowOffer, animated: Bool) {
        setAuthorFollowOffer(offer, animated: animated)
    }

    public var drawsAuthorBadgeOnScreen: Bool { window != nil }
}

/// A list card's author band (#2300): the flat rows and a shelf's text card,
/// bound by their host through `PostAuthorMarks`. The flat rows draw its
/// Follow too (#2419); a shelf's card is told none.
extension PostGridListRowCell: AuthorFollowDrawing {
    public func drawAuthorBadge(_ badge: PersonPill.Badge, animated: Bool) {
        setAuthorRelationMark(badge, animated: animated)
    }

    public func drawAuthorFollow(_ offer: AuthorFollowOffer, animated: Bool) {
        setAuthorFollowOffer(offer, animated: animated)
    }

    public var drawsAuthorBadgeOnScreen: Bool { window != nil }
}
