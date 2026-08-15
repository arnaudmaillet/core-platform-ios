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
    private static func cell(providing menu: MapPillMenu?) -> MapPillCell {
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

    private static func header(_ title: String, _ subtitle: String?) -> UIMenu {
        UIMenu(options: .displayInline, children: [
            UIAction(title: title, subtitle: subtitle) { _ in }
        ])
    }

    @Test("The pill presents the provided header")
    func theTitleReachesThePill() {
        let cell = Self.cell(providing: MapPillMenu(
            title: "",
            header: Self.header("Kenji Tanaka", "@kenji.dev"),
            liveSection: { [UIAction(title: "Remove") { _ in }] }
        ))
        #expect(cell.debugInstalledMenuTitle == "Kenji Tanaka")
    }

    /// ⚠️ The point of the split: the handle is on the pill BEFORE the menu
    /// is ever opened. Deferred, it could only appear one frame into the
    /// presentation, which is what made it look like it was still loading.
    @Test("The handle is installed with the header, not resolved on open")
    func theHandleIsInstalledUpFront() {
        var liveSectionCalls = 0
        let cell = Self.cell(providing: MapPillMenu(
            title: "",
            header: Self.header("Kenji Tanaka", "@kenji.dev"),
            liveSection: {
                liveSectionCalls += 1
                return [UIAction(title: "Remove") { _ in }]
            }
        ))

        #expect(cell.debugInstalledMenuSubtitle == "@kenji.dev")
        // And it cost nothing from the live half — that is still unresolved,
        // waiting for a thumb.
        #expect(liveSectionCalls == 0)
    }

    /// A place keeps the plain caption, and it is installed just as eagerly.
    @Test("A captioned menu installs its caption")
    func aCaptionedMenuInstallsItsCaption() {
        let cell = Self.cell(providing: MapPillMenu(
            title: "Cafés",
            header: nil,
            liveSection: { [UIAction(title: "Remove") { _ in }] }
        ))

        #expect(cell.debugInstalledMenuTitle == "Cafés")
        #expect(cell.debugInstalledMenuSubtitle == nil)
    }

    @Test("A pill with no provider carries no menu")
    func noProviderNoMenu() {
        let cell = Self.cell(providing: nil)
        cell.menuProvider = nil
        #expect(cell.debugInstalledMenuTitle == nil)
    }

    /// The provider resolving nil is a moment, not a verdict: the pill keeps
    /// a menu (its verbs are deferred to presentation time, when the bar will
    /// know the option) and only goes without a header.
    @Test("A provider that resolves nil still leaves the ladder installed")
    func nilResultKeepsTheMenu() {
        let cell = Self.cell(providing: nil)
        #expect(cell.debugInstalledMenuTitle == "")
        #expect(cell.debugInstalledMenuSubtitle == nil)
    }
}
