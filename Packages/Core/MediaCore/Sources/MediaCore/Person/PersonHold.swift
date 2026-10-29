import DesignSystem

/// A LONG PRESS ON A PERSON OPENS THEM (#1885): any container of a person's
/// info — the post screen's author pill, the Shots author row — that opens
/// their profile on a hold plays `held`, once, as the hold is recognised.
/// Hosts call this at `.began`, so the next person container gets the same
/// feel for free.
@MainActor
public enum PersonHold {
    /// The hold recognised: `held`, then `open`.
    public static func recognised(_ open: () -> Void) {
        Haptics.play(.held)
        open()
    }
}
