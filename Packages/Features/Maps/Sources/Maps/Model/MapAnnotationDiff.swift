import CoreModels

/// The minimal set of annotation mutations to apply to `MKMapView` for a new
/// viewport result. The whole point is *not* to `removeAnnotations(all) +
/// addAnnotations(all)` on every pan — that flickers, re-fades every marker,
/// and (in Step B) tears down any playing preview. Instead we diff by stable
/// `post_id` identity and touch only what actually changed; a small pan that
/// returns a mostly-overlapping set produces a tiny diff.
public struct MapAnnotationDiff: Equatable, Sendable {
    /// Pins present in the new result but not currently on the map.
    public var added: [MapPin]
    /// Pins currently on the map but absent from the new result.
    public var removed: [MapPin]
    /// Pins present in both whose content changed (thumbnail, coordinate, or
    /// media kind) — the marker stays put but its view is refreshed in place.
    public var updated: [MapPin]

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && updated.isEmpty }

    public init(added: [MapPin] = [], removed: [MapPin] = [], updated: [MapPin] = []) {
        self.added = added
        self.removed = removed
        self.updated = updated
    }
}

/// Pure identity diff over pin sets, keyed by `post_id`. Kept free of MapKit so
/// the anti-stutter logic is unit-tested without a live map view.
public enum MapAnnotationDiffer {
    /// Diffs the currently-shown pins (`current`, keyed by id) against the new
    /// `incoming` list. Order of `incoming` is preserved within `added`; the
    /// caller applies removals before additions.
    public static func diff(from current: [PostID: MapPin], to incoming: [MapPin]) -> MapAnnotationDiff {
        var diff = MapAnnotationDiff()
        var incomingIDs = Set<PostID>()
        incomingIDs.reserveCapacity(incoming.count)

        for pin in incoming {
            incomingIDs.insert(pin.postID)
            if let existing = current[pin.postID] {
                if existing != pin { diff.updated.append(pin) }
            } else {
                diff.added.append(pin)
            }
        }
        for (id, pin) in current where !incomingIDs.contains(id) {
            diff.removed.append(pin)
        }
        return diff
    }
}
