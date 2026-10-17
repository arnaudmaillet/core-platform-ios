import MediaCore
import CoreModels
import DesignSystem
import UIKit

/// The author identity (avatar + name/meta) hosted as a bar item's custom
/// view: the post page's toolbar, the conversation's bar, the text composer.
/// The bar never hides or transforms it during a hero flight — the card
/// flies beneath the real, static bar.
///
/// THE DRAWING IS THE APP'S ONE PERSON PILL (`PersonPill`, MediaCore, #1277):
/// the face, the two lines, the relation badge centred on the face's edge.
/// What this view adds is the FEED's: who is shown (a post's author, a
/// conversation's correspondent), the swaps between people (blurred in place,
/// `BarItemContentTransition`), the scroll's scrub blur, and the bar
/// remeasures a width change asks for.
///
/// ITS WIDTH IS ITS CONTENT'S (#925): the pill hugs the face and the two
/// lines, under a cap — the room its bar leaves it (`setWidthBudget`) — and a
/// new person re-negotiates the item's size through the blur
/// (`BarItemRemeasure`).
///
/// THE RELATION IS A BADGE ON THE AVATAR (#925): a relation that loads or
/// changes never touches the pill's width, and every change of it is an SF
/// Symbols replace — never the pill's blur.
final class SnapAuthorIdentityView: UIView {
    /// What the avatar's badge says about the viewer and the person.
    typealias FollowBadge = PersonPill.Badge

    /// Told when the pill joins a window — the moment UIKit has hosted the
    /// bottom bar's items, and so the moment their glass container exists
    /// to be themed (#1325).
    var onDidMoveToWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onDidMoveToWindow?() }
    }

    /// Matches the bar's standard control height.
    private static let height: CGFloat = 40
    /// Long display names truncate here rather than crowding the back item.
    private static let maxWidth: CGFloat = 220
    /// The unhydrated (cold-tap) floor: the pill opens at a plausible
    /// footprint instead of a nub, so hydration is a small glide, not a pop.
    private static let minWidth: CGFloat = 150

    /// Caps the pill's width — the room its bar leaves it. The pill takes its
    /// intrinsic width, at most this (#925).
    ///
    /// The cap is real — the system overflows the whole item into a `•••`
    /// menu the moment the run does not fit, and losing the author entirely
    /// is worse than any amount of truncation. So the pill pays for it in
    /// WIDTH: the name simply truncates earlier. A cap changed on an
    /// installed pill asks its bar for a pass.
    func setWidthBudget(_ budget: CGFloat?) {
        guard pill.setWidthBudget(budget), superview != nil else { return }
        BarItemRemeasure.run(self, duration: nil)
    }

    /// The widest the pill is drawn: the budget, under the pill's own cap.
    var widthCap: CGFloat { pill.widthCap }

    /// Called when the identity is tapped, with the shown author.
    var onAuthorTapped: ((ProfileID) -> Void)?
    /// Called when the "+" is tapped, with the shown author. Never for a
    /// state mark (`FollowBadge`): those take no tap of their own.
    var onFollowTapped: ((ProfileID) -> Void)?

    /// Everything the pill draws: the one view a content change fades
    /// (`contentTransition`) — a CONTAINER, because a platter flattens a
    /// label's own partial alpha to opaque.
    ///
    /// The face is decoded at the avatar bucket (`faceBucket`).
    private let pill = PersonPill(
        height: SnapAuthorIdentityView.height, carriesBadge: true,
        ceiling: SnapAuthorIdentityView.maxWidth, coldWidth: SnapAuthorIdentityView.minWidth,
        faceSize: SnapAuthorIdentityView.faceBucket
    )
    /// Blurs one author out and the next in, inside the one bar item
    /// (`BarItemContentTransition`), the glass taking the new width.
    private lazy var contentTransition: BarItemContentTransition = {
        let transition = BarItemContentTransition(host: self, content: pill)
        transition.remeasure = { [weak self] duration in
            guard let self else { return }
            BarItemRemeasure.run(self, duration: duration)
        }
        transition.didSettle = { [weak self] in self?.onContentSettled?() }
        return transition
    }()
    /// Once a content change has fully landed.
    var onContentSettled: (() -> Void)?

    /// Blurs the pill by `amount` (0…1) as the SCROLL says — the feed's paging
    /// drives it (`BarPillScrub`), and an author set meanwhile lands under
    /// the blur (`BarItemContentTransition.setScrubBlur`).
    func setScrubBlur(_ amount: CGFloat) { contentTransition.setScrubBlur(amount) }

    /// How blurred the pill SHOWS: the scroll's blur, or a swap's envelope.
    var shownScrubBlur: CGFloat { contentTransition.scrubBlur }

    /// Renders the blurred still a scroll may need, before the page moves.
    func prepareScrub() { contentTransition.prepareScrub() }

    /// Whose face the avatar task is loading — compared on arrival so a fast
    /// page-past cannot land a picture on the wrong pill.
    private var authorID: ProfileID?
    /// What is actually on screen, so a repeat call can tell "same page again"
    /// from "same page, better data".
    private var renderedModel: FeedItemDisplayModel?

    init() {
        super.init(frame: .zero)
        // The bar is transparent over arbitrary media; shadows keep the
        // identity legible without a background (`setOverMedia`).
        pill.setOverMedia(true)
        pill.setBadge(followBadge, animated: false)
        pill.onFollowTapped = { [weak self] in
            guard let self, self.followBadge == .follow, let id = self.authorID else { return }
            self.onFollowTapped?(id)
        }
        pill.pin(to: self)
        // The tap is the HOST's, not the pill's: a swap fades the pill to
        // nothing at its midpoint, and a faded view takes no touch.
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(authorTapped)))
    }

    @objc private func authorTapped() {
        guard let authorID else { return }
        onAuthorTapped?(authorID)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `model`'s author, IN PLACE: the pill is one view in one bar item
    /// for the screen's life, and a change of what it draws blurs the old
    /// content out and the new in (`BarItemContentTransition`) while the
    /// item's glass stays where it is, gliding to the new author's width
    /// while only the blurred stills show.
    ///
    /// The meta line is the author's HANDLE alone (`pillMetaLine`): the post's
    /// age is not the pill's to say (asked 2026-10-01) — so paging between
    /// posts by the same author changes nothing on it at all.
    ///
    /// The pill's STATE (`shownAuthor`, the tap target) is the new author at
    /// once; only the drawing waits for the transition's midpoint.
    /// `animated: false`, or a pill not in a window, swaps in one frame.
    func setAuthor(_ model: FeedItemDisplayModel, pipeline: ImagePipeline, animated: Bool = true) {
        guard model != renderedModel else { return }
        // The fast path is for PAGING between posts by one person: the face and
        // the name are already right, and there is no reason to refetch an
        // avatar. Only a handle the projection lacked can still move.
        let sameFace = showsSameFace(as: model)
        let meta = Self.pillMetaLine(fromMeta: model.metaText)
        renderedModel = model
        authorID = model.authorID
        guard !sameFace else {
            guard pill.handle != meta else { return }
            contentTransition.perform(animated: animated) { self.pill.setHandle(meta) }
            return
        }
        var faceURL = model.avatarURL
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-pill-no-face") { faceURL = nil }
        #endif
        contentTransition.perform(animated: animated) {
            self.pill.setName(model.authorName, handle: meta)
            self.pill.avatar.setMonogram(MonogramAvatarView.monogram(
                name: model.authorName, handle: Self.handle(fromMeta: model.metaText)
            ))
            // A face already in the pipeline's memory is drawn here, in the
            // same pass as the name — nothing to fade in after the pill
            // appears. Any other lands later, on THIS author's content.
            self.pill.avatar.setPicture(faceURL, pipeline: pipeline)
        }
    }

    /// Whether `model` would draw the same face and name this pill draws now —
    /// so at most its handle line differs.
    ///
    /// ⚠️ It has to check what is DRAWN, not just who it belongs to. A page
    /// is configured twice from one id — the grid's projection, then the real
    /// entry — and those can carry the same author with a better name and an
    /// avatar the projection had no URL for. Keyed on `authorID` alone, the
    /// second call took the fast path and the capsule kept a blank face.
    func showsSameFace(as model: FeedItemDisplayModel) -> Bool {
        model.authorID == authorID
            && model.authorName == renderedModel?.authorName
            && model.avatarURL == renderedModel?.avatarURL
    }

    /// The author on the pill, if one has been set with `setAuthor`.
    var shownAuthor: FeedItemDisplayModel? { renderedModel }

    /// The bucket the pill's face is decoded at: the pipeline's avatar size,
    /// a small bitmap decoded off the main thread (#894).
    ///
    /// ⚠️ Never the full-size picture. The pill is also drawn by
    /// `CALayer.render` — the blurred stills of `BarItemContentTransition` —
    /// and that CPU path scales whatever the disc holds, on the main thread,
    /// on a frame of the scroll: a full-size face cost 22–40ms per first still
    /// on the iPhone 18 Pro simulator (`-pill-probe`), the same pill 3–7ms
    /// with a small one. The pipeline's memory answers synchronously, so a
    /// swap made on this turn draws the new author already wearing the face.
    static let faceBucket = ImageBucket.avatar

    /// Decodes `url`'s face into the pipeline ahead of need — the next page's
    /// author — so the pill's swap to them is drawn with it.
    static func warmFace(_ url: URL, pipeline: ImagePipeline) {
        guard !pipeline.isDecoded(url, size: faceBucket) else { return }
        Task { @MainActor in
            _ = try? await pipeline.image(for: url, size: faceBucket)
        }
    }

    /// Shows a person who is not a post's author — a conversation's
    /// correspondent. The meta line says whatever the host passes, and an
    /// empty one simply leaves the name alone on the pill.
    ///
    /// ⚠️ ONE PERSON IS DRAWN ONCE (#889). The correspondent arrives in
    /// pieces — the name, then their id, then the face and the @handle from
    /// one profile read — and a piece that lands for the person already on
    /// the pill changes in place: the new line is set and the glass glides
    /// to its width, the face fades in on the avatar alone. Only a
    /// DIFFERENT person (or the first one over the redaction bars) cross-
    /// fades the whole pill, as `setAuthor` does.
    func setPerson(id: ProfileID?, name: String, meta: String, avatarURL: URL?, pipeline: ImagePipeline) {
        let faceChanged = id != authorID || avatarURL != personAvatarURL
        guard faceChanged || name != pill.name || meta != pill.handle else { return }
        // Someone else than the person drawn: an id that replaces another
        // id. A first id for the name already drawn is the same person.
        let personChanged = pill.isRedacted || (authorID != nil && id != authorID)
        renderedModel = nil
        authorID = id
        let urlChanged = avatarURL != personAvatarURL
        personAvatarURL = avatarURL
        defer { BarItemRemeasure.run(self, duration: 0.22) }

        let draw = {
            self.pill.setName(name, handle: meta)
            if personChanged { self.pill.avatar.setPicture(nil, pipeline: nil) }
            self.pill.avatar.setMonogram(MonogramAvatarView.monogram(
                name: name, handle: Self.handle(fromMeta: meta)
            ))
        }
        if personChanged {
            personFades += 1
            UIView.transition(with: self, duration: 0.18,
                              options: [.transitionCrossDissolve, .allowUserInteraction],
                              animations: draw) { _ in self.personFades -= 1 }
        } else {
            draw()
        }

        guard personChanged || urlChanged else { return }
        // The face over the initials (nil: the person's picture is gone, the
        // initials again); the avatar fades it in on the disc alone.
        pill.avatar.setPicture(avatarURL, pipeline: pipeline)
    }

    /// What the pill's second line says for a post's meta ("@handle · 3m"):
    /// the "@handle" alone — never the age, which is the post's, not the
    /// author's. Empty when the meta carries no handle.
    static func pillMetaLine(fromMeta meta: String) -> String {
        let handle = handle(fromMeta: meta)
        return handle.isEmpty ? "" : "@" + handle
    }

    /// "@handle" off a meta line ("@handle · 3m"); empty when it carries none.
    private static func handle(fromMeta meta: String) -> String {
        let first = meta.components(separatedBy: " · ").first ?? ""
        return first.hasPrefix("@") ? String(first.dropFirst()) : ""
    }

    /// The face `setPerson` last asked for — the arrival guard for its fetch.
    private var personAvatarURL: URL?

    /// What the avatar's badge says: the viewer's relation to the author (the
    /// snap feed) or to the correspondent (a conversation, #752), and none
    /// for the viewer themself or while it does not know.
    ///
    /// ⚠️ EVERY CHANGE IS ONE SYMBOL REPLACING ANOTHER (#925) — a follow tap
    /// turning the "+" into the followed mark and a relation read landing
    /// late alike: `animated`, on screen, the badge's symbol changes through
    /// SF Symbols' replace transition, and nothing else moves. The pill is
    /// never blurred or faded for it (it used to be, through the author's own
    /// swap, #889), and the bar item is never resized.
    ///
    /// A swap of the pill's WHOLE content already under way (a new author
    /// blurring in) takes the badge with it instead: set in the same turn as
    /// a new author, the badge lands in that one swap.
    func setFollowBadge(_ badge: FollowBadge, animated: Bool = false) {
        guard badge != followBadge else { return }
        followBadge = badge
        // `afterSwap` runs the change at once, unless the pill's content is
        // being swapped: then at that swap's midpoint, under its blur, where
        // a symbol transition would play unseen and its still would picture
        // it half-drawn — so only a change made NOW animates.
        var now = true
        contentTransition.afterSwap { [weak self] in
            guard let self else { return }
            self.pill.setBadge(self.followBadge, animated: now && animated && self.window != nil)
        }
        now = false
    }

    /// Whether the WHOLE pill is being redrawn through a transition — the
    /// blur swap, or the person cross-fade. Tests: a relation change must
    /// never show one (#889, #925).
    var isRedrawingWholePill: Bool { contentTransition.isRunning || personFades > 0 }

    /// The person cross-fades under way (`setPerson`).
    private var personFades = 0

    /// Whether the "+" is on offer.
    var offersFollow: Bool { followBadge == .follow }

    /// The pill's own default is the "+": a host that offers no follow says
    /// so (`setFollowBadge(.none)`).
    private(set) var followBadge: FollowBadge = .follow

    /// The symbol the badge draws now — nil for none. Tests.
    var drawnBadgeSymbol: String? { pill.drawnBadgeSymbol }

    /// How many badge changes were drawn through the symbol replace. Tests.
    var badgeReplaceCount: Int { pill.badgeReplaceCount }

    /// The badge's disc and glyph images as drawn now. Tests (#968).
    var drawnBadgeImages: (disc: UIImage?, glyph: UIImage?) { (nil, pill.drawnBadgeImage) }

    /// The SHADOW only — the colours are semantic and resolve from the
    /// bar's theme (`SnapChromeTheme`, applied to the navigation bar). A text
    /// page's own ground makes it unnecessary.
    func setOverMedia(_ overMedia: Bool) { pill.setOverMedia(overMedia) }
}

extension PersonPill.Badge {
    /// What the pill draws for where the viewer stands — ONE rule for a
    /// post's author and a conversation's correspondent (#752).
    init(_ relation: FollowRelation) {
        self = switch relation {
        case .notFollowing, .followedBy: .follow
        case .following: .following
        case .mutual: .friends
        // Drawn, not offered: the profile screen withdraws it.
        case .requested: .pending
        case .viewer, .blocked: .none
        }
    }
}

/// The snap feed's navigation-bar controls, built as *custom views* so their
/// on-screen frames are readable with public API (a system-styled
/// `UIBarButtonItem` exposes no view), and so the hero flight's stand-ins can
/// be second instances of the exact same controls — pixel-identical at the
/// landing swap by construction.
enum SnapNavControls {
    /// The back chevron for a presented (map-opened) feed; dismisses to the map.
    static func makeBackButton() -> UIButton {
        makeCircularBarButton(systemName: "chevron.backward", pointSize: 17)
    }

    /// A NAVIGATION-bar action that stands in the back button's slot (the
    /// comments ✕). The back button's 17pt metric, not the toolbar's 15,
    /// because it sits in the same slot and swaps with it — two glyphs at
    /// different weights trading places would read as a size change.
    static func makeNavActionButton(systemName: String) -> UIButton {
        makeCircularBarButton(systemName: systemName, pointSize: 17)
    }

    /// A bottom-toolbar action (share, more): the same 36pt circle as the
    /// back button, hosted as a bar item custom view so the system glass
    /// wraps each action in its own isolated bubble — custom views never
    /// join a shared item background.
    static func makeToolbarActionButton(systemName: String) -> UIButton {
        makeCircularBarButton(systemName: systemName, pointSize: 15)
    }

    /// One symbol in a strict 1:1 box: symbol intrinsic sizes are asymmetric
    /// and the system glass pill wraps the custom view's bounds, which
    /// renders slightly oval without this. Both metrics are 999, never
    /// required: the bar's FIRST pass pins its item wrapper to the raw
    /// intrinsic size with autoresizing constraints, and anything required
    /// loses to that with a console break. 36 matches the wrapper's real
    /// item height, so the settled pill is an exact circle (a 40pt box
    /// would settle 40×36 — subtly oval).
    private static func makeCircularBarButton(systemName: String, pointSize: CGFloat) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage.symbol(named: systemName)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
        config.baseForegroundColor = .label
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        let height = button.heightAnchor.constraint(equalToConstant: 36)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        let aspect = button.widthAnchor.constraint(equalTo: button.heightAnchor)
        aspect.priority = UILayoutPriority(999)
        aspect.isActive = true
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.5
        button.layer.shadowRadius = 3
        button.layer.shadowOffset = .zero
        return button
    }
}

#if DEBUG
extension SnapAuthorIdentityView {
    /// The picture on the disc now; nil while the initials show.
    var debugFaceImage: UIImage? { pill.avatar.shownPicture }
    /// The lines the pill shows, top to bottom, and the name's font.
    var debugShownLines: [String] { pill.debugShownLines }
    var debugNameFont: UIFont { pill.debugNameFont }
    var debugHandleFont: UIFont { pill.debugHandleFont }

    /// `-pill-probe`: what the pill's disc actually is at this instant — its
    /// frame in the window, its corner and mask, every transformed ancestor up
    /// to the bar, and any OTHER view in the window drawing the same initials.
    func debugProbe(_ tag: String) {
        guard let window else { print("[pill-probe] \(tag) pill=\(ObjectIdentifier(self)) NO WINDOW"); return }
        let disc = pill.avatar.monogram
        let frame = disc.convert(disc.bounds, to: window)
        let presentation = disc.layer.presentation()
        let maskPath = (disc.layer.mask as? CAShapeLayer)?.path?.boundingBox
        let pres = presentation.map {
            String(format: "%.1fx%.1f r=%.1f", $0.bounds.width, $0.bounds.height, $0.cornerRadius)
        } ?? "nil"
        let mask = maskPath.map { String(format: "%.1fx%.1f", $0.width, $0.height) } ?? "NONE"
        var line = String(format: "[pill-probe] %@ pill=%.1fx%.1f disc@win=(%.1f,%.1f %.1fx%.1f) r=%.1f",
                          tag, bounds.width, bounds.height, frame.minX, frame.minY, frame.width, frame.height,
                          disc.layer.cornerRadius)
        line += " pres=\(pres) mask=\(mask) curve=\(disc.layer.cornerCurve.rawValue)"
            + " clips=\(disc.layer.masksToBounds) bg=\(disc.layer.backgroundColor.map { String(format: "%.2f", $0.alpha) } ?? "nil")"
            + " sublayers=\((disc.layer.sublayers ?? []).map { "\(type(of: $0))" })"
        var chain: [String] = []
        var view: UIView? = self
        while let current = view, !(current is UIWindow) {
            let t = current.layer.presentation()?.transform ?? current.layer.transform
            var entry = "\(type(of: current))[\(Int(current.bounds.width))x\(Int(current.bounds.height))"
            if !CATransform3DIsIdentity(t) { entry += String(format: " s=%.3f", t.m11) }
            if current.alpha < 1 { entry += String(format: " a=%.2f", current.alpha) }
            if current.layer.cornerRadius > 0 { entry += String(format: " r=%.1f", current.layer.cornerRadius) }
            if current.layer.mask != nil { entry += " MASK" }
            chain.append(entry + "]")
            if current is UINavigationBar { break }
            view = current.superview
        }
        line += " chain=" + chain.joined(separator: " < ")
        // Copies: any other label in the window reading the same initials,
        // and any portal/snapshot in the bar band.
        let initials = disc.debugMonogramText
        var copies: [String] = []
        func scan(_ root: UIView) {
            for sub in root.subviews {
                if let label = sub as? UILabel, label.text == initials, label.superview !== disc {
                    let f = label.convert(label.bounds, to: window)
                    copies.append(String(format: "label(%.1f,%.1f %.1fx%.1f)", f.minX, f.minY, f.width, f.height))
                }
                let name = String(describing: type(of: sub))
                // Anything painting a background over the disc: the plate's
                // square has to be drawn by SOMETHING.
                let over = sub.convert(sub.bounds, to: window)
                if sub !== disc, over.intersects(frame.insetBy(dx: 4, dy: 4)), over.width < 80,
                   let bg = sub.layer.backgroundColor, bg.alpha > 0 {
                    copies.append(String(format: "BG %@(%.1f,%.1f %.1fx%.1f r=%.1f %@%@)", name, over.minX, over.minY,
                                         over.width, over.height, sub.layer.cornerRadius,
                                         sub.layer.cornerCurve.rawValue, sub.layer.mask == nil ? "" : " MASK"))
                }
                if name.contains("Portal") || name.contains("Snapshot") || name.contains("Replica") {
                    let f = sub.convert(sub.bounds, to: window)
                    if f.minY < 140 {
                        copies.append(String(format: "%@(%.1f,%.1f %.1fx%.1f)", name, f.minX, f.minY, f.width, f.height))
                    }
                }
                scan(sub)
            }
        }
        scan(window)
        line += " copies=\(copies)"
        print(line)
    }
}
#endif
