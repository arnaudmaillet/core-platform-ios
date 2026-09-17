import MediaPlayback

extension MediaTimelining {
    /// The pieces a timeline keeps, as the values the export and the preview are
    /// both built from — EMPTY for a clip nothing has cut.
    ///
    /// ⚠️ **ONE MAPPING, TWO CONSUMERS, AND THAT IS THE POINT.** The editor's
    /// canvas plays exactly what the export will produce; written twice, the two
    /// would agree only until one of them was changed. Empty is not "one piece
    /// covering everything": an empty plan plays and exports the file as shot.
    ///
    /// ⚠️ **AND THE ORDER IS THE TIMELINE'S.** A re-ordered timeline plays its
    /// pieces in the order the author arranged, and nothing here may sort them
    /// back into the order the camera recorded.
    static func exportSegments(
        _ timeline: MediaTimeline, withinSource duration: Double
    ) -> [VideoExportSegment] {
        guard cuts(timeline, withinSource: duration) else { return [] }
        let pieces = resolved(timeline, withinSource: duration)
        return pieces.enumerated().map { index, piece in
            VideoExportSegment(
                start: piece.start, end: piece.end, speed: piece.speed,
                // ⚠️ Nothing after the last piece: there is no cut there.
                transitionOut: index < pieces.count - 1 ? piece.transitionOut : nil,
                look: piece.filter
            )
        }
    }

    /// Whether two timelines play the same film, in the same order, at the same
    /// rates — so that swapping one preview item for the other would change
    /// nothing anybody could see.
    ///
    /// ⚠️ **A SPLIT IS NOT AN EDIT OF THE FILM.** Cutting a piece in two leaves
    /// two touching halves at one rate; rebuilding the preview for it would cost
    /// a visible hitch for no difference. The same goes for an untouched clip and
    /// the one piece at 1× that a rate chip leaves behind when it is set back to
    /// 1. Touching pieces at one rate are merged before the two are compared.
    ///
    /// ⚠️ **AND A TRANSITION IS AN EDIT OF THE FILM.** Two timelines that differ
    /// only in what is drawn at a cut are two films. The reach of each transition
    /// is measured on the pieces AS CUT, before merging: splitting a piece that
    /// carries one can shorten it (half of the new, shorter neighbour), and that
    /// is a different film too. A cut with a transition is never merged away.
    static func playsTheSame(
        _ one: MediaTimeline, _ other: MediaTimeline, withinSource duration: Double
    ) -> Bool {
        let a = film(of: one, withinSource: duration)
        let b = film(of: other, withinSource: duration)
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { x, y in
            abs(x.start - y.start) < 0.0005 && abs(x.end - y.end) < 0.0005
                && abs(x.speed - y.speed) < 0.0005
                && x.kind == y.kind && abs(x.half - y.half) < 0.0005
                && x.filter == y.filter
        }
    }

    /// One stretch of film as it will be seen: where it comes from, how fast it
    /// plays, and what is drawn at the cut after it.
    private struct Stretch {
        var start: Double
        var end: Double
        var speed: Double
        var kind: VideoTransitionKind?
        var half: Double
        /// ⚠️ **A PIECE'S LOOK IS PART OF THE FILM** — two timelines that
        /// differ only in it play different pictures, and two touching pieces
        /// wearing different looks are never merged into one.
        var filter: MediaFilter?
    }

    private static func film(of timeline: MediaTimeline, withinSource duration: Double) -> [Stretch] {
        let pieces = resolved(timeline, withinSource: duration)
        let cuts = seams(timeline, withinSource: duration)
        var out: [Stretch] = []
        for (index, piece) in pieces.enumerated() {
            let cut = cuts.indices.contains(index) ? cuts[index] : nil
            // A transition with no room draws nothing: it is a plain cut.
            let half = cut?.half ?? 0
            let next = Stretch(
                start: piece.start, end: piece.end, speed: speed(of: piece),
                kind: half > 0 ? cut?.kind : nil, half: half, filter: piece.filter
            )
            if let last = out.last, last.kind == nil, last.filter == next.filter,
               abs(last.end - next.start) < 0.0005, abs(last.speed - next.speed) < 0.0005 {
                out[out.count - 1].end = next.end
                out[out.count - 1].kind = next.kind
                out[out.count - 1].half = next.half
            } else {
                out.append(next)
            }
        }
        return out
    }
}
