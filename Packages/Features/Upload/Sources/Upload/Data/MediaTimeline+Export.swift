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
        return resolved(timeline, withinSource: duration).map {
            VideoExportSegment(start: $0.start, end: $0.end, speed: $0.speed)
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
    static func playsTheSame(
        _ one: MediaTimeline, _ other: MediaTimeline, withinSource duration: Double
    ) -> Bool {
        let a = merged(resolved(one, withinSource: duration))
        let b = merged(resolved(other, withinSource: duration))
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { x, y in
            abs(x.start - y.start) < 0.0005 && abs(x.end - y.end) < 0.0005
                && abs(speed(of: x) - speed(of: y)) < 0.0005
        }
    }

    private static func merged(_ pieces: [MediaSegment]) -> [MediaSegment] {
        var out: [MediaSegment] = []
        for piece in pieces {
            if let last = out.last, abs(last.end - piece.start) < 0.0005,
               abs(speed(of: last) - speed(of: piece)) < 0.0005 {
                out[out.count - 1] = MediaSegment(start: last.start, end: piece.end, speed: last.speed)
            } else {
                out.append(piece)
            }
        }
        return out
    }
}
