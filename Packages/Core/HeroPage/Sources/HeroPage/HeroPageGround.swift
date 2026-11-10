import DesignSystem
import UIKit

/// What a hero page — a profile, a place — lies on, and what its banner's
/// foot melts into (#2243): the grouped grey under cards, the plain white
/// under flat rows. Both pages are vertical post lists, so they follow the
/// launch's list style (`PostListStyle.current`); the banner's veil, its ramp
/// and the identity's contrast audit read the same tone, so the picture still
/// melts into the page it sits on.
public enum HeroPageGround {
    public static var color: UIColor { PostListStyle.current.pageGround }
}
