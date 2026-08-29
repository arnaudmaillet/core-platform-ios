/// The card's metric line, as the grid spells it: absent counts are `nil`, not
/// zero.
///
/// `PostMetricLabel` hides itself for a `nil` and renders a `0` — "absence,
/// not an asserted zero" — so carrying optionals all the way through is what
/// keeps a seeded page from claiming a post has no views when nobody has said
/// how many it has.
///
/// It outlived the view it was declared beside. `PostCaptionRowView` drew a
/// text post's caption as the gallery card's flat content — no bubble, no
/// avatar — and was deleted when the caption row stopped having two faces (see
/// `CaptionBubbleCell`). The type stays because the GRID's own line still needs
/// it, and because the opener still hands its counts to a page that has only
/// one of them to show.
struct PostCardMetrics: Equatable, Sendable {
    let views: Int64?
    let reactions: Int64?
    let comments: Int64?

    var isEmpty: Bool { views == nil && reactions == nil && comments == nil }
}
