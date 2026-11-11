import CoreModels
import DesignSystem
import MapKit
import PostGrid
import UIKit

/// The text bubble (#2203, the owner, 2026-11-09; every build since #2299): the TEXT marker nearest the
/// map's centre opens a bubble round it with its author and its words — see
/// `MapTextBubbleView` and `MapFeaturedHalo`.
///
/// - **Which post.** The text markers standing on their own in the map's
///   open part (between the top of the screen and the bottom bars), the
///   nearest to that part's centre — with a little give, so two markers at
///   almost the same distance do not take turns as the map drifts. A group
///   whose face is a text post counts as that post (the face the viewer
///   sees) — a city's or a country's too (the owner, 2026-11-09), with the
///   same bubble; one whose face is a picture never takes it.
/// - **When.** Once the map RESTS, a moment after (`textBubbleSettleDelay`,
///   the owner, 2026-11-09: no bubble opening and closing under a moving
///   map) — and as markers arrive on a resting map. While it moves, the
///   bubble that is open stays, riding with its marker.
/// - **Its words.** From what the feed already holds, else asked for — the
///   featured post and its nearest neighbours together, so a small pan
///   lands on words in hand. The bubble opens once they are.
/// - **A tap** anywhere on the bubble is its marker's: it opens the post.
extension MapsViewController {
    /// How much nearer another marker must be to take the bubble from the
    /// one it speaks for.
    static let textBubbleGive: CGFloat = 18
    /// How many of the nearest text posts' words are asked for at once.
    static let textBubbleLookahead = 6
    /// How long the map rests before the bubble picks again.
    /// Short (the owner, 2026-11-09: 0.35 s felt late): enough to let a
    /// pinch's pauses go by, not enough to be seen waiting.
    static let textBubbleSettleDelay: TimeInterval = 0.15

    // MARK: - Choosing the post

    /// The map's open part, in the map's space: under the top of the screen,
    /// above the bottom bars.
    var textBubbleOpenRect: CGRect {
        let top = view.safeAreaInsets.top
        let bottom = barsStack.window == nil
            ? mapView.bounds.maxY - view.safeAreaInsets.bottom
            : barsStack.convert(barsStack.bounds, to: mapView).minY
        return CGRect(x: 0, y: top, width: mapView.bounds.width, height: max(0, bottom - top))
    }

    /// The text post a marker shows — a single text marker's, or a group's
    /// whose face is a text post, a city's or a country's included — nil for
    /// a picture's.
    static func textBubblePin(of annotation: any MKAnnotation) -> MapPin? {
        switch annotation {
        case let single as MapAnnotation:
            single.pin.isText ? single.pin : nil
        case let group as MapComputedCluster:
            group.representative.isText ? group.representative : nil
        default:
            nil
        }
    }

    /// The text markers in the open part, with their post and where they stand.
    func textBubbleCandidates() -> [(annotation: any MKAnnotation, pin: MapPin, point: CGPoint)] {
        let open = textBubbleOpenRect
        return mapView.annotations(in: mapView.visibleMapRect).compactMap { item in
            guard let annotation = item as? any MKAnnotation, let pin = Self.textBubblePin(of: annotation) else { return nil }
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

    /// The marker the bubble should speak for, `current` keeping it unless
    /// another is nearer by more than the give. Pure, for tests.
    static func textBubblePick(
        candidates: [(id: PostID, point: CGPoint)], centre: CGPoint, current: PostID?, give: CGFloat = textBubbleGive
    ) -> PostID? {
        func distance(_ point: CGPoint) -> CGFloat { hypot(point.x - centre.x, point.y - centre.y) }
        guard let best = candidates.min(by: { distance($0.point) < distance($1.point) }) else { return nil }
        if let current, let kept = candidates.first(where: { $0.id == current }),
           distance(kept.point) - give <= distance(best.point) {
            return current
        }
        return best.id
    }

    /// The marker nearest the open part's centre takes the bubble.
    func updateTextBubble(animated: Bool) {
        guard !isGuestLocked else { return feature(nil, animated: animated) }
        let candidates = textBubbleCandidates()
        let open = textBubbleOpenRect
        let centre = CGPoint(x: open.midX, y: open.midY)
        let current = textBubbleFeatured.flatMap(Self.textBubblePin(of:))?.postID
        let picked = Self.textBubblePick(
            candidates: candidates.map { ($0.pin.postID, $0.point) }, centre: centre, current: current
        )
        feature(candidates.first { $0.pin.postID == picked }?.annotation, animated: animated)
        prefetchTextBubblePosts(around: centre, among: candidates)
    }

    /// `annotation`'s marker takes the bubble (nil: none has it); the one
    /// that had it folds its own away.
    func feature(_ annotation: (any MKAnnotation)?, animated: Bool) {
        let before = textBubbleFeatured
        guard !Self.same(before, annotation) else {
            // The same marker: its words may have arrived since.
            if let annotation { showBubble(on: annotation, animated: animated) }
            return
        }
        textBubbleFeatured = annotation
        if let before { setMarker(before, featured: false, animated: animated) }
        guard let annotation else { return }
        setMarker(annotation, featured: true, animated: animated)
        showBubble(on: annotation, animated: animated)
    }

    /// The featured marker's bubble with its post's author and words, once
    /// they are in hand (asked for otherwise; the bubble opens then).
    private func showBubble(on annotation: any MKAnnotation, animated: Bool) {
        guard let pin = Self.textBubblePin(of: annotation) else { return }
        guard let post = textBubblePost(pin.postID) else { return loadTextBubblePosts([pin.postID]) }
        // The marker's own read of a showcase's card stands in for a post
        // read without one (#2216).
        let content = MapTextBubbleView.Content.of(post, pinEmbed: pin.embed)
        switch mapView.view(for: annotation) {
        case let single as MapAnnotationView: single.setBubble(content, animated: animated)
        case let group as MapClusterAnnotationView: group.setBubble(content, animated: animated)
        default: break
        }
    }

    /// A marker's view — a single one or a group — featured or not.
    private func setMarker(_ annotation: any MKAnnotation, featured: Bool, animated: Bool) {
        switch mapView.view(for: annotation) {
        case let single as MapAnnotationView: single.setFeatured(featured, animated: animated)
        case let group as MapClusterAnnotationView: group.setFeatured(featured, animated: animated)
        default: break
        }
    }

    // MARK: - The words

    private func textBubblePost(_ id: PostID) -> GalleryPost? {
        if let post = textBubblePosts[id] { return post }
        guard let held = heldTextPost(id) else { return nil }
        textBubblePosts[id] = held
        return held
    }

    /// The featured post's nearest neighbours' words, asked for now, so a
    /// small pan lands on words in hand.
    private func prefetchTextBubblePosts(
        around centre: CGPoint, among candidates: [(annotation: any MKAnnotation, pin: MapPin, point: CGPoint)]
    ) {
        let missing = candidates
            .sorted { hypot($0.point.x - centre.x, $0.point.y - centre.y) < hypot($1.point.x - centre.x, $1.point.y - centre.y) }
            .prefix(Self.textBubbleLookahead)
            .map(\.pin.postID)
            .filter { textBubblePost($0) == nil }
        loadTextBubblePosts(missing)
    }

    private func loadTextBubblePosts(_ ids: [PostID]) {
        let wanted = ids.filter { textBubblePosts[$0] == nil }
        guard !wanted.isEmpty else { return }
        let load = loadTextPosts
        Task { [weak self] in
            let posts = await load(wanted)
            guard let self else { return }
            textBubblePosts.merge(posts) { _, new in new }
            // The featured post's words arrived: its bubble opens.
            guard let featured = textBubbleFeatured, let pin = Self.textBubblePin(of: featured), posts[pin.postID] != nil
            else { return }
            showBubble(on: featured, animated: view.window != nil)
        }
    }

    // MARK: - The map's moments

    /// The map rests: the bubble picks again, a moment later — unless the
    /// map moves again first.
    func textBubbleRegionSettled() {
        scheduleTextBubbleUpdate()
    }

    /// A marker kept through a re-cluster, its face changed (a group led by
    /// another post now, or a single moved on): if it is the featured one
    /// and its bubble speaks for a post it no longer shows, the bubble folds
    /// now — never the old words round a new face (the owner, 2026-11-09, a
    /// fast zoom) — and the next pick, once the map rests, opens the right one.
    func textBubbleMarkerChanged(_ annotation: any MKAnnotation) {
        guard Self.same(annotation, textBubbleFeatured) else { return }
        let shown: PostID? = switch mapView.view(for: annotation) {
        case let single as MapAnnotationView: single.bubblePostID
        case let group as MapClusterAnnotationView: group.bubblePostID
        default: nil
        }
        guard shown != Self.textBubblePin(of: annotation)?.postID else { return }
        feature(nil, animated: true)
        if !isRegionTransitioning { scheduleTextBubbleUpdate() }
    }

    /// The map starts to move: a pick still waiting is dropped.
    func textBubbleRegionWillChange() {
        textBubbleSettle?.cancel()
        textBubbleSettle = nil
    }

    /// The bubble's pick, `textBubbleSettleDelay` from now, once.
    private func scheduleTextBubbleUpdate() {
        textBubbleSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            textBubbleSettle = nil
            guard !isRegionTransitioning else { return }
            updateTextBubble(animated: true)
        }
        textBubbleSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.textBubbleSettleDelay, execute: work)
    }

    /// Markers arrived: the featured one stands out again (a view realized
    /// afresh) and opens its bubble, and one may be the first post.
    func textBubbleViewsAdded(_ views: [MKAnnotationView]) {
        if let featured = textBubbleFeatured {
            for view in views where Self.same(view.annotation, featured) {
                (view as? MapAnnotationView)?.setFeatured(true, animated: false)
                (view as? MapClusterAnnotationView)?.setFeatured(true, animated: false)
                // In sight, it opens as anywhere else (the halo asks the window).
                showBubble(on: featured, animated: true)
            }
        }
        // The first markers make the first pick — once the map rests.
        if textBubbleFeatured == nil, !isRegionTransitioning { scheduleTextBubbleUpdate() }
    }

    #if DEBUG
    /// The featured post, for the specs.
    var debugTextBubblePostID: PostID? { textBubbleFeatured.flatMap(Self.textBubblePin(of:))?.postID }
    #endif
}
