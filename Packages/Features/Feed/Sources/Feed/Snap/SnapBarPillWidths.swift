import CoreGraphics
import UIKit
import DesignSystem

/// The FIXED widths of the snap feed's two bar pills — the author pill in the
/// navigation bar, the audio capsule in the toolbar — read off the bars'
/// geometry and never off what the pills say.
///
/// ⚠️ WHY FIXED (asked 2026-09-30). Both pills used to hug their text, so every
/// page with a longer or shorter name or sound re-negotiated the item's width:
/// the glass visibly grew and shrank between posts, however well the width
/// glided under the blur (#315, #320). Now each pill has ONE width for the
/// screen — the room its bar can spare, capped — and a long name or sound
/// truncates inside it. The width moves only with the bars themselves: a new
/// bar width (rotation), a Dynamic Type size, the wallet badge growing a digit,
/// a control joining the bar (below). Never with a name or a sound.
///
/// THE AUTHOR PILL takes what the bar's OTHER ITEMS leave it: the back arrow,
/// the wallet badge, and the comments sort while a thread that has one holds
/// the bar (a text page past `CommentSortPolicy`'s threshold). So its width
/// changes when the bar gains or loses a control — in the same turn, under the
/// bar's own item animation — and never when a name does. Reserving the sort
/// on every page was weighed and rejected: measured on the iPhone 18 Pro
/// (402pt, a "250" balance), it would cost the pill 66pt on EVERY media page
/// — 193 → 127, the name gone after a few letters — to spare the few text
/// pages whose thread is long enough to sort. (Passing the sort on every page
/// below is the one-line switch, should that trade be wanted.) The sort shows its word only when the word leaves the pill
/// `comfortableAuthor` wide (`sortShowsTitle`) — the bar's geometry again,
/// not the author's handle, which is what used to decide it.
///
/// THE TOOLBAR'S AUTHOR PILL (#671) takes what the footer's stock items
/// leave it — `[pill] —— [☆ ⇄] [⋯]` — and those GROW WITH DYNAMIC TYPE: a
/// bar's symbol scales with the text size (measured on the iPhone SE at
/// XXXL, #1679: a 38pt glyph item draws 49). So the reserve is read for the
/// icon width the screen's text size gives (`toolbarIcon`), and a long name
/// at a large size truncates in the pill instead of sweeping ⇄ into `•••`.
///
/// ⚠️ THE BARS FOLD, THEY DO NOT SQUEEZE. A run that does not fit is swept into
/// UIKit's `•••` whole (memory `navbar-leading-selector-collapse`), so every
/// figure below is a measured platter and the result leaves slack; there is no
/// floor that could out-argue the bar. Pure arithmetic, pinned by
/// `SnapBarPillWidthsTests` at 375 / 393 / 402 / 440.
struct SnapBarPillWidths: Equatable {
    /// The author pill's width.
    var author: CGFloat
    /// The author pill's width in the TOOLBAR's leading slot (#671): what the
    /// footer's stock items leave (`toolbarReserve(icon:)`), capped, so the
    /// run never folds into `•••`.
    var toolbarAuthor: CGFloat
    /// Whether the comments sort shows its word; false without a sort.
    var sortShowsTitle: Bool

    // MARK: - Navigation bar (measured, iOS 26/27)

    /// The bar's margins, each side.
    static let navBarMargin: CGFloat = 16
    /// The glass UIKit wraps around every custom bar item (not published;
    /// measured: a 170pt author fits beside an 88pt sort on a 390pt bar and
    /// 195 does not).
    static let navItemPadding: CGFloat = 18
    /// The fixed space that keeps two adjacent items two pills.
    static let pillSpacing: CGFloat = Spacing.sm
    /// The back arrow's bubble.
    static let backButtonWidth: CGFloat = 36
    /// The widest the author pill gets, however wide the bar: past it a short
    /// name floats in a lot of empty glass.
    ///
    /// 168 since the pill lost the post's age (2026-10-01): its second line is
    /// the handle alone, so the line that used to set the width ("@handle ·
    /// 12 weeks") is gone. 168 leaves the labels ~83pt — a first and last
    /// name — beside the face, the follow slot and their gaps; on the iPhone
    /// 18 Pro it was 193 (the bar's room, under the old 220 cap).
    static let authorCap: CGFloat = 168
    /// What the arithmetic keeps back, so a rounding or an unmeasured point
    /// is never the one that folds the run.
    static let slack: CGFloat = 8

    // MARK: - Toolbar (measured, iOS 27, `-dump-bars`, #1679)

    /// A stock glyph item's width at the default text size: what the
    /// footer's ☆, ⇄ and ⋯ draw (`BarItems.icon`, since #1683).
    static let defaultToolbarIcon: CGFloat = 38

    /// Everything on the footer but the author pill, for glyph items `icon`
    /// wide — read off the bar's own frames on iOS 27 (iPhone SE and 18 Pro,
    /// `-dump-bars`): 28pt margins each side; the glass around the pill
    /// (+10); a 13pt gap to the [☆ ⇄] platter, which is the two glyphs and
    /// 31 of its own (107 at the default size); a 13pt gap; ⋯'s 48 (its glyph
    /// does not grow); and 8 of slack. The fold is silent, and one point
    /// short sweeps ⇄ into a system `•••` that looks exactly like ⋯.
    ///
    /// ⚠️ It was a fixed 280 against an 86pt platter — the custom buttons'
    /// before the stock items (#1683) — and a long name on an SE folded ⇄
    /// away, at any text size and at once at XXXL.
    static func toolbarReserve(icon: CGFloat) -> CGFloat {
        toolbarReserve(icon: icon, platter: true)
    }

    /// The same footer with (`platter`) or without the two-glyph platter —
    /// the conversation's `[📷 🖼]` is the post's `[☆ ⇄]`, and a thread that
    /// sends no media wears only ⋯ (#1679: its own arithmetic left the peer
    /// pill 163pt on an SE, and 🖼 folded into `•••` at XXXL).
    static func toolbarReserve(icon: CGFloat, platter: Bool) -> CGFloat {
        28 + 10 + 13 + (platter ? (2 * icon + 31) + 13 : 0) + 48 + 28 + slack
    }

    /// A stock glyph item's width at `traits`' text size.
    @MainActor
    static func toolbarIcon(for traits: UITraitCollection) -> CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: defaultToolbarIcon, compatibleWith: traits)
    }

    /// The toolbar author's cap: past it a short name floats in glass.
    static let toolbarAuthorCap: CGFloat = 220

    /// The narrowest the author pill is left for the sort's WORD: below it the
    /// sort drops to its glyph and gives the pill the difference — the old
    /// compact pill's width, where a name still reads.
    static let comfortableAuthor: CGFloat = 150

    /// The smallest a pill is ever made: one bubble, the avatar and its
    /// breathing. Not a floor that keeps text readable — only one that keeps
    /// a pathological input (an accessibility-size wallet on a narrow bar)
    /// from asking for a negative width.
    static let minimum: CGFloat = 36

    /// The comments sort's two widths, when it is on the bar.
    struct Sort: Equatable {
        /// Without its word.
        var glyph: CGFloat
        /// With its longest word.
        var titled: CGFloat
    }

    /// - Parameters:
    ///   - navBarWidth: the navigation bar's width.
    ///   - toolbarWidth: the toolbar's (the screen's, on a phone).
    ///   - walletWidth: the wallet badge's fitted width, nil without a wallet.
    ///   - sort: the comments sort's widths while it is on the bar, else nil.
    ///   - toolbarIcon: a stock glyph item's width at the screen's text size.
    static func resolve(
        navBarWidth: CGFloat,
        toolbarWidth: CGFloat,
        walletWidth: CGFloat?,
        sort: Sort?,
        toolbarIcon: CGFloat = defaultToolbarIcon
    ) -> SnapBarPillWidths {
        // Everything on the nav bar but the author pill, the sort (if any)
        // `sortWidth` points wide. The back arrow is always paid for: whether
        // the screen has one is known only at its appearance, and a width
        // that moved then would be a width that moved.
        func room(sortWidth: CGFloat?) -> CGFloat {
            var leading = backButtonWidth + navItemPadding
            if let sortWidth { leading += pillSpacing + sortWidth + navItemPadding }
            let wallet = walletWidth.map { $0 + navItemPadding + pillSpacing } ?? 0
            return navBarWidth - navBarMargin * 2 - leading - wallet - navItemPadding - slack
        }
        func clamp(_ width: CGFloat, cap: CGFloat) -> CGFloat {
            max(minimum, min(cap, width)).rounded(.down)
        }
        let showsTitle = sort.map { room(sortWidth: $0.titled) >= comfortableAuthor } ?? false
        let sortWidth = sort.map { showsTitle ? $0.titled : $0.glyph }
        return SnapBarPillWidths(
            author: clamp(room(sortWidth: sortWidth), cap: authorCap),
            toolbarAuthor: clamp(toolbarWidth - toolbarReserve(icon: toolbarIcon), cap: toolbarAuthorCap),
            sortShowsTitle: showsTitle
        )
    }
}
