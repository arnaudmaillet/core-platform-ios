import UIKit

extension InteractiveSlideDismissal {
    /// Arms this driver as the CARD-shaped close of a screen that was opened by
    /// a hero FLIGHT, for the posts that flight cannot carry home.
    ///
    /// ⚠️ THE PRESENTATION IS CHOSEN AT THE TAP, AND THE FEED IS A PAGER. A
    /// media post opens with a hero; page onto a text post and there is no
    /// media left for that hero to fly. Both zoom grabs refuse a `.card` close
    /// before they look at an axis, the flight's own pop animator declines it
    /// too, and the push has already disclaimed the stack's native edge swipe.
    /// A screen with nothing else attached therefore has NO drag at all on a
    /// text page, and its chevron falls through to UIKit's plain pop — which is
    /// how a profile's Activity tab was filmed: open a clip, page to a text
    /// post, close, and the list comes back on a cut.
    ///
    /// ONE implementation, because there were three hand-written copies of it
    /// (For You's grid, the place page's tiles, and none at all for a profile)
    /// and the missing one is the defect above. Every host now gets the same
    /// rules from here:
    ///
    /// * **both axes**, like every other card close;
    /// * **arbitrated** against the hero grab, so each side refuses the other's
    ///   kind and exactly one driver claims any drag;
    /// * `stage` runs **only for a close that carries a card** — this hook is
    ///   asked for every pop, a hero's included, and staging a card close
    ///   CONCEALS the landing, so a flight arriving on it reads as no animation
    ///   at all;
    /// * `stage` runs **once** per presentation — a swipe asks twice (when the
    ///   grab claims the screen, and again when the pop asks for an animator),
    ///   and a staging that moves a card would undo itself the second time.
    ///
    /// `stage` returns whether it staged. `false` leaves the latch open so a
    /// later ask can try again — a host that could not yet answer (nothing
    /// settled) is not the same as one that answered.
    ///
    /// What stays with the host is what genuinely differs: the landing's
    /// geometry, which `stage` writes into `revealGeometry` (or leaves nil for
    /// the plain slide), and the host's own `install(on:)`, which must come
    /// AFTER the flight took the delegate slot so a `.hero` pop is forwarded
    /// straight back to it.
    public func armAsCardCloseAlongsideFlight(
        on feed: UIViewController,
        stage: @escaping (UIViewController) -> Bool
    ) {
        armAsCardCloseAlongsideFlight(
            on: feed, restagesOnEveryAttempt: false
        ) { feed, _ in stage(feed) }
    }

    /// The same arming, for a host whose landing depends on the AXIS.
    ///
    /// ⚠️ ONE STAGING CANNOT DESCRIBE TWO LANDINGS. The map's hero feed closes
    /// rightward (and by its chevron) onto the MARKER, and downward onto its
    /// place page's card — a different screen, a different rect. Latched after
    /// the first staging, a vertical grab abandoned half-way would leave the
    /// place page's geometry armed for the chevron that follows, and the
    /// window would shrink onto a tile that is not on screen. So:
    ///
    /// * `stage` is handed the axis the dismissal travels on (`.horizontal`
    ///   for a pop with no gesture — the back button's direction);
    /// * `restagesOnEveryAttempt` turns the once-only latch OFF: `stage` is
    ///   asked on every card-carrying ask, and making a staging that MOVES
    ///   something idempotent becomes the host's job (its return value is then
    ///   informational only).
    ///
    /// Everything else — both axes, the arbitration, the card-only gate, the
    /// reset — is the one-closure form's, which forwards here with the latch on.
    public func armAsCardCloseAlongsideFlight(
        on feed: UIViewController,
        restagesOnEveryAttempt: Bool,
        stage: @escaping (_ feed: UIViewController, _ axis: ZoomDismissAxis) -> Bool
    ) {
        // Nothing from the last opening survives into this one — see
        // `resetForNewPresentation`.
        resetForNewPresentation()
        arbitratesWithHeroGrab = true
        attach(to: feed, axes: [.horizontal, .vertical])
        var hasStaged = false
        prepareForDismissal = { [weak feed] axis in
            guard !hasStaged, let feed,
                  // Asked of the same authority both grabs gate on, so the
                  // three can never disagree about what the post is.
                  (feed as? any ZoomTransitionDestination)?.zoomDismissalKind == .card
            else { return }
            let staged = stage(feed, axis)
            if !restagesOnEveryAttempt { hasStaged = staged }
        }
    }
}
