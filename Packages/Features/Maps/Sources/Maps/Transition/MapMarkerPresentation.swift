/// How a tapped marker opens its post(s).
///
/// The map has two presentations and the choice is a property of the MARKER,
/// not of the destination: both land on the same snap feed.
///
/// A media pin flies. The pin's face and the flying card are the same
/// component, so the card takes off as the marker's exact twin and the viewer
/// watches the photograph they tapped become the page — that is the whole
/// argument for a hero, and it needs a photograph to make it.
///
/// A text marker has no cover at either end of the flight. Flying a symbol on a
/// tinted circle is a hero animation about nothing: the card carries no content
/// the destination will show, so it reads as a graphic effect rather than as
/// continuity, and it delays the words by the length of a spring. The honest
/// presentation is the platform's own push — which is also what the same post
/// gets from For You and from a profile (`SnapFeedHeroOrigin.hasHero`
/// documents the identical rule), so one post does not arrive three ways.
///
/// Pure and marker-shaped so the decision can be pinned by a test: the view
/// controller needs a live `MKMapView` to exist at all, and the rule does not.
enum MapMarkerPresentation: Equatable {
    /// The custom zoom flight, card and all.
    case hero
    /// A standard push: right-to-left slide in, swipe or chevron back.
    case plainPush

    /// Decided by the face the marker is WEARING — which, for a cluster, is its
    /// representative's, and the representative is kind-neutral
    /// (`MapClusterEngine.representative(of:)`). So a MIXED group can wear
    /// either face and gets the presentation that matches it: text face → push,
    /// media face → flight. That is not an approximation of the group's
    /// contents, it is exact about the one post the feed opens on — the
    /// representative leads `memberIDs`, so the face, the transition and the
    /// landing page are the same post. The rest of the group (photos included)
    /// is a swipe away either way.
    init(face: PinCardView.Face) {
        self = face == .text ? .plainPush : .hero
    }
}
