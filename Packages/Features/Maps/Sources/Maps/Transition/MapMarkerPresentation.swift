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
/// A text marker has no cover at either end of a flight, and flying a symbol
/// on a tinted circle was a hero animation about nothing.
///
/// ⚠️ IT OPENS WITH THE PLATFORM'S PUSH (#2015, the owner 2026-11-01): a text
/// marker, an avatar, an emote, a GIF — the page slides in from the right and
/// goes back the native way, uncovering the map. It opened as a window growing
/// out of the disc from #125 (2026-08-21) until then. The map pushes ON
/// PURPOSE: For You and the profile keep the window for their text rows, so
/// one post can arrive two ways — the owner asked for the map only.
///
/// "A screen closes the way it opened": a plain-pushed feed closes with the
/// native pop whatever page is on screen by then (the plain push pins it), and
/// a flight-opened feed paged onto a text post still closes as the marker's
/// window (`makeRevealGeometry`) — a custom opening, a custom close.
///
/// Pure and marker-shaped so the decision can be pinned by a test: the view
/// controller needs a live `MKMapView` to exist at all, and the rule does not.
enum MapMarkerPresentation: Equatable {
    /// The custom zoom flight, card and all.
    case hero
    /// A standard push: right-to-left slide in, swipe or chevron back. Every
    /// non-media marker (#2015), and every marker under Reduce Motion.
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
    /// With `reducesMotion` (`HeroMotionPolicy`), every face opens with the
    /// plain push: no zoom.
    init(face: PinCardView.Face, reducesMotion: Bool) {
        self = reducesMotion ? .plainPush : MapMarkerPresentation(face: face)
    }

    init(face: PinCardView.Face) {
        // ⚠️ Written as "is it media" rather than "is it text", so a face
        // added later gets the PLAIN PUSH by default. An icon pin is a text
        // post — its page is a text page — and the old form would silently have
        // flown it as a photograph.
        self = face == .media ? .hero : .plainPush
    }
}
