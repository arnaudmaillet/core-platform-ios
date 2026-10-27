import DesignSystem
import UIKit

/// THE LOADING LADDER (#1085): one contract for every view that shows content
/// arriving in steps — skeleton, placeholder, preview, content — so the order,
/// the state machine and the transitions between the steps are written once,
/// not once per screen.
///
/// ```
///   z-order, bottom to top          a view declares the rungs it uses
///   background ─ skeleton ─ placeholder ─ preview ─ content ─ (overlay, state)
///   (ground)    (bone)     (initials,    (thumb,   (picture,
///                           blurhash)     poster,   live video)
///                                         parked)
/// ```
///
/// ⚠️ **NOT ONE CLASS FOR EVERY KIND OF CONTENT.** Video and emotes have
/// removal signals and motion of their own (the first frame, the Lottie
/// bake, the spring). The ladder is the contract they share — the rungs,
/// their order, the state machine, the transition policy — and thin views
/// sit on it: `ImageContentView` here, the avatar view (#943) and the media
/// surface (#1088) next. `EmoteSkeleton` keeps its own machine (#1071).
///
/// ## The rules, written once
/// - **A warm hit draws in the configure pass**, with no animation and no
///   one-frame flash (`show(_:warm:)`).
/// - **A late arrival animates**, with the transition its rung names
///   (`Transition`). Every one is a dissolve or a cut today, and a dissolve
///   IS the Reduce Motion substitute, so none changes under it; a spring or
///   a scale added here reads `MotionPreference` and becomes a dissolve.
/// - **A new item cuts** (`begin(item:)`): the generation moves on, a late
///   answer for the old one lands nowhere, and no transition of the old one
///   runs on the reused view.
/// - **A rung never changes the view's size**: the ladder only shows and
///   hides the views a host lays out.
/// - **A skeleton shows late and stays briefly** (`Policy.skeletonDelay`,
///   `Policy.skeletonMinimum`): no bone for a load that lands at once, and
///   no one-frame bone for one that lands just after the delay.
/// - **`isSettled`** says the content (or a failure) has landed, for a push
///   that waits on it.
///
/// ## The hero's hooks (#1085, "Hero transitions: compatibility requirements")
/// The zoom hero addresses its sources' layers by name, lends live surfaces
/// between views and drives a card's blend itself. So:
/// 1. the rung views stay addressable (`view(for:)`, `renderedPreview`);
/// 2. **one driver per alpha**: a rung registered with `drivesAlpha: false`
///    (a live video surface, `revealOnFirstFrame`'s) is never faded here;
/// 3. **held** (`hold()` … `release()`): no transition runs, and a late
///    arrival lands at the release, without animation;
/// 4. **lent content** (`lendContent()` … `reclaimContent()`): the content
///    view is owned elsewhere — the ladder neither steps back nor touches it;
/// 5. **monotonic within one item**: a lower rung after a higher one, or a
///    readiness drop (`contentDropped()`), never steps back;
/// 6. **a flight card** (`isFlightCard`) draws its source's state at once:
///    no skeleton delay, no transition;
/// 7. **a parked frame outranks the pipeline's thumbnail**
///    (`PreviewSource.parked`);
/// 8. **reconfigure is not reuse**: `begin(item:)` with the item already
///    shown keeps the generation and cuts nothing;
/// 9. **the fade law**: one operand moves — the arriving rung fades IN over
///    the ones below, which stay opaque until it lands.
@MainActor
public final class LoadingLadder {
    /// The rungs, in z-order. Each view declares the ones it uses.
    public enum Rung: Int, Comparable, CaseIterable, Sendable {
        case background
        /// A bone (`SkeletonBoneView`): a predictable shape, not yet filled.
        case skeleton
        /// A floor that says what is coming: initials, a blurhash, a glyph.
        case placeholder
        /// A first look: a thumbnail, a poster, a parked frame.
        case preview
        /// The content itself.
        case content

        public static func < (lhs: Rung, rhs: Rung) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// How a rung arrives over the ones below — a host picks a kind, never a
    /// duration.
    public enum Transition: Equatable, Sendable {
        /// Drawn in the same pass: a warm hit, a cut, a hold's release.
        case none
        /// A dissolve: "a picture arrives", "a skeleton leaves" — 0.25 s, the
        /// app's settled value (`SkeletonCrossfade`). It is also the Reduce
        /// Motion substitute, so it stays under Reduce Motion.
        case dissolve(TimeInterval)
        /// A live surface's first frame: one frame, owned by the surface
        /// (`VideoRenderView`); the ladder writes no alpha for it.
        case firstFrame

        public static let pictureArrives = Transition.dissolve(0.25)
    }

    /// Where a preview came from: a parked frame (playback handing a tile the
    /// frame it left on) outranks the pipeline's thumbnail that lands later.
    public enum PreviewSource: Int, Comparable, Sendable {
        case pipeline
        case parked

        public static func < (lhs: PreviewSource, rhs: PreviewSource) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The timing a ladder keeps.
    public struct Policy: Sendable {
        /// A skeleton appears only if nothing better has arrived by then.
        public var skeletonDelay: TimeInterval
        /// Once shown, a skeleton stays at least this long: a load that lands
        /// just after the delay never flashes a bone for a frame.
        public var skeletonMinimum: TimeInterval
        /// How content arrives late.
        public var contentArrives: Transition
        /// How a preview arrives late.
        public var previewArrives: Transition

        public init(
            skeletonDelay: TimeInterval = LoadingTiming.skeletonDelay, skeletonMinimum: TimeInterval = LoadingTiming.minimum,
            contentArrives: Transition = .pictureArrives, previewArrives: Transition = .pictureArrives
        ) {
            self.skeletonDelay = skeletonDelay
            self.skeletonMinimum = skeletonMinimum
            self.contentArrives = contentArrives
            self.previewArrives = previewArrives
        }

        public static let standard = Policy()
    }

    /// Time, injectable: a test steps it — the loading kit's one clock.
    public typealias Clock = LoadingClock

    /// A ticket for one item's answers: an answer with a stale one lands
    /// nowhere.
    public struct Token: Equatable, Sendable {
        let generation: Int
    }

    // MARK: - State

    public let policy: Policy
    private let clock: Clock

    /// The highest rung shown for the current item; nil before any.
    public private(set) var rung: Rung?
    /// The item on show; a different one is a reuse.
    public private(set) var item: AnyHashable?
    public private(set) var generation = 0
    /// The current item failed: the highest rung reached stays.
    public private(set) var hasFailed = false
    /// Content (or a failure) has landed — for a push that waits.
    public var isSettled: Bool { rung == .content || hasFailed }
    /// Told once each item settles.
    public var onSettled: (() -> Void)?
    /// Told as each rung lands, with how — for a host that draws a rung
    /// itself rather than registering its view: a hero source's cover, whose
    /// view the ladder never touches (`CoverSlot`). Called before the rungs
    /// below leave, in the same pass, so a dissolve the host runs carries
    /// the bone's leaving too.
    public var onLand: ((Rung, Transition) -> Void)?

    /// Held by a flight: no transition runs (hook 3).
    public private(set) var isHeld = false
    /// The content view is lent to another view (hook 4).
    public private(set) var isContentLent = false
    /// A flight card: draws its source's state at once (hook 6).
    public var isFlightCard = false

    /// The preview's source, when one is shown.
    public private(set) var previewSource: PreviewSource?

    /// What a test reads: the transitions the ladder decided, in order.
    public private(set) var transitions: [(Rung, Transition)] = []

    private var views: [Rung: (view: UIView, drivesAlpha: Bool, permanent: Bool)] = [:]
    private var skeletonShownAt: TimeInterval?
    private var pendingWhileHeld: Rung?
    private var revealGeneration = 0

    public init(policy: Policy = .standard, clock: Clock = .system) {
        self.policy = policy
        self.clock = clock
    }

    // MARK: - Views

    /// Registers the view that draws `rung` (hook 1: it stays addressable).
    ///
    /// - Parameters:
    ///   - drivesAlpha: false for a view whose alpha someone else owns — a
    ///     live surface revealed on its first frame (hook 2).
    ///   - permanent: a floor that stays under what covers it — an avatar's
    ///     initials — rather than leaving once covered.
    public func setView(_ view: UIView?, for rung: Rung, drivesAlpha: Bool = true, permanent: Bool = false) {
        if let view {
            views[rung] = (view, drivesAlpha, permanent)
            apply(view: view, rung: rung, visible: isVisible(rung))
        } else {
            views[rung] = nil
        }
    }

    public func view(for rung: Rung) -> UIView? { views[rung]?.view }

    // MARK: - Items

    /// A new item: a cut, and a new generation, unless it is the item already
    /// on show (a reconfigure — hook 8). Returns the token its answers carry.
    @discardableResult
    public func begin(item newItem: AnyHashable?) -> Token {
        if let newItem, newItem == item { return Token(generation: generation) }
        item = newItem
        generation += 1
        revealGeneration += 1
        rung = nil
        hasFailed = false
        previewSource = nil
        skeletonShownAt = nil
        pendingWhileHeld = nil
        for (rung, entry) in views where !(rung == .content && isContentLent) {
            entry.view.layer.removeAllAnimations()
            apply(view: entry.view, rung: rung, visible: rung == .background)
        }
        rung = views[.background] == nil ? nil : .background
        scheduleSkeleton(for: generation)
        return Token(generation: generation)
    }

    /// Whether `token` is the current item's.
    public func isCurrent(_ token: Token) -> Bool { token.generation == generation }

    /// The current item's token — for an answer that comes from outside the
    /// item's own load (a parked frame, a seeded cover).
    public var currentToken: Token { Token(generation: generation) }

    /// Shows `rung` for the item `token` names.
    ///
    /// - Parameter warm: the answer was at hand when the item was configured
    ///   (a cache hit): drawn in this pass, never animated.
    /// - Parameter source: for a preview, where it came from (hook 7).
    public func show(_ next: Rung, token: Token, warm: Bool = false, source: PreviewSource = .pipeline) {
        guard isCurrent(token) else { return }
        // Monotonic (hook 5): never back down within one item.
        if let rung, next < rung { return }
        if next == .preview {
            if let previewSource, source < previewSource { return }
            previewSource = source
        }
        if rung == next, next != .preview { return }
        if isHeld {
            pendingWhileHeld = max(pendingWhileHeld ?? next, next)
            return
        }
        // A bone shown too briefly would flash: let it finish its minimum.
        if let shownAt = skeletonShownAt, next > .skeleton, !warm, !isFlightCard {
            let remaining = policy.skeletonMinimum - (clock.now() - shownAt)
            if remaining > 0 {
                let reveal = revealGeneration
                clock.after(remaining) { [weak self] in
                    guard let self, revealGeneration == reveal, isCurrent(token) else { return }
                    skeletonShownAt = nil
                    show(next, token: token, warm: warm, source: source)
                }
                return
            }
        }
        let transition: Transition = (warm || isFlightCard) ? .none : transition(for: next)
        land(next, transition: transition)
    }

    /// The item failed: the highest rung reached stays, nothing animates.
    public func fail(token: Token) {
        guard isCurrent(token), !hasFailed else { return }
        hasFailed = true
        hideSkeletonIfShown()
        onSettled?()
    }

    /// A readiness drop (a live surface losing its frame mid-flight or on a
    /// resize): recorded, never a step back (hook 5).
    public func contentDropped() {}

    // MARK: - Hero hooks

    /// A flight holds this view: no transition until `release()` (hook 3).
    public func hold() {
        isHeld = true
        for entry in views.values { entry.view.layer.removeAllAnimations() }
    }

    /// The flight let go: what arrived meanwhile lands, without animation.
    public func release() {
        guard isHeld else { return }
        isHeld = false
        if let pending = pendingWhileHeld {
            pendingWhileHeld = nil
            land(pending, transition: .none)
        }
    }

    /// The content view is lent to another view (hook 4): the ladder will
    /// not touch it nor step back while it is away.
    public func lendContent() { isContentLent = true }

    /// It came back: shown as content again, without animation.
    public func reclaimContent() {
        guard isContentLent else { return }
        isContentLent = false
        if rung == .content, let entry = views[.content] { apply(view: entry.view, rung: .content, visible: true) }
    }

    // MARK: - Landing

    private func transition(for rung: Rung) -> Transition {
        switch rung {
        case .content:
            if views[.content]?.drivesAlpha == false { return .firstFrame }
            return policy.contentArrives
        case .preview:
            return policy.previewArrives
        case .placeholder, .skeleton:
            return .pictureArrives
        case .background:
            return .none
        }
    }

    private func land(_ next: Rung, transition: Transition) {
        rung = next
        transitions.append((next, transition))
        if transitions.count > 32 { transitions.removeFirst() }
        if next > .skeleton { skeletonShownAt = nil }
        onLand?(next, transition)
        guard let entry = views[next], !(next == .content && isContentLent) else {
            finishLanding(next)
            return
        }
        revealGeneration += 1
        let reveal = revealGeneration
        switch transition {
        case .none, .firstFrame:
            apply(view: entry.view, rung: next, visible: true)
            finishLanding(next)
        case .dissolve(let duration):
            // The fade law (hook 9): the arriving rung moves, the ones below
            // stay opaque behind it until it has landed.
            entry.view.isHidden = false
            guard entry.drivesAlpha else {
                finishLanding(next)
                return
            }
            entry.view.alpha = 0
            UIView.animate(
                withDuration: duration, delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
            ) {
                entry.view.alpha = 1
            } completion: { [weak self] _ in
                guard let self, revealGeneration == reveal else { return }
                finishLanding(next)
            }
        }
    }

    /// The rungs below a landed one leave (all but a permanent floor), and a
    /// landed content settles the item.
    private func finishLanding(_ landed: Rung) {
        for (rung, entry) in views where rung < landed && rung > .background && !entry.permanent {
            apply(view: entry.view, rung: rung, visible: false)
        }
        if landed == .content { onSettled?() }
    }

    private func isVisible(_ rung: Rung) -> Bool {
        guard let current = self.rung else { return rung == .background }
        if rung == current || rung == .background { return true }
        return rung < current && (views[rung]?.permanent ?? false)
    }

    private func apply(view: UIView, rung: Rung, visible: Bool) {
        view.isHidden = !visible
        if views[rung]?.drivesAlpha ?? true { view.alpha = visible ? 1 : 0 }
    }

    // MARK: - Skeleton

    private func scheduleSkeleton(for generation: Int) {
        // No item, nothing coming: a reset view shows its ground, never a
        // bone that would shimmer for good.
        guard views[.skeleton] != nil, item != nil else { return }
        if isFlightCard { return }
        clock.after(policy.skeletonDelay) { [weak self] in
            guard let self, self.generation == generation, !isHeld else { return }
            // ⚠️ Not for an item that already failed: nothing is coming, and
            // a bone landing after a fast failure stayed for good (#1752 — a
            // banner whose fetch failed inside the delay).
            guard !hasFailed, rung == nil || rung == .background else { return }
            skeletonShownAt = clock.now()
            land(.skeleton, transition: .none)
        }
    }

    private func hideSkeletonIfShown() {
        if let entry = views[.skeleton], rung == .skeleton {
            apply(view: entry.view, rung: .skeleton, visible: false)
        }
    }

    // MARK: - Tests

    /// The still a view is drawing now, for a hero that reads it (hook 1):
    /// the content's image when it is an image view, else the preview's.
    public var renderedPreview: UIImage? {
        for rung in [Rung.content, .preview] where self.rung.map({ $0 >= rung }) ?? false {
            if let image = (views[rung]?.view as? UIImageView)?.image { return image }
        }
        return nil
    }
}
