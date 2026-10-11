import MapKit

/// The camera bookkeeping of a locked country's unlock offer, from the moment
/// it opens until its sheet is gone: where the map was before the offer flew
/// it away, whether closing flies it back there, and whether a close that came
/// back up has to frame the country again.
///
/// A value, kept apart from `MapsViewController`, which still flies the camera,
/// frames the country and presents the sheet. It only answers what to do, so
/// the rules (#760: a switch keeps home; a pan closes where the user took the
/// map) are pinned without a map (`MapCountryOfferStateTests`).
struct MapCountryOfferState {
    /// Where the map was before the offer flew it to its country.
    private(set) var camera: MKMapCamera?
    /// Whether closing the offer flies the map back to `camera`.
    private(set) var returns = true
    /// The open offer's close has already flown the map back — a cancelled
    /// close then frames the country again.
    private(set) var flewBack = false

    /// An offer opens. Only the FIRST camera is kept until the offer is gone:
    /// whatever else the offer does meanwhile — taking another locked country
    /// in place (#760) never comes through here — closing still flies back
    /// home. `current` is read only when there is no camera yet.
    mutating func opening(from current: () -> MKMapCamera?) {
        if camera == nil { camera = current() }
    }

    /// A close was asked for. `returning`: whether the map flies back — false
    /// when the user moved the map away from the offer themselves.
    mutating func closeRequested(returning: Bool) {
        returns = returning
    }

    /// The sheet has started down: the camera to fly back to, or nil when the
    /// map stays where it is.
    mutating func closing() -> MKMapCamera? {
        guard returns, let camera else { return nil }
        flewBack = true
        return camera
    }

    /// The sheet came back up: whether the country has to be framed again
    /// (the map had already flown back). The next close returns again.
    mutating func closeCancelled() -> Bool {
        let reframes = flewBack
        flewBack = false
        returns = true
        return reframes
    }

    /// The sheet is gone: nothing is remembered.
    mutating func closed() {
        camera = nil
        returns = true
        flewBack = false
    }
}
