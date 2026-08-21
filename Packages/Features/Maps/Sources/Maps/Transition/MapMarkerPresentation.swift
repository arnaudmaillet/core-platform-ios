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
/// A text marker has no cover at either end of a FLIGHT, and flying a symbol on
/// a tinted circle was a hero animation about nothing: the card carried no
/// content the destination would show, so it read as a graphic effect rather
/// than as continuity. That argument sent it to the platform's own push for a
/// long time, and the note here said so.
///
/// It opens as a WINDOW now. The disc is not a card to fly, it is a hole to
/// grow: the real page is installed at full size behind it and the disc sweeps
/// open to the screen, wearing the marker's own glyph and tint until it has
/// somewhere to hand them to. Nothing impersonates anything, which is exactly
/// why the objection above does not apply — see `RevealGeometry`. The same
/// post opened from For You or a profile gets the same window from its row, so
/// one post still does not arrive three ways.
///
/// Pure and marker-shaped so the decision can be pinned by a test: the view
/// controller needs a live `MKMapView` to exist at all, and the rule does not.
enum MapMarkerPresentation: Equatable {
    /// The custom zoom flight, card and all.
    case hero
    /// The clip-window reveal, opened from the marker's own disc.
    case reveal
    /// A standard push: right-to-left slide in, swipe or chevron back. The
    /// fallback for a marker the reveal cannot describe — one that has scrolled
    /// off, or a build with the window turned off.
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
        self = face == .text ? .reveal : .hero
    }
}
