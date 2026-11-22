import UIKit

/// Chrome built ahead, at rest, for the next page a flight opens: the
/// new cell's chrome and the flight's replica each take one rather than
/// building theirs in the tap's turn (~4 ms apiece on the simulator,
/// `-O`). A spare is exactly what `init` leaves — never configured,
/// never in a window — so taking one is the same as building one.
@MainActor
enum SnapChromeSpares {
    private static var spares: [SnapChromeView] = []
    static let spareCapacity = 2
    private static var restockArmed = false
    /// The text size the spares were built at: their caption floor is
    /// font-derived (`captionFloorHeight`), resolved in `init` from the app's
    /// size, not from a window they were never in.
    private static var sparesCategory: UIContentSizeCategory?

    /// A fresh chrome: a spare when one is ready, else built now. Spares
    /// built at another text size are dropped, not handed out.
    static func make() -> SnapChromeView {
        defer { armRestock() }
        if sparesCategory != UIApplication.shared.preferredContentSizeCategory { spares.removeAll() }
        return spares.popLast() ?? SnapChromeView()
    }

    private static func addSpare() {
        let category = UIApplication.shared.preferredContentSizeCategory
        if sparesCategory != category { spares.removeAll() }
        sparesCategory = category
        spares.append(SnapChromeView())
    }

    /// Builds the spares back one at a time, a second after the last take —
    /// past the flight it was taken for — and in the DEFAULT run-loop mode
    /// only, so a scroll's tracking holds it off.
    private static func armRestock() {
        guard !restockArmed, spares.count < spareCapacity else { return }
        restockArmed = true
        let timer = Timer(timeInterval: 1, repeats: false) { _ in
            MainActor.assumeIsolated {
                restockArmed = false
                guard spares.count < spareCapacity else { return }
                addSpare()
                armRestock()
            }
        }
        RunLoop.main.add(timer, forMode: .default)
    }

    #if DEBUG
    static var debugSpareCount: Int { spares.count }
    /// Builds every spare now — tests cannot wait out the restock.
    static func debugRestock() {
        while spares.count < spareCapacity { addSpare() }
    }
    #endif
}
