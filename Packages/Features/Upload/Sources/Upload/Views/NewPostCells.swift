import DesignSystem
// `VideoRenderView` — the surface the cover's clip plays in, over its own tile.
import MediaPlayback
import UIKit

/// The chosen media, laid along the top of the new-post screen in the order they
/// will publish in — the first of them being the cover.
///
/// A scroll view of image views rather than a second collection view: the count
/// is capped at twenty, none of it is reused, and a nested collection view here
/// would buy recycling nobody needs at the price of another data source.
///
/// ⚠️ **NO CARD BEHIND IT.** This strip is the subject of its section, not a row
/// in a settings list, so its section is drawn plain and its cell background is
/// cleared. A white platter behind pictures reads as a frame nobody asked for.
final class NewPostMediaCell: UICollectionViewListCell {
    private enum Metrics {
        /// Tall enough to judge a photograph by, which a 72pt chip was not.
        static let height: CGFloat = 208
        /// ⚠️ **9:16, AND THE RATIO IS THE POINT.** These were 3:4 — the same
        /// shape the debug fixture renders its portrait tiles at — so fitting
        /// such a picture into such a frame letterboxed by ZERO and made fill
        /// and fit pixel-identical. A screenshot could not tell them apart, and
        /// I read that as the feature being broken. A 9:16 frame is narrower
        /// than any photograph it will hold, so fitting always shows ground and
        /// filling always crops: the choice becomes visible on sight.
        static let width: CGFloat = (208 * 9 / 16).rounded()
        static let corner: CGFloat = 14
        /// ⚠️ **EIGHT FRAMES A SECOND, WHICH IS A PREVIEW AND NOT A FILM.** The
        /// sheet exists to say "this is a clip and this is roughly what is in
        /// it"; at twenty-five frames a second it would need three times the
        /// pictures to say the same thing, and each one is held decoded.
        static let sheetSecondsPerFrame: Double = 0.125
    }

    /// ⚠️ A `CarouselScrollView`, NOT A PLAIN ONE: at its leading edge it
    /// declines a rightward drag so the stack's back-swipe can carry the screen
    /// back. See `CarouselBackSwipe`.
    private let scroller = CarouselScrollView()
    private let row = UIStackView()
    /// What the strip currently stands for, so a re-configure of the same
    /// selection in the same order does not rebuild and re-fetch it.
    private var shown: [String] = []
    /// The tiles by item id, so the cover can be found again without walking
    /// the row — the order is `publishOrder`'s, which changes under us.
    private var tiles: [String: UIImageView] = [:]
    /// The sprite sheet each clip tile falls back to, by item id — built on
    /// demand by the screen, kept here because the tile is what draws it.
    ///
    /// ⚠️ **UNDER THE SURFACE, OVER THE STILL** — asked for in those words. The
    /// order inside a clip's tile is `still → sheet → surface → badges`, so a
    /// tile that has lost the player (or never had it) shows moving frames
    /// rather than a frozen one, and a surface that has not received a frame
    /// yet shows the sheet through it rather than the still.
    private var sheets: [String: UIImageView] = [:]
    /// The "Cover" capsule, so it can be shown and hidden with the state.
    private var coverBadges: [String: UIView] = [:]
    /// Which tiles stand for a clip: the only ones that take a tap.
    private var clips: Set<String> = []
    /// What each clip tile was last told to be. ⚠️ **STORED, NOT INFERRED.**
    /// Reading it back off `isAnimating` answers "playing" for a clip whose
    /// frames have not been sampled yet, which is the state a test is most
    /// likely to be asking about.
    private var clipStates: [String: ClipState] = [:]
    /// The tiles built invisible, waiting for the screen to say it is appearing
    /// — see `popTilesIn()`.
    private var heldForArrival: [UIView] = []

    /// Told when a clip's tile is tapped — the screen owns what a tap means.
    var onTileTapped: ((String) -> Void)?

    /// Whether motion is unwanted, asked at the moment each curve would run.
    ///
    /// ⚠️ **A CLOSURE THE SCREEN HANDS DOWN, NOT A READ OF THE SETTING.** The
    /// simulator a test runs on cannot switch Reduce Motion on, so a cell that
    /// read `UIAccessibility` itself could only ever be tested with motion —
    /// and "instant under Reduce Motion" would be a promise nothing checked.
    var reducesMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }

    /// ⚠️ **ONE SURFACE, BUILT ONCE AND MOVED — NOT ONE PER TILE.** The strip
    /// holds up to twenty tiles and the screen plays exactly one of them (see
    /// `NewPostViewController.playCover`), so a surface per tile would be
    /// nineteen `VideoRenderView`s that never receive a frame. Built here rather
    /// than made on demand because it is handed to a player: a surface minted
    /// inside `videoSurface(over:)` would be a new object on every cover change,
    /// and the screen's "am I already playing this?" guard compares identity.
    private let surface = VideoRenderView()

    /// Told when a bound surface is taken out from under its player — a rebuild
    /// of the strip, or the cell being recycled.
    ///
    /// ⚠️ **THE CELL CANNOT STOP A PLAYER AND MUST NOT TRY.** It owns the
    /// rectangle, not the playback seam; what it can do is say that the
    /// rectangle is gone. `MediaEditorPageCell.onReuse` carries the same
    /// division for the canvas, for the same reason: a surface detached while a
    /// player still holds it goes on decoding for nobody, which is the shape of
    /// `profile-gallery-player-leak`.
    var onSurfaceLost: ((VideoRenderView) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        scroller.showsHorizontalScrollIndicator = false
        scroller.alwaysBounceHorizontal = true
        scroller.clipsToBounds = false
        // ⚠️ COMPUTED IN `layoutSubviews`, NOT FIXED HERE. The strip centres its
        // thumbnails while they fit and runs edge to edge once they do not, so
        // the side room depends on the count and the width — see
        // `centreContentIfItFits`. A constant stated here would add to that and
        // push a centred row off-centre by exactly one margin.
        row.axis = .horizontal
        row.spacing = Spacing.sm
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(row)
        scroller.pin(to: contentView, insets: NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: 0, bottom: Spacing.sm, trailing: 0
        ))
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
            scroller.heightAnchor.constraint(equalToConstant: Metrics.height)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// ⚠️ A VIDEO IS MARKED, NOT HIDDEN. It cannot be published yet — the
    /// library seam vends images only — and the screen's footer says so. Drawing
    /// them anyway, badged, is what keeps the strip honest about the selection
    /// the viewer actually made.
    ///
    /// ⚠️ **THE COVER IS NAMED, NOT ASSUMED TO BE FIRST.** Only photos publish,
    /// so if the viewer's first pick is a video the leading tile is NOT what the
    /// feed will show this post by — badging index 0 would promise a cover that
    /// never arrives, which is the very thing §22 exists to stop. The screen
    /// says which item is the cover and this draws that one.
    /// ⚠️ **THE THUMBNAILS HONOUR THE EDITOR'S CHOICES — ALL OF THEM.** A picture
    /// the author chose to show WHOLE must not come back cropped one screen later,
    /// and one they cut or dressed must not come back whole or undressed. The strip
    /// is the same media, so it obeys the same decisions.
    ///
    /// ⚠️ **IT HONOURED ONE OF THREE UNTIL THE CROP WORK, AND THAT WAS A BUG THIS
    /// ROW SHIPPED.** The fit was read; the look was not applied at all, so a
    /// picture made mono in the editor came back in colour on this screen. Adding
    /// the crop alone would have made it two of three.
    /// `MediaEdits.applied(to:artwork:)` is now the one render both this strip and
    /// `post()` go through.
    ///
    /// `holdsForArrival` builds the tiles invisible and small, for
    /// `popTilesIn()` to bring in — see the note there on why the screen says
    /// WHEN and this cell only says HOW.
    func show(
        _ items: [MediaLibraryItem],
        coverID: String?,
        edits: [String: MediaEdits] = [:],
        holdsForArrival: Bool = false,
        thumbnail: @escaping @MainActor (String, CGSize) async -> UIImage?
    ) {
        // ⚠️ **THE KEY CARRIES EVERY DECISION, NOT JUST THE IDENTITY** — the same
        // pictures in the same order can still need redrawing, because the author
        // may have changed one of them in the editor. This `guard` is the only
        // thing that redraws the strip, so a decision missing from the key is a
        // thumbnail that silently keeps showing the previous one; `signature`
        // spells the fields rather than hashing them for exactly that reason.
        let wanted = items.map { "\($0.id)=\((edits[$0.id] ?? .untouched).signature)" }
        guard wanted != shown else { return }
        shown = wanted
        // ⚠️ **THE SURFACE IS TAKEN OUT BEFORE ITS TILE IS**, and whoever put a
        // player in it is told. The loop below frees every tile, and a surface
        // left inside one would be deallocated with it while a player was still
        // pushing frames at it.
        surrenderSurface()
        tiles.removeAll()
        sheets.removeAll()
        coverBadges.removeAll()
        clips.removeAll()
        clipStates.removeAll()
        heldForArrival.removeAll()
        for view in row.arrangedSubviews { view.removeFromSuperview() }

        let size = CGSize(width: Metrics.width * 2, height: Metrics.height * 2)
        for item in items {
            let picture = UIImageView()
            picture.contentMode = (edits[item.id] ?? .untouched).fit.mode
            picture.clipsToBounds = true
            // ⚠️ BLACK, NOT A GREY FILL. In a 9:16 frame a fitted picture shows
            // its ground on two sides, and that ground IS the letterbox — it
            // should read as the editor's canvas does, not as a placeholder
            // still waiting for an image.
            picture.backgroundColor = .black
            picture.layer.cornerRadius = Metrics.corner
            picture.layer.cornerCurve = .continuous
            picture.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                picture.widthAnchor.constraint(equalToConstant: Metrics.width),
                picture.heightAnchor.constraint(equalToConstant: Metrics.height)
            ])
            picture.isAccessibilityElement = true
            let isCover = item.id == coverID
            picture.accessibilityLabel = Self.label(for: item, isCover: isCover)
            // ⚠️ **EVERY TILE GIVES UNDER THE FINGER AND TICKS ON A TAP — AND A
            // PHOTOGRAPH'S DOES NOTHING ELSE.** Asked for as thumbnails that
            // "behave like buttons". A clip's tile has something to do with the
            // tap (film or frames); a photograph has no second state, and
            // inventing one was explicitly not asked. The press says the tile
            // felt the finger, which is true of both.
            // ⚠️ **A RECOGNISER, NOT A CONTROL.** The tile is an image view the
            // strip's `CarouselScrollView` scrolls, and a control in its place
            // would keep a drag that begins on it: a `UIScrollView` refuses to
            // cancel a `UIControl`'s touches unless told to, and that scroller
            // is not told to (nor is it this change's to tell). A recogniser
            // needs no permission: `PressFeedback`'s never recognises, gives
            // way to the carousel's pan and to the stack's back-swipe, and
            // leaves the clip's own tap alone.
            PressFeedback.attach(toView: picture) { [weak self] in self?.reducesMotion() ?? false }

            if isCover {
                let badge = Self.badge(text: "Cover")
                picture.addSubview(badge)
                coverBadges[item.id] = badge
            }
            if item.isVideo {
                clips.insert(item.id)
                picture.isUserInteractionEnabled = true
                let tap = UITapGestureRecognizer(
                    target: self, action: #selector(tileTapped)
                )
                picture.addGestureRecognizer(tap)
                // ⚠️ **`video.fill`, NOT `video.slash.fill`.** The slash meant
                // "this will not be posted" and was true for as long as the
                // publish loop dropped videos. It no longer is, and a slashed
                // camera now reads as a refusal of something that works. The
                // mark stays, because which tile is a clip is still worth
                // saying — the picker's grid stamps a duration for the same
                // reason.
                let badge = UIImageView(image: UIImage(systemName: "video.fill"))
                badge.tintColor = .white
                badge.translatesAutoresizingMaskIntoConstraints = false
                picture.addSubview(badge)
                NSLayoutConstraint.activate([
                    badge.trailingAnchor.constraint(equalTo: picture.trailingAnchor, constant: -Spacing.sm),
                    badge.bottomAnchor.constraint(equalTo: picture.bottomAnchor, constant: -Spacing.sm)
                ])
            }

            row.addArrangedSubview(picture)
            let id = item.id
            tiles[id] = picture
            let chosen = edits[id] ?? .untouched
            Task { [weak picture] in
                let image = await thumbnail(id, size)
                // Drawn off the main actor (charter P13): a page with a cut
                // or a look is a CoreImage render, and this ran it on the
                // main actor for every tile as its picture arrived.
                let dressed: UIImage? = if let image, !chosen.finish(includingOverlays: true).isNone {
                    await Task.detached(priority: .userInitiated) { chosen.applied(to: image, artwork: nil) }.value
                } else {
                    image
                }
                picture?.image = dressed
            }
        }
        // ⚠️ **HELD HERE, AT BUILD, AND NOT WHEN THE RIPPLE STARTS.** The build
        // is the list's layout, and it can run without the screen asking for it
        // — a tile staged invisible only when the ripple is asked for could be
        // drawn whole for a frame first, and then blink out to pop back in.
        // ⚠️ AND NOT AT ALL UNDER REDUCE MOTION — a held tile is a promise of a
        // curve, and there will not be one.
        if holdsForArrival, !reducesMotion() {
            heldForArrival = row.arrangedSubviews
            for tile in heldForArrival {
                tile.alpha = 0
                tile.transform = BandPop.collapsedTransform
            }
        }
    }

    /// Brings the held tiles in on the editing band's curve — each one scaling
    /// and fading up from `BandPop.collapsedTransform`, one after another — so
    /// the strip arrives as a ripple rather than as a slab switched on. The
    /// filter row does exactly this (`MediaEditorViewController.popTheTenantIn`),
    /// and these are the same numbers on purpose: the two screens are one flow.
    ///
    /// ⚠️ **THE SCREEN SAYS WHEN, AND IT SAYS IT ONCE.** A list cell is
    /// configured inside the collection view's own layout pass, where a first
    /// build and a rebuild look exactly alike — and the moment that matters is
    /// the screen APPEARING, which only the controller sees (`viewIsAppearing`,
    /// as the push begins — see there for why not later, and not earlier). A
    /// strip REBUILT later (a cover change reorders it) is not held and not
    /// rippled: see `NewPostViewController.bringTheStripIn`.
    ///
    /// ⚠️ **SILENT, UNLIKE THE BAND.** The band's pops are heard because a tap on
    /// a category asked for them; nothing here was tapped — the author pressed
    /// "Next" a screen ago — and seven clicks as a screen arrives would be noise.
    func popTilesIn() {
        let tiles = heldForArrival
        heldForArrival = []
        guard !tiles.isEmpty else { return }
        let delays = tiles.indices.map { BandPop.stagger(for: $0) }
        #if DEBUG
        debugArrivals.append(delays)
        #endif
        for (tile, delay) in zip(tiles, delays) {
            // ⚠️ A SPRING, WHICH TAKES ITS FROM-VALUE FROM THE MODEL — the
            // alpha and scale staged at build, a turn or more ago. See
            // `uiview-animate-from-value-trap` for the option that would read
            // it from the presentation layer instead.
            UIView.animate(
                withDuration: BandPop.duration,
                delay: delay,
                usingSpringWithDamping: BandPop.dampingRatio,
                initialSpringVelocity: 0,
                // A clip's tile is a control, and it stays one while it arrives.
                options: [.allowUserInteraction]
            ) {
                tile.alpha = 1
                tile.transform = .identity
            }
        }
    }

    @objc private func tileTapped(_ tap: UITapGestureRecognizer) {
        guard let tile = tap.view,
              let id = tiles.first(where: { $0.value === tile })?.key,
              clips.contains(id)
        else { return }
        onTileTapped?(id)
    }

    /// What a clip's tile is doing right now.
    enum ClipState: Equatable {
        /// The film is running in the surface, over its sheet.
        case playing
        /// The sheet is what shows: sampled frames cycling, or the still until
        /// they arrive.
        case sheet
    }

    /// Draws `id`'s tile in `state`.
    ///
    /// ⚠️ **THE "Cover" CAPSULE BELONGS TO THE SHEET STATE, AND THIS REVERSES
    /// AN EARLIER DECISION.** The note that stood here argued the badge must
    /// survive playback — "the cover badge would vanish the moment the cover
    /// started playing, on the one tile that needs it most". Asked for the
    /// other way: the word is there to name a tile at rest, and a label over
    /// moving film is the same noise the editor's own chrome is kept off the
    /// picture to avoid. The badge comes back the moment the film stops — on a
    /// curve, see `setCoverBadge(showing:for:animated:)`.
    func setClipState(_ state: ClipState, for id: String) {
        guard clips.contains(id) else { return }
        // ⚠️ **A TILE'S FIRST STATE IS ITS DRESS, NOT A CHANGE.** `show` builds
        // every badge showing and forgets every state, so the first answer after
        // a build is the tile being put right, not the author doing something —
        // a fresh cover tile that is to play would otherwise be seen wearing its
        // word for a moment and then shrug it off.
        let isAChange = clipStates[id].map { $0 != state } ?? false
        let sheet = sheets[id]
        sheet?.isHidden = false
        switch state {
        case .playing:
            // ⚠️ **HELD ON ONE FRAME, NOT RUNNING UNDER THE FILM.** The sheet is
            // under the surface as a FALLBACK — what shows through until the
            // first frame lands (`videoSurface(over:)`'s note on
            // `paintsOpaqueGround`) and if the load never arrives. Left
            // animating it would be a second picture changing sixty times a
            // minute behind an opaque one, for nobody.
            sheet?.stopAnimating()
        case .sheet:
            sheet?.startAnimating()
        }
        clipStates[id] = state
        setCoverBadge(showing: state == .sheet, for: id, animated: isAChange)
        tiles[id]?.accessibilityHint = state == .playing
            ? "Double-tap to show this clip's frames"
            : "Double-tap to play this clip"
    }

    /// Shows or hides the "Cover" capsule on `id`'s tile.
    ///
    /// ⚠️ **THE BAND'S NUMBERS, NOT NEW ONES.** It arrives on `BandPop`'s spring
    /// — `duration`, `dampingRatio`, from `collapsedScale` — and leaves on the
    /// band's departure: 0.6 of that duration, eased in, not a spring
    /// (`MediaEditorViewController.popTheTenantOut`). A capsule is smaller than
    /// a filter card, and BandPop's note on `collapsedScale` is about keeping a
    /// CAPTION legible for the whole curve; "Cover" is a caption, so the
    /// reasoning carries over rather than asking for a scale of its own.
    ///
    /// ⚠️ **LEAVING IS QUICKER BECAUSE NOBODY IS READING IT.** The word goes
    /// because the film started, and the film is what the author is now
    /// watching; a slow fade would hold a label over the first half-second of
    /// the very picture it was taken off to reveal.
    ///
    /// ⚠️ **THE MODEL IS THE DECISION, SET AT ONCE; `isHidden` FOLLOWS THE
    /// CURVE.** Alpha reads 0 the moment a departure is asked for, and the view
    /// is only hidden when the curve ends — and only if nothing has asked for it
    /// back in the meantime, which is what the completion's own check is for.
    private func setCoverBadge(showing: Bool, for id: String, animated: Bool) {
        guard let badge = coverBadges[id] else { return }
        let isShowing = !badge.isHidden && badge.alpha > 0
        guard showing != isShowing else { return }
        let moves = animated && !reducesMotion()
        // ⚠️ DECIDED ONCE, AND THE CURVES BELOW ARE HANDED THESE — so what the
        // debug record says is what was asked of UIKit, not a second opinion.
        let duration = moves ? (showing ? BandPop.duration : Self.badgeDeparture) : 0
        let spring = BandPop.dampingRatio
        #if DEBUG
        debugBadgeChanges.append(BadgeChange(
            id: id, showing: showing, duration: duration,
            dampingRatio: moves && showing ? spring : nil
        ))
        #endif
        guard moves else {
            badge.layer.removeAllAnimations()
            badge.isHidden = !showing
            badge.alpha = 1
            badge.transform = .identity
            return
        }
        guard showing else {
            // ⚠️ `.beginFromCurrentState` IS SAFE HERE BECAUSE NOTHING IS STAGED:
            // it reads the from-value off the presentation layer, which for a
            // badge on screen is exactly what the eye last saw — including one
            // caught half way through arriving.
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: [.curveEaseIn, .beginFromCurrentState, .allowUserInteraction]
            ) {
                badge.alpha = 0
                badge.transform = BandPop.collapsedTransform
            } completion: { [weak badge] _ in
                guard let badge, badge.alpha == 0 else { return }
                badge.isHidden = true
            }
            return
        }
        if badge.isHidden {
            badge.isHidden = false
            badge.alpha = 0
            badge.transform = BandPop.collapsedTransform
        } else if let now = badge.layer.presentation() {
            // A departure still under way: turn round from where it has got to,
            // rather than jumping to nothing and starting again.
            badge.layer.removeAllAnimations()
            badge.alpha = CGFloat(now.opacity)
            badge.transform = CATransform3DGetAffineTransform(now.transform)
        }
        // ⚠️ A SPRING, WHOSE FROM-VALUE IS THE MODEL STAGED JUST ABOVE — the
        // plain curve with `.beginFromCurrentState` would read it off a
        // presentation layer that never drew it, and run end to end, invisibly
        // (`uiview-animate-from-value-trap`).
        UIView.animate(
            withDuration: duration,
            delay: 0,
            usingSpringWithDamping: spring,
            initialSpringVelocity: 0,
            options: [.allowUserInteraction]
        ) {
            badge.alpha = 1
            badge.transform = .identity
        }
    }

    /// The band's departure — see `setCoverBadge(showing:for:animated:)`.
    private static let badgeDeparture = BandPop.departure

    /// Hands `id`'s tile the frames it falls back to.
    ///
    /// ⚠️ **`animationImages`, NOT A BAKED GRID.** The map's markers carry a
    /// real sprite sheet because their frames arrive as one downloaded asset
    /// (`PinCardView`); here the frames are sampled from a file on the device
    /// and are already separate images, so composing a grid and slicing it back
    /// would be work with a picture at both ends of it. UIKit's own cycling is
    /// the same thing with none of that.
    func showSheet(_ frames: [UIImage], for id: String) {
        guard clips.contains(id), let tile = tiles[id], !frames.isEmpty else { return }
        let sheet = sheets[id] ?? {
            let view = UIImageView()
            view.contentMode = tile.contentMode
            view.clipsToBounds = true
            view.translatesAutoresizingMaskIntoConstraints = false
            // ⚠️ **AT THE BOTTOM, SO THE SURFACE CAN GO ABOVE IT.** `insertSubview(at: 0)`
            // puts it over the tile's own image and under everything else the
            // tile holds; the surface is then inserted ABOVE this one by name
            // rather than by index, which is what keeps the two in order
            // however many times either is installed.
            tile.insertSubview(view, at: 0)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
                view.topAnchor.constraint(equalTo: tile.topAnchor),
                view.bottomAnchor.constraint(equalTo: tile.bottomAnchor)
            ])
            sheets[id] = view
            return view
        }()
        sheet.animationImages = frames
        sheet.animationDuration = Double(frames.count) * Metrics.sheetSecondsPerFrame
        sheet.animationRepeatCount = 0
        sheet.image = frames.first
        sheet.startAnimating()
    }

    /// Whether `id`'s tile already has its frames.
    func hasSheet(for id: String) -> Bool { sheets[id]?.animationImages?.isEmpty == false }

    /// Lays the video surface over the tile standing for `id` and hands it back,
    /// or nil when no tile stands for it.
    ///
    /// ⚠️ **BELOW THE BADGES, ABOVE THE PICTURE.** The "Cover" capsule and the
    /// `video.fill` mark are subviews of the tile, added in `show`, so an
    /// `addSubview` here would put moving film on top of both — the cover badge
    /// would vanish the moment the cover started playing, on the one tile that
    /// needs it most. Index 0 is above the tile's own image (which is drawn by
    /// the view, not by a subview) and below everything `show` added.
    ///
    /// ⚠️ **NO POSTER, AND NO OPAQUE GROUND.** `MediaEditorPageCell` hands its
    /// surface `setPoster(picture.image)` because the page's picture is behind
    /// a canvas that paints its own ground; here the tile IS the poster and it
    /// is directly underneath, so a copy of it would be the same pixels decoded
    /// twice. What makes the still show through until the first frame lands is
    /// `paintsOpaqueGround = false` — left at its default the surface is a black
    /// rectangle over the thumbnail for as long as the load takes.
    ///
    /// The gravity tracks the tile's own `contentMode`, which is the fit the
    /// author chose in the editor: a clip they asked to see WHOLE must not start
    /// filling its frame the moment it begins to move.
    func videoSurface(over id: String) -> VideoRenderView? {
        guard let tile = tiles[id] else { return nil }
        surface.videoGravity = tile.contentMode == .scaleAspectFit ? .resizeAspect : .resizeAspectFill
        guard surface.superview !== tile else { return surface }
        surrenderSurface()
        surface.paintsOpaqueGround = false
        surface.isUserInteractionEnabled = false
        surface.isHidden = false
        // ⚠️ **`insertSubview(at:)` AND THE CONSTRAINTS BY HAND, NOT `pin(to:)`.**
        // DesignSystem's `pin` calls `addSubview` itself, which appends — the
        // badges would end up underneath, which is the whole thing the index
        // above exists to avoid.
        surface.translatesAutoresizingMaskIntoConstraints = false
        if let sheet = sheets[id] {
            tile.insertSubview(surface, aboveSubview: sheet)
        } else {
            tile.insertSubview(surface, at: 0)
        }
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            surface.topAnchor.constraint(equalTo: tile.topAnchor),
            surface.bottomAnchor.constraint(equalTo: tile.bottomAnchor)
        ])
        surface.fadeInOnFirstFrame(over: 0.2)
        return surface
    }

    /// Takes the surface back off whatever tile it was over. Idempotent, and
    /// silent — the caller is the one who stopped the player.
    func hideVideoSurface() {
        guard surface.superview != nil else { return }
        detachSurface()
    }

    /// Detaches a bound surface and says so, for the paths where the tile is
    /// about to go away under it.
    private func surrenderSurface() {
        guard surface.superview != nil else { return }
        detachSurface()
        onSurfaceLost?(surface)
    }

    private func detachSurface() {
        surface.isHidden = true
        surface.removeFromSuperview()
    }

    /// ⚠️ **A LIST CELL IS RECYCLED WITHOUT ASKING.** There is one media row on
    /// this screen and it is the first, so this rarely fires — but "rarely" is
    /// how a surface handed to a player ends up inside somebody else's cell.
    override func prepareForReuse() {
        super.prepareForReuse()
        surrenderSurface()
        onSurfaceLost = nil
        shown = []
        tiles.removeAll()
        sheets.removeAll()
        coverBadges.removeAll()
        clips.removeAll()
        clipStates.removeAll()
        heldForArrival.removeAll()
    }

    #if DEBUG
    /// A change to a cover badge, as it was decided.
    struct BadgeChange: Equatable {
        let id: String
        let showing: Bool
        /// Zero for a change made at once.
        let duration: TimeInterval
        /// Nil for a curve that is not a spring.
        let dampingRatio: CGFloat?
    }

    /// Internal for tests: every change to a cover badge, in order.
    ///
    /// ⚠️ **THE DECISION, BECAUSE THE DRAWING CANNOT BE ASKED.** `UIView.animate`
    /// writes the END values to the model when it is called, so `alpha` and
    /// `transform` read the same whether a curve ran, is running, or was never
    /// asked for (`uiview-animate-from-value-trap`). What can be asked is what
    /// was chosen: which way, how long, and on what curve.
    private(set) var debugBadgeChanges: [BadgeChange] = []
    /// Internal for tests: each ripple the strip played, as the delay of every
    /// tile in strip order — the choreography's decision, for the reason given
    /// on `debugBadgeChanges`.
    private(set) var debugArrivals: [[TimeInterval]] = []
    /// Internal for tests: how many tiles are built invisible, waiting for the
    /// screen to land.
    var debugHeldTileCount: Int { heldForArrival.count }
    /// Internal for tests: the item each tile stands for, in strip order.
    var debugTileIDs: [String] {
        row.arrangedSubviews.compactMap { view in tiles.first { $0.value === view }?.key }
    }

    /// Internal for tests: which tile the video surface is laid over, by item
    /// id — nil when nothing is laid over anything.
    ///
    /// ⚠️ **ASKED BY THE ID THE TILE STANDS FOR, NOT BY ITS INDEX.** The strip
    /// is drawn in `publishOrder`, so the cover is index 0 by construction and
    /// an index assertion would pass over a strip that always played its first
    /// tile whatever the cover was.
    var debugSurfaceTileID: String? {
        guard let host = surface.superview else { return nil }
        return tiles.first { $0.value === host }?.key
    }

    /// Internal for tests: what each clip tile is doing.
    func debugClipState(for id: String) -> ClipState? { clipStates[id] }
    /// Internal for tests: the press on `id`'s tile.
    func debugPressFeedback(for id: String) -> PressFeedback? {
        tiles[id].flatMap { PressFeedback.attached(to: $0) }
    }
    /// Internal for tests: whether `id`'s sheet is actually cycling — the
    /// drawing, next to the state above.
    func debugSheetIsCycling(for id: String) -> Bool { sheets[id]?.isAnimating == true }
    /// Internal for tests: whether the cover's word is showing on `id`'s tile —
    /// or will be, once any curve under way has run.
    ///
    /// ⚠️ **THE MODEL, WHICH IS WHERE A CURVE ENDS.** A departure leaves
    /// `isHidden` false until it finishes, so asking `isHidden` alone would
    /// answer "showing" for the length of every fade-out. Alpha is set to its
    /// end value the moment the curve is asked for.
    func debugCoverBadgeIsShowing(for id: String) -> Bool {
        guard let badge = coverBadges[id] else { return false }
        return !badge.isHidden && badge.alpha > 0
    }
    /// Internal for tests: how many frames `id`'s sheet is cycling.
    func debugSheetFrameCount(for id: String) -> Int { sheets[id]?.animationImages?.count ?? 0 }
    /// Internal for tests: whether the sheet is UNDER the surface on `id`'s
    /// tile — the fallback position, asked of the view order rather than
    /// assumed from the call that installed them.
    func debugSheetIsUnderTheSurface(for id: String) -> Bool? {
        guard let tile = tiles[id], let sheet = sheets[id], surface.superview === tile else { return nil }
        guard let sheetAt = tile.subviews.firstIndex(of: sheet),
              let surfaceAt = tile.subviews.firstIndex(of: surface)
        else { return nil }
        return sheetAt < surfaceAt
    }
    /// Internal for tests: a tap on a clip's tile, through the routine the
    /// recogniser calls — so a test drives the wiring and not a copy of it.
    func debugTapTile(_ id: String) {
        guard clips.contains(id) else { return }
        onTileTapped?(id)
    }
    /// Internal for tests: the surface itself, only while it is installed — so
    /// a test can say the seam was handed THIS one.
    var debugVideoSurface: VideoRenderView? { surface.superview == nil ? nil : surface }

    /// Internal for tests: how each thumbnail lays its picture, in strip order.
    ///
    /// ⚠️ **ASKED OF THE STRIP, NOT HUNTED FOR IN THE WINDOW.** A recursive
    /// search for `UIImageView` also finds the video badge, which would make the
    /// count wrong and the order meaningless. And a screenshot cannot answer
    /// this at all: the tiles are pinned to 156x208, which IS 3:4, so a 3:4
    /// picture fitted into one letterboxes by ZERO — fill and fit are
    /// pixel-identical for those items.
    var debugContentModes: [UIView.ContentMode] {
        row.arrangedSubviews.compactMap { ($0 as? UIImageView)?.contentMode }
    }
    #endif

    override func layoutSubviews() {
        super.layoutSubviews()
        centreContentIfItFits()
    }

    /// Centres the thumbnails while they fit, and lets them run edge to edge
    /// once they do not — the same rule the picker's tray follows.
    private func centreContentIfItFits() {
        let count = row.arrangedSubviews.count
        guard count > 0, bounds.width > 0 else { return }
        let content = CGFloat(count) * Metrics.width + CGFloat(count - 1) * Spacing.sm
        let side = max(Spacing.lg, (bounds.width - content) / 2)
        guard abs(scroller.contentInset.left - side) > 0.5 else { return }
        scroller.contentInset.left = side
        scroller.contentInset.right = side
    }

    private static func label(for item: MediaLibraryItem, isCover: Bool) -> String {
        let subject = item.isVideo ? "Video" : "Photo"
        return isCover ? "\(subject), the cover" : subject
    }

    /// A small capsule laid on the picture. Pinned inside its host on the way
    /// out, so the caller only has to add it.
    private static func badge(text: String) -> UIView {
        CoverBadgeHost(text: text)
    }
}

/// The "Cover" capsule, positioned against whatever picture it is added to.
///
/// ⚠️ **A BADGE CANNOT CONSTRAIN ITSELF BEFORE IT HAS A PARENT.** Building the
/// capsule and pinning it in the same breath needs the superview, which does not
/// exist until `addSubview`. This view does its own pinning in
/// `didMoveToSuperview`, so the caller adds it and nothing else.
private final class CoverBadgeHost: UIView {
    /// ⚠️ **NO EFFECT AT BIRTH.** Materialising a `UIBlurEffect` in an
    /// initializer contacts the render server, and on a headless CI simulator
    /// that stalled the main actor ~45s and reddened an unrelated suite
    /// (PR #46). The effect is set in `didMoveToWindow`, which is the same
    /// recipe the comment ticker and `ProgressiveBlurView` follow.
    private let frost = UIVisualEffectView(effect: nil)
    private let label = UILabel()

    init(text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false

        label.text = text
        label.font = .preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white

        frost.clipsToBounds = true
        frost.layer.cornerCurve = .continuous
        frost.pin(to: self)
        label.pin(to: frost.contentView, insets: NSDirectionalEdgeInsets(
            top: Spacing.xs / 2, leading: Spacing.sm,
            bottom: Spacing.xs / 2, trailing: Spacing.sm
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, frost.effect == nil else { return }
        frost.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard let host = superview else { return }
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.topAnchor, constant: Spacing.sm),
            leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Spacing.sm)
        ])
    }

    /// ⚠️ **A PERFECT PILL IS HALF THE HEIGHT, AND ONLY LAYOUT KNOWS IT.** The
    /// previous radius was a fixed 10pt with a comment claiming the frame
    /// clamped it — nothing clamps a corner radius, so at Dynamic Type sizes
    /// either side of the default it read as a rounded rectangle rather than a
    /// capsule.
    override func layoutSubviews() {
        super.layoutSubviews()
        frost.layer.cornerRadius = bounds.height / 2
    }
}

/// A row whose whole content is one button — "Change cover".
///
/// A button rather than a selectable list row, because it opens a menu: the
/// menu has to hang off a view UIKit can present from, and a list cell's
/// selection is not one.
///
/// ⚠️ **THE BUTTON HUGS ITS WORDS, BECAUSE A FULL-WIDTH ONE TOOK THE WHOLE SHEET
/// OFF THE SCREEN.** Reported as "tapping Change cover makes the window
/// disappear": with the menu open the MAP showed where the upload sheet had
/// been, and the sheet came back once the menu closed. The button used to be
/// pinned to the row's full width with its title centred inside it. Measured
/// on the iPhone 18 Pro simulator (iOS 27, 402pt wide), ONE button with ONE
/// menu, only its width changed at runtime from the debugger:
///
/// | width | menu opens               | sheet    |
/// |-------|--------------------------|----------|
/// | 402   | at the window's top, y=79 | vanishes |
/// | 396   | at the window's top       | vanishes |
/// | 370   | on the button             | stays    |
/// | 142   | on the button             | stays    |
///
/// `.plain()` and `.gray()` behaved alike, and hiding the strip above changed
/// nothing; the Comments menu on the same screen, hung off a capsule in a row's
/// accessory, never did it. The dismiss tap (`dismissTapName`) is not involved
/// — the narrow button carries it too — and neither is `setCover`: the sheet is
/// gone before any choice is made.
///
/// ⚠️ **NOTHING IN THE VIEW TREE SAYS SO — THE SYMPTOM LIVES IN THE RENDER
/// SERVER.** Read with the sheet gone from the screen: the menu is a
/// `_UIContextMenuActionsOnlyViewController` presented BY the upload stack, and
/// the sheet's `UIDropShadowView` still sits at (0, 62, 402, 812), not hidden,
/// alpha 1, with no animation on its layer. So no assertion on the hierarchy
/// can see the defect; what a test can pin is the width that causes it
/// (`NewPostTests.theCoverButtonLeavesItsRowRoomEitherSide`).
///
/// ⚠️ **CAPPED, WELL SHORT OF THE EDGE, BECAUSE THE EDGE IS NOT PUBLISHED.** It
/// lies somewhere between 370 and 396 on a 402pt window, and UIKit does not say
/// where or what it is measured against. The cap is 80% of the row — under the
/// 92% measured safe — so a title that grows at a large type size wraps
/// instead of widening back into the band that fails. Only one phone width
/// was measured.
final class NewPostButtonCell: UICollectionViewListCell {
    private let button = UIButton(configuration: .plain())

    /// The most of the row the button may take — see the type's note.
    static let widestShare: CGFloat = 0.8

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.showsMenuAsPrimaryAction = true
        button.configuration?.contentInsets = .zero
        // Centred in the screen, not tucked against the leading edge: it is the
        // one action belonging to the strip above it, so it sits under its
        // middle rather than beside its first tile.
        button.constrain(in: contentView) { host in
            button.topAnchor.constraint(equalTo: host.topAnchor, constant: Spacing.xs)
            button.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Spacing.xs)
            button.centerXAnchor.constraint(equalTo: host.centerXAnchor)
            button.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, multiplier: Self.widestShare)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, symbolName: String, menu: UIMenu, isEnabled: Bool) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: symbolName)
        configuration.imagePadding = Spacing.sm
        configuration.contentInsets = .zero
        button.configuration = configuration
        button.menu = menu
        button.isEnabled = isEnabled
    }

    #if DEBUG
    /// Internal for tests: where the button sits in its row, and how wide the
    /// row is — the geometry the type's note is about.
    var debugButtonFrame: CGRect { button.frame }
    var debugRowWidth: CGFloat { contentView.bounds.width }
    /// Internal for tests: the menu the button opens.
    var debugMenu: UIMenu? { button.menu }
    #endif
}

/// The title field.
///
/// ⚠️ **DRAWN, TYPED INTO, AND NOT SENT** (`dev/BACKEND_GAPS.md` §21).
/// `post.v1` has exactly one free-text field, `caption`, and folding a title
/// into it would publish a composite string no reader could split back apart.
final class NewPostTitleCell: UICollectionViewListCell {
    private let field = UITextField()
    private var onChange: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        field.font = .preferredFont(forTextStyle: .headline)
        field.adjustsFontForContentSizeCategory = true
        field.placeholder = "Add a title"
        field.returnKeyType = .next
        field.addAction(
            UIAction { [weak self] action in
                guard let field = action.sender as? UITextField else { return }
                self?.onChange?(field.text ?? "")
            },
            for: .editingChanged
        )
        // ⚠️ INTERNAL MARGINS ARE STATED, NOT INHERITED. Pinned to the content
        // view's edges the text runs into the card's rounded corner and is
        // clipped by it — which is exactly how this first shipped.
        field.pin(to: contentView, insets: Self.textInsets)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The padding that keeps text clear of an inset-grouped card's corner.
    /// Shared with the caption below, so the two fields line up.
    static let textInsets = NSDirectionalEdgeInsets(
        top: Spacing.md, leading: Spacing.sm, bottom: Spacing.md, trailing: Spacing.sm
    )

    func configure(text: String, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        if field.text != text { field.text = text }
    }
}

/// The caption field.
///
/// A `UITextView` with a placeholder LABEL beside it, and a height that grows
/// with the text to a ceiling — the recipe Feed's `CommentsInputBar` uses, which
/// cannot be imported here (features do not import one another) and is small
/// enough to restate rather than promote.
///
/// ⚠️ **A `UITextView` HAS NO PLACEHOLDER.** The label is a real sibling toggled
/// on `hasText`; every "placeholder" on a text view in UIKit is this.
final class NewPostCaptionCell: UICollectionViewListCell {
    private enum Metrics {
        static let minimumHeight: CGFloat = 96
        static let maximumHeight: CGFloat = 220
    }

    private let field = UITextView()
    private let placeholder = UILabel()
    private var heightConstraint: NSLayoutConstraint!
    private var onChange: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.backgroundColor = .clear
        field.textContainerInset = .zero
        field.textContainer.lineFragmentPadding = 0
        // ⚠️ **ALWAYS SCROLLABLE, SO THERE IS NO SWITCH LEFT TO MISS.** This was
        // false, with scrolling turned on once the text passed a ceiling — a flip
        // that never fired because the comparison landed exactly on its own edge
        // (`fitting > maximumHeight`, both 220). Scrolling from the start deletes
        // the flip rather than repairing it. See `resize()` for the measurement,
        // and for the wrong mechanism I first wrote there.
        field.isScrollEnabled = true
        field.delegate = self

        placeholder.text = "Write a caption…"
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.numberOfLines = 0

        // The same internal margins the title wears — see the note there.
        field.pin(to: contentView, insets: NewPostTitleCell.textInsets)
        placeholder.constrain(in: contentView) { _ in
            placeholder.leadingAnchor.constraint(equalTo: field.leadingAnchor)
            placeholder.trailingAnchor.constraint(equalTo: field.trailingAnchor)
            placeholder.topAnchor.constraint(equalTo: field.topAnchor)
        }
        heightConstraint = field.heightAnchor.constraint(equalToConstant: Metrics.minimumHeight)
        heightConstraint.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(text: String, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        if field.text != text { field.text = text }
        placeholder.isHidden = field.hasText
        resize()
    }

    /// ⚠️ **THE FIRST MEASUREMENT USED TO BE THE ONLY ONE, AND IT WAS TAKEN AT
    /// ZERO WIDTH.** `configure` runs before the cell has a rectangle — measured
    /// `width=0.0 fitting=22.0` — and nothing re-ran it afterwards: not a layout
    /// pass, not even focusing the field, which was confirmed by the probe
    /// staying at a single line through both. Re-running it here is what gives
    /// the caption a real width to measure against.
    override func layoutSubviews() {
        super.layoutSubviews()
        // ⚠️ **THE CELL'S LAYOUT PASS SIZES `contentView`, NOT ITS SUBVIEWS.**
        // Measured right here: `contentW=370.0` while `field.bounds.width` was
        // still `0.0`. The container had just been given its frame; the field's
        // own constraints resolve in a LATER pass, so a measurement taken now
        // describes a zero-width text container and `contentSize` means nothing.
        // That is why adding this override did not, on its own, fix the
        // first-measurement bug — the probe still read `width=0.0` from here.
        //
        // Laying the content out first is what hands the measurement a real
        // width. The guard in `resize()` is what stops the extra pass looping.
        contentView.layoutIfNeeded()
        resize()
    }

    /// Grows to a ceiling, then scrolls past it, so a long caption never pushes
    /// the settings off the screen.
    private func resize() {
        // ⚠️ **`contentSize` — AND THE FIRST EXPLANATION WRITTEN HERE WAS WRONG.**
        // It claimed `sizeThatFits` was clamped by the very ceiling it existed to
        // detect crossing, citing `fitting=220.0` across 450 consecutive calls as
        // proof. That was a coincidence dressed as a mechanism: 449 characters at
        // this width are genuinely 220pt tall, and the ceiling is also 220.
        // Doubling the text settled it — `fitting` went to 418.0, so nothing was
        // ever clamped.
        //
        // What the old rule actually died on was the strict comparison landing on
        // that knife edge: `fitting > maximumHeight` with both at exactly 220 is
        // false, so scrolling never switched on. Measuring `contentSize` against
        // a view that always scrolls deletes the flip, so there is no edge left
        // to land on — and the symptom the viewer reported (four lines, the rest
        // unreachable) came from the CELL never re-measuring, not from here.
        let fitting = field.contentSize.height
        let height = min(max(fitting, Metrics.minimumHeight), Metrics.maximumHeight)
        // ⚠️ THE GUARD ALSO BREAKS THE LAYOUT LOOP. `layoutSubviews` calls this,
        // and this invalidates the cell's measurement — which lays out again.
        // Bailing once the height has settled is what stops that going round.
        guard abs(heightConstraint.constant - height) > 0.5 else { return }
        heightConstraint.constant = height
        // ⚠️ **AND THE CELL HAS TO BE TOLD, MEASURED AFTER LAYOUT.** With the
        // constraint reading 220 the cell was still 120: a self-sizing list cell
        // does not re-measure itself because a constraint inside it moved, so the
        // caption was clipped on top of never scrolling.
        invalidateIntrinsicContentSize()
    }
}

extension NewPostCaptionCell: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = textView.hasText
        resize()
        onChange?(textView.text ?? "")
        keepCaretVisible()
    }

    /// Arrow keys, a tap into the middle of the text, or the selection moving
    /// after a paste — all of them can put the caret outside the window without
    /// the text changing at all.
    func textViewDidChangeSelection(_ textView: UITextView) {
        keepCaretVisible()
    }
}

private extension NewPostCaptionCell {
    /// ⚠️ **GROWING TO A CEILING IS ONLY HALF A TEXT AREA.** Once the field has
    /// reached its maximum height it scrolls, and from that moment a caret that
    /// walks off the top or the bottom is invisible while you are typing into
    /// it. `scrollRangeToVisible` follows the CARET; the height rule only
    /// follows the text.
    ///
    /// ⚠️ Deferred a turn on purpose: when the delegate fires, the layout
    /// manager has not yet laid out the glyph just typed, so asking to reveal
    /// the selection now scrolls to where the caret USED to be.
    func keepCaretVisible() {
        guard field.isScrollEnabled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, field.isScrollEnabled else { return }
            field.scrollRangeToVisible(field.selectedRange)
        }
    }
}
