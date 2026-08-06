import UIKit

/// The one row height every people list in the app is laid out to, and the
/// arithmetic for getting a cell there.
///
/// **Why a shared calculation rather than a shared constant.** Six cells now
/// sit at this height and no two of them reach it the same way: a hand-built
/// text column, a `UIListContentConfiguration`, a row with a 48pt disc and two
/// action buttons, a row with three lines of type. Copying one cell's margin
/// into another was tried and produced a row 2.4pt short, because matching the
/// INPUT does not match the OUTPUT when the content in between differs. Every
/// caller instead says how tall its content is and is told what to pad it by.
public enum PersonRowMetrics {
    /// The shared pitch. Defined by `PersonListCell` — that row is the one
    /// every other is being matched TO, so it owns the number.
    public static var rowHeight: CGFloat { PersonListCell.comfortableRowHeight }

    /// What to inset above and below `contentHeight` to land on `rowHeight`.
    ///
    /// `contentHeight` is the tallest thing the row actually contains — a 48pt
    /// identity disc, or a stack of type if that is taller. A row whose
    /// content already exceeds the target keeps `minimum` and is simply
    /// taller: this compacts rows, it never crops them.
    public static func verticalInset(
        forContentHeight contentHeight: CGFloat,
        minimum: CGFloat = Spacing.xs
    ) -> CGFloat {
        max(minimum, (rowHeight - contentHeight) / 2)
    }

    /// The height of `count` stacked lines in these text styles, for callers
    /// whose content is type rather than a disc.
    public static func textHeight(_ styles: [UIFont.TextStyle]) -> CGFloat {
        styles.reduce(0) { $0 + UIFont.preferredFont(forTextStyle: $1).lineHeight }
    }
}
