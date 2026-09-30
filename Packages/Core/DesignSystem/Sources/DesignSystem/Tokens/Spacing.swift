import CoreGraphics

/// Spacing scale. All layout code uses these tokens instead of magic numbers
/// so density changes are a one-line edit.
public enum Spacing {
    /// 4pt
    public static let xs: CGFloat = 4
    /// 8pt
    public static let sm: CGFloat = 8
    /// 12pt
    public static let md: CGFloat = 12
    /// 16pt
    public static let lg: CGFloat = 16
    /// 24pt
    public static let xl: CGFloat = 24
    /// 32pt
    public static let xxl: CGFloat = 32

    // MARK: - Sections

    /// BETWEEN TWO SECTIONS: from the foot of one section's content to the
    /// top of the next section's TITLE LINE (the title's line box, not the
    /// bar or header that hosts it) — 28pt.
    ///
    /// ONE number for every sectioned surface (asked for, 2026-09-30: "the
    /// interface must breathe, and the SAME spacing everywhere"): the sound
    /// sheet (sound → Popular → Recent), For You (Friends → Following →
    /// "For you"), the pushed Following and Friends lists (New → Recent). Each
    /// surface hosts its titles its own way — a 44pt bar, a pinned capsule's
    /// header — so each turns this into the gap ITS geometry needs
    /// (`sectionGap(aboveTitleBar:lineHeight:)`), and on screen every title
    /// line stands the same distance under what is above it.
    ///
    /// Why 28, from Apple's own screens on iOS 26: the App Store's and Music's
    /// shelves keep roughly 28–32pt between a shelf's foot and the next
    /// shelf's title, an inset-grouped list about 35pt between a group and the
    /// next header's text; and the gap BEFORE a title should be about three
    /// times the gap AFTER it (`sectionTitle`), so the title reads as the head
    /// of what follows rather than the tail of what precedes it (proximity).
    /// 28 against 10 is that ratio, on the 4pt grid.
    public static let section: CGFloat = 28

    /// A section's TITLE LINE to its content: 10pt — the air a 44pt bar (the
    /// tap target a title that is also a way in needs) leaves under a title3
    /// line at the default text size, so a bar that centres its title already
    /// keeps it. Apple's shelf titles sit 8–12pt over their content.
    public static let sectionTitle: CGFloat = 10

    /// The space to leave ABOVE a title bar `barHeight` tall that centres one
    /// line `lineHeight` tall, for that line to stand `section` under the
    /// content above — whole points. The bar's own air counts toward it.
    public static func sectionGap(aboveTitleBar barHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        max(0, (section - max(0, barHeight - lineHeight) / 2).rounded())
    }

    /// A title bar that centres one line `lineHeight` tall with `sectionTitle`
    /// above and below it — never under the 44pt a control needs; whole
    /// points.
    public static func sectionTitleBarHeight(lineHeight: CGFloat) -> CGFloat {
        max(44, (lineHeight + 2 * sectionTitle).rounded(.up))
    }
}
