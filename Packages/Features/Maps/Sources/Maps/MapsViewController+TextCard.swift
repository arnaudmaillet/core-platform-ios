import CoreModels
import DesignSystem
import MapKit
import PostGrid
import UIKit

/// `-map-text-card` (the owner, 2026-11-08): the card over the map for the
/// TEXT post nearest its centre — see `MapTextPostCardView`.
///
/// - **Which post.** The text markers standing on their own in the map's
///   open part (between the top of the screen and the card), the nearest to
///   that part's centre — with a little give, so two markers at almost the
///   same distance do not take turns as the map drifts. A group whose face
///   is a text post counts as that post (the face the viewer sees); a city's
///   or a country's marker never does.
/// - **When.** As the map moves (`mapViewDidChangeVisibleRegion`), as it
///   rests, and as markers arrive.
/// - **Its words.** From what the feed already holds, else asked for — the
///   featured post and its nearest neighbours together, so a swipe lands on
///   words in hand. Bones while they come.
extension MapsViewController {
    /// How much nearer another marker must be to take the card from the one
    /// it shows.
    static let textCardGive: CGFloat = 18
    /// How many of the nearest text posts' words are asked for at once.
    static let textCardLookahead = 6

    // MARK: - Installing

    func installTextCard() {
        filterBar.isHidden = true
        subFilterBar.isHidden = true
        textCard.translatesAutoresizingMaskIntoConstraints = false
        textCardSlot.addSubview(textCard)
        NSLayoutConstraint.activate([
            textCard.leadingAnchor.constraint(equalTo: textCardSlot.leadingAnchor, constant: Spacing.md),
            textCard.trailingAnchor.constraint(equalTo: textCardSlot.trailingAnchor, constant: -Spacing.md),
            textCard.topAnchor.constraint(equalTo: textCardSlot.topAnchor),
            textCard.bottomAnchor.constraint(equalTo: textCardSlot.bottomAnchor),
        ])
        barsStack.addArrangedSubview(textCardSlot)
        // The map rests under the carousel: from the top of its slot to the
        // screen's foot — the tab bar's band included — a touch is not a pan
        // (the owner, 2026-11-08). Over the map, under the bars.
        let shield = UIView()
        shield.backgroundColor = .clear
        shield.isUserInteractionEnabled = true
        shield.accessibilityIdentifier = "map-text-card-shield"
        shield.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(shield, belowSubview: barsStack)
        NSLayoutConstraint.activate([
            shield.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            shield.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            shield.topAnchor.constraint(equalTo: textCardSlot.topAnchor),
            shield.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        textCard.onTap = { [weak self] in self?.openTextCardPost() }
        textCard.onSwipe = { [weak self] direction in self?.swipeTextCard(direction) }
    }

    // MARK: - Choosing the post

    /// The map's open part, in the map's space: under the top of the screen,
    /// above the card.
    var textCardOpenRect: CGRect {
        let top = view.safeAreaInsets.top
        let bottom = textCardSlot.window == nil
            ? mapView.bounds.maxY
            : textCardSlot.convert(textCardSlot.bounds, to: mapView).minY
        return CGRect(x: 0, y: top, width: mapView.bounds.width, height: max(0, bottom - top))
    }

    /// The text post a marker shows — a single text marker's, or a group's
    /// whose face is a text post — nil for anything else (a picture, a city,
    /// a country).
    static func textCardPin(of annotation: any MKAnnotation) -> MapPin? {
        switch annotation {
        case let single as MapAnnotation:
            single.pin.isText && single.hierarchyPlace == nil ? single.pin : nil
        case let group as MapComputedCluster:
            group.representative.isText && !group.isHierarchyMarker ? group.representative : nil
        default:
            nil
        }
    }

    /// The text markers in the open part, with their post and where they stand.
    func textCardCandidates() -> [(annotation: any MKAnnotation, pin: MapPin, point: CGPoint)] {
        let open = textCardOpenRect
        return mapView.annotations(in: mapView.visibleMapRect).compactMap { item in
            guard let annotation = item as? any MKAnnotation, let pin = Self.textCardPin(of: annotation) else { return nil }
            let point = mapView.convert(annotation.coordinate, toPointTo: mapView)
            return open.contains(point) ? (annotation, pin, point) : nil
        }
    }

    /// Whether two markers are the same object.
    static func same(_ lhs: (any MKAnnotation)?, _ rhs: (any MKAnnotation)?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (left?, right?): left === right
        default: false
        }
    }

    /// The marker the card should speak for, `current` keeping it unless
    /// another is nearer by more than the give. Pure, for tests.
    static func textCardPick(
        candidates: [(id: PostID, point: CGPoint)], centre: CGPoint, current: PostID?, give: CGFloat = textCardGive
    ) -> PostID? {
        func distance(_ point: CGPoint) -> CGFloat { hypot(point.x - centre.x, point.y - centre.y) }
        guard let best = candidates.min(by: { distance($0.point) < distance($1.point) }) else { return nil }
        if let current, let kept = candidates.first(where: { $0.id == current }),
           distance(kept.point) - give <= distance(best.point) {
            return current
        }
        return best.id
    }

    /// The deck: the text posts in the map's open part, nearest the centre
    /// first — the carousel's loop. Built when the VIEWER moves the map (or
    /// the first time); a swipe's own journey to its post leaves it as it
    /// is, so the loop keeps its order.
    func updateTextCard(animated: Bool) {
        guard usesTextCard else { return }
        guard !isGuestLocked else { return present(nil, behind: nil, turn: .none, animated: animated) }
        guard textCardDeckStale || textCardDeck.isEmpty else { return }
        let candidates = textCardCandidates()
        let open = textCardOpenRect
        let centre = CGPoint(x: open.midX, y: open.midY)
        let current = textCardFeatured.flatMap(Self.textCardPin(of:))?.postID
        let picked = Self.textCardPick(
            candidates: candidates.map { ($0.pin.postID, $0.point) }, centre: centre, current: current
        )
        let deck = candidates
            .sorted { hypot($0.point.x - centre.x, $0.point.y - centre.y) < hypot($1.point.x - centre.x, $1.point.y - centre.y) }
            .map(\.annotation)
        let next = deck.first { Self.textCardPin(of: $0)?.postID == picked }
        // The map brought another post to the centre: the cards turn — back
        // when it is the one before in the old loop, forward otherwise.
        var turn = MapTextPostCardView.Turn.none
        if !Self.same(next, textCardFeatured), textCardFeatured != nil, next != nil {
            turn = Self.same(next, Self.neighbour(of: textCardIndex, in: textCardDeck, by: -1)) ? .previous : .next
        }
        textCardDeck = deck
        textCardIndex = deck.firstIndex { Self.same($0, next) } ?? 0
        present(next, behind: Self.neighbour(of: textCardIndex, in: deck, by: -1), turn: turn, animated: animated)
        prefetchTextCardPosts(around: centre, among: candidates)
    }

    /// The deck's post `step` away from `index`, looping; nil in a deck of
    /// one (a post is not its own neighbour). Pure, for tests.
    static func neighbour(of index: Int, in deck: [any MKAnnotation], by step: Int) -> (any MKAnnotation)? {
        guard deck.count > 1, deck.indices.contains(index) else { return nil }
        let count = deck.count
        return deck[((index + step) % count + count) % count]
    }

    /// The front card speaks for `annotation` (nil: the carousel goes down),
    /// its marker standing out; the card above for `behind` — the post
    /// before it in the loop.
    func present(
        _ annotation: (any MKAnnotation)?, behind: (any MKAnnotation)?, turn: MapTextPostCardView.Turn, animated: Bool
    ) {
        let previous = textCardFeatured
        let changed = !Self.same(previous, annotation)
        textCardFeatured = annotation
        textCardBehind = behind
        if changed, let previous { setMarker(previous, featured: false, animated: animated) }
        guard let annotation, Self.textCardPin(of: annotation) != nil else {
            textCardLoad?.cancel()
            textCardDeck = []
            textCard.show(.hidden, animated: animated)
            return
        }
        if changed { setMarker(annotation, featured: true, animated: animated) }
        textCard.show(textCardShown(for: annotation), behind: textCardShown(for: behind), turn: turn, animated: animated)
    }

    /// What a card shows for `annotation`'s post: its words, or bones while
    /// they are asked for.
    private func textCardShown(for annotation: (any MKAnnotation)?) -> MapTextPostCardView.Shown {
        guard let annotation, let pin = Self.textCardPin(of: annotation) else { return .hidden }
        if let post = textCardPost(pin.postID) { return .content(textCardContent(post, for: pin)) }
        loadTextCardPosts([pin.postID])
        return .loading(pin.postID)
    }

    private func textCardPost(_ id: PostID) -> GalleryPost? {
        if let post = textCardPosts[id] { return post }
        guard let held = heldTextPost(id) else { return nil }
        textCardPosts[id] = held
        return held
    }

    /// A marker's view — a single one or a group — featured or not.
    private func setMarker(_ annotation: any MKAnnotation, featured: Bool, animated: Bool) {
        switch mapView.view(for: annotation) {
        case let single as MapAnnotationView: single.setFeatured(featured, animated: animated)
        case let group as MapClusterAnnotationView: group.setFeatured(featured, animated: animated)
        default: break
        }
    }

    private func textCardContent(_ post: GalleryPost, for pin: MapPin) -> MapTextPostCardView.Content {
        // The place as precise as it is known, its country after it: "Paris,
        // France" (the places run most specific first).
        .of(post, place: Self.textCardPlace(of: pin))
    }

    /// "Paris, France", "France", or nil.
    static func textCardPlace(of pin: MapPin) -> String? {
        let names = pin.places.prefix(2).map(\.name)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    // MARK: - The words

    /// The featured post's nearest neighbours' words, asked for now, so a
    /// swipe or a small pan lands on words in hand.
    private func prefetchTextCardPosts(
        around centre: CGPoint, among candidates: [(annotation: any MKAnnotation, pin: MapPin, point: CGPoint)]
    ) {
        let missing = candidates
            .sorted { hypot($0.point.x - centre.x, $0.point.y - centre.y) < hypot($1.point.x - centre.x, $1.point.y - centre.y) }
            .prefix(Self.textCardLookahead)
            .map(\.pin.postID)
            .filter { textCardPost($0) == nil }
        loadTextCardPosts(missing)
    }

    private func loadTextCardPosts(_ ids: [PostID]) {
        let wanted = ids.filter { textCardPosts[$0] == nil }
        guard !wanted.isEmpty else { return }
        let load = loadTextPosts
        Task { [weak self] in
            let posts = await load(wanted)
            guard let self else { return }
            textCardPosts.merge(posts) { _, new in new }
            // The shown posts' words arrived: bones to words, in place.
            let ids = [textCardFeatured, textCardBehind].compactMap { $0.flatMap(Self.textCardPin(of:))?.postID }
            guard ids.contains(where: { posts[$0] != nil }) else { return }
            textCard.show(
                textCardShown(for: textCardFeatured), behind: textCardShown(for: textCardBehind),
                turn: .none, animated: view.window != nil
            )
        }
    }

    // MARK: - The map's moments

    /// The map rests: the card asks once more, and a swipe's journey ends.
    func textCardRegionSettled() {
        guard usesTextCard else { return }
        textCardFollowsSwipe = false
        updateTextCard(animated: true)
        textCardDeckStale = false
    }

    /// The map starts to move: the viewer's own move rebuilds the deck as it
    /// goes; a swipe's journey does not.
    func textCardRegionWillChange() {
        guard usesTextCard, !textCardFollowsSwipe else { return }
        textCardDeckStale = true
    }

    /// Markers arrived: the featured one stands out again (a view realized
    /// afresh), and one may be the card's first post.
    func textCardViewsAdded(_ views: [MKAnnotationView]) {
        if let featured = textCardFeatured {
            for view in views where Self.same(view.annotation, featured) {
                (view as? MapAnnotationView)?.setFeatured(true, animated: false)
                (view as? MapClusterAnnotationView)?.setFeatured(true, animated: false)
            }
        }
        // The first markers make the first deck; later ones leave it be.
        if textCardDeck.isEmpty, !textCardFollowsSwipe { updateTextCard(animated: true) }
    }

    // MARK: - The card's gestures

    private func openTextCardPost() {
        guard let featured = textCardFeatured else { return }
        openAnnotation(featured, thumbnail: nil)
    }

    /// A swipe turns the carousel one post along the loop — up: the next,
    /// down: the previous — and the map carries the post to the centre.
    private func swipeTextCard(_ turn: MapTextPostCardView.Turn) {
        // Only the posts still on the map.
        let onMap = Set(mapView.annotations.map { ObjectIdentifier($0) })
        let featured = textCardFeatured
        textCardDeck.removeAll { !onMap.contains(ObjectIdentifier($0)) }
        textCardIndex = textCardDeck.firstIndex { Self.same($0, featured) } ?? 0
        let step = turn == .previous ? -1 : 1
        guard turn != .none, let target = Self.neighbour(of: textCardIndex, in: textCardDeck, by: step) else {
            // A loop of one: the carousel's own rubber band already said so.
            Haptics.play(.boundary)
            return
        }
        let count = textCardDeck.count
        textCardIndex = ((textCardIndex + step) % count + count) % count
        textCardFollowsSwipe = true
        present(target, behind: Self.neighbour(of: textCardIndex, in: textCardDeck, by: -1), turn: turn, animated: true)
        centreTextCardMarker(target)
    }

    /// Moves the map so `annotation` stands at the open part's centre.
    private func centreTextCardMarker(_ annotation: any MKAnnotation) {
        let open = textCardOpenRect
        let target = CGPoint(x: open.midX, y: open.midY)
        let point = mapView.convert(annotation.coordinate, toPointTo: mapView)
        let mapCentre = CGPoint(x: mapView.bounds.midX, y: mapView.bounds.midY)
        let shifted = CGPoint(x: mapCentre.x + point.x - target.x, y: mapCentre.y + point.y - target.y)
        let coordinate = mapView.convert(shifted, toCoordinateFrom: mapView)
        mapView.setCenter(coordinate, animated: !MotionPreference.reducesMotion)
        if MotionPreference.reducesMotion { textCardFollowsSwipe = false }
    }

    #if DEBUG
    /// The featured post, for the specs.
    var debugTextCardPostID: PostID? { textCardFeatured.flatMap(Self.textCardPin(of:))?.postID }
    #endif
}
