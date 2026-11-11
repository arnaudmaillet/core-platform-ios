import DesignSystem
import UIKit

/// What a hero page — a profile, a place — lies on, and what its banner's
/// foot melts into: the plain page (`Surface.plainPage`, white in the light,
/// black in the dark), since both pages are vertical post lists (#2243, the
/// only style since #2290). The banner's veil, its ramp and the identity's
/// contrast audit read the same tone, so the picture melts into the page it
/// sits on.
public enum HeroPageGround {
    public static var color: UIColor { Surface.plainPage }
}
