import CoreModels
import MediaCore
import UIKit

/// Something that draws an author's relation badge: the page's author row,
/// the bar's pill (#1972).
@MainActor
protocol AuthorBadgeDrawing: AnyObject {
    /// Draws `badge`; `animated` is the binding's answer to "can it be seen
    /// to change now".
    func drawAuthorBadge(_ badge: PersonPill.Badge, animated: Bool)
    /// Whether a change drawn now would be seen: in a window.
    var drawsAuthorBadgeOnScreen: Bool { get }
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
final class AuthorBadgeBinding {
    private let store: SnapAuthorFollowStore
    /// The bound pills by identity, held weakly.
    private var bound: [ObjectIdentifier: Bound] = [:]

    init(store: SnapAuthorFollowStore) {
        self.store = store
    }

    /// Binds `pill` to `author` — nil unbinds it, drawing no badge — and
    /// draws what is known now, without animation.
    func bind(_ pill: any AuthorBadgeDrawing, to author: ProfileID?) {
        guard let author else {
            bound[ObjectIdentifier(pill)] = nil
            pill.drawAuthorBadge(.none, animated: false)
            return
        }
        bound[ObjectIdentifier(pill)] = Bound(pill: pill, author: author)
        pill.drawAuthorBadge(store.badge(for: author), animated: false)
        trace("bind \(author.rawValue) known=\(store.relation(for: author) != nil) onScreen=\(pill.drawsAuthorBadgeOnScreen)")
        if store.relation(for: author) == nil { store.resolve(for: author) }
    }

    /// The author `pill` is bound to, if any.
    func author(of pill: any AuthorBadgeDrawing) -> ProfileID? {
        guard let entry = bound[ObjectIdentifier(pill)], entry.pill === pill else { return nil }
        return entry.author
    }

    /// Draws `pill`'s badge again as known now, without animation: a page
    /// scrolling in shows the truth whatever it was configured with.
    func reapply(_ pill: any AuthorBadgeDrawing) {
        guard let author = author(of: pill) else { return }
        pill.drawAuthorBadge(store.badge(for: author), animated: false)
    }

    /// `author`'s answer changed: every pill bound to it, redrawn —
    /// animated where it can be seen.
    func relationDidChange(for author: ProfileID) {
        let badge = store.badge(for: author)
        let pills = pills(boundTo: author)
        trace("answer \(author.rawValue) badge=\(badge) pills=\(pills.count) onScreen=\(pills.filter(\.drawsAuthorBadgeOnScreen).count)")
        for pill in pills {
            pill.drawAuthorBadge(badge, animated: pill.drawsAuthorBadgeOnScreen)
        }
    }

    /// The viewer changed (a sign-in, a sign-out): every pill redrawn, and
    /// every author still unknown asked again.
    func viewerDidChange() {
        prune()
        trace("viewer changed: \(bound.count) pills")
        var asked: Set<ProfileID> = []
        for entry in bound.values {
            guard let pill = entry.pill else { continue }
            let author = entry.author
            pill.drawAuthorBadge(store.badge(for: author), animated: pill.drawsAuthorBadgeOnScreen)
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

    /// Forgets the pills that went away.
    private func prune() {
        bound = bound.filter { $0.value.pill != nil }
    }

    /// `-author-badge-trace` (DEBUG): binds, answers and viewer changes.
    private func trace(_ line: @autoclosure () -> String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-author-badge-trace") else { return }
        print("[author-badge] \(line())")
        #endif
    }

    private struct Bound {
        weak var pill: (any AuthorBadgeDrawing)?
        let author: ProfileID
    }
}
