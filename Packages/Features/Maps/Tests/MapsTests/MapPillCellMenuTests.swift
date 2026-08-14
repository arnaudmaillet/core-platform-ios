import Testing
import UIKit
@testable import Maps

/// What the cell INSTALLS on its pill, as opposed to what the bar builds.
///
/// The two drifted apart once: the cell kept only the provided menu's
/// `.children`, so a menu whose title carried the person's name presented
/// without any header at all — invisible to every assertion that read the
/// built menu, and only visible in a screenshot of an open menu. These pin
/// the seam itself.
@MainActor
struct MapPillCellMenuTests {
    private static func cell(providing menu: UIMenu?) -> MapPillCell {
        let cell = MapPillCell(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
        cell.configure(
            content: MapPillButton.Content(
                title: nil,
                symbolName: "person.crop.circle", selectedSymbolName: "person.crop.circle.fill",
                accessibilityLabel: "Kenji Tanaka",
                expandsWhenSelected: false
            ),
            height: 48,
            selected: false
        )
        cell.menuProvider = { menu }
        return cell
    }

    @Test("The pill presents the provided menu's title as its header")
    func theTitleReachesThePill() {
        let cell = Self.cell(providing: UIMenu(
            title: "Kenji Tanaka",
            children: [UIMenu(options: .displayInline, children: [UIAction(title: "Remove") { _ in }])]
        ))
        #expect(cell.debugInstalledMenuTitle == "Kenji Tanaka")
    }

    @Test("A pill with no provider carries no menu")
    func noProviderNoMenu() {
        let cell = Self.cell(providing: nil)
        cell.menuProvider = nil
        #expect(cell.debugInstalledMenuTitle == nil)
    }

    /// The provider resolving nil is a moment, not a verdict: the pill keeps
    /// a menu (its children are deferred to presentation time, when the bar
    /// will know the option) and only goes without a header.
    @Test("A provider that resolves nil still leaves the ladder installed")
    func nilResultKeepsTheMenu() {
        let cell = Self.cell(providing: nil)
        #expect(cell.debugInstalledMenuTitle == "")
    }
}
