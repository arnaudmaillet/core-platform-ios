import CoreNavigation
import DesignSystem
import Testing
import UIKit
@testable import Chat

/// **The section the inbox names in its bar (#1301).** While a list is
/// scrolled past a section's header, the bar says that section after the bell
/// — `[bell][New 8] … [coins][search]` — and the header no longer floats
/// under the bar. It follows the scroll and the page in front.
@MainActor
struct InboxPinnedSectionTests {
    // MARK: - The list's half: which section is stuck

    /// Two sections of 20 rows under 55pt headers — the shape of a sectioned
    /// inbox list.
    private final class TwoSections: NSObject, UITableViewDataSource, UITableViewDelegate {
        func numberOfSections(in tableView: UITableView) -> Int { 2 }
        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 20 }
        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            UITableViewCell()
        }
        func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 55 }
        func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? { UIView() }
    }

    private func table() -> (UITableView, TwoSections) {
        let source = TwoSections()
        let table = UITableView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), style: .plain)
        table.rowHeight = 72
        table.dataSource = source
        table.delegate = source
        table.reloadData()
        table.layoutIfNeeded()
        return (table, source)
    }

    private func read(
        _ tracker: InboxPinnedSectionTracker, _ table: UITableView, headed: Bool = true
    ) {
        tracker.update(
            in: table,
            headedSection: { headed ? [InboxListSection.new, .earlier][$0] : nil },
            count: { $0 == .new ? 8 : 0 }
        )
    }

    /// Nothing at the top; "New" once the list moves past its header;
    /// "Recent" once Recent's header reaches the line; nothing back at the top.
    @Test func theStuckSectionFollowsTheScroll() {
        let (table, source) = table()
        _ = source
        let tracker = InboxPinnedSectionTracker()
        var published: [InboxPinnedSection?] = []
        tracker.onChange = { published.append($0) }

        read(tracker, table)
        #expect(tracker.pinned == nil, "a list at its top named a section")

        table.contentOffset.y = 100
        read(tracker, table)
        #expect(tracker.pinned == InboxPinnedSection(section: .new, count: 8))
        #expect(tracker.index == 0)

        table.contentOffset.y = table.rect(forSection: 1).minY
        read(tracker, table)
        #expect(tracker.pinned == InboxPinnedSection(section: .earlier, count: 0))
        #expect(tracker.index == 1)

        table.contentOffset.y = 0
        read(tracker, table)
        #expect(tracker.pinned == nil)
        #expect(published.count == 3, "published on a scroll that changed nothing: \(published)")
    }

    /// A list with no arrivals is one unlabelled block (`headedSection` nil):
    /// it names nothing however far it scrolls.
    @Test func anUnheadedListNamesNothing() {
        let (table, source) = table()
        _ = source
        let tracker = InboxPinnedSectionTracker()
        table.contentOffset.y = 900
        read(tracker, table, headed: false)
        #expect(tracker.pinned == nil)
    }

    /// ⚠️ A section's first row lands ON the pin line, not under an empty
    /// band: its header is hidden once pinned, so `scrollToRow(at:.top)` left
    /// a header-tall blank strip under the bar (#179).
    @Test func scrollingToASectionPutsItsFirstRowOnThePinLine() {
        let (table, source) = table()
        _ = source
        table.scrollFirstRow(ofSection: 1, animated: false)
        let pinLine = table.contentOffset.y + table.adjustedContentInset.top
        #expect(pinLine == table.rectForRow(at: IndexPath(row: 0, section: 1)).minY)

        let tracker = InboxPinnedSectionTracker()
        read(tracker, table)
        #expect(tracker.pinned?.section == .earlier, "the bar did not name the section scrolled to")
    }

    // MARK: - The container's half: the bar item

    /// A page that says which section it has scrolled into.
    private final class SectionedSurface: UIViewController, InboxSurface {
        let category: MessagesCategory
        let chrome = InboxSurfaceChrome()
        var onChromeChange: ((InboxSurfaceChrome) -> Void)?
        private(set) var pinnedSection: InboxPinnedSection?
        var onPinnedSectionChange: ((InboxPinnedSection?) -> Void)?
        private(set) var scrolls = 0

        init(_ category: MessagesCategory) {
            self.category = category
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func surfaceDidBecomeActive() {}
        func scrollToPinnedSection() { scrolls += 1 }

        func pin(_ section: InboxListSection?, count: Int = 0) {
            pinnedSection = section.map { InboxPinnedSection(section: $0, count: count) }
            onPinnedSectionChange?(pinnedSection)
        }
    }

    private func makeBell() -> UIBarButtonItem {
        let item = UIBarButtonItem(customView: UIView())
        item.accessibilityLabel = "Bell"
        return item
    }

    /// `[bell][New · 8]`: the item comes after the bell — the conversation's
    /// day item, a system-titled bubble — is a NEW item under a new identifier
    /// when the list scrolls on (UIKit's morph, not a title swapped in place),
    /// goes at the top, and its tap is the header's.
    @Test func theBarNamesTheSectionAfterTheBell() throws {
        let surface = SectionedSurface(.all)
        let screen = MessagesInboxViewController(surfaces: [surface])
        let bell = makeBell()
        screen.setLeadingAccessoryItem(bell)
        screen.loadViewIfNeeded()
        #expect(screen.navigationItem.leftBarButtonItems?.count == 1)
        #expect(screen.debugSectionItem == nil)

        surface.pin(.new, count: 8)
        let leading = try #require(screen.navigationItem.leftBarButtonItems)
        #expect(leading.count == 2 && leading.first === bell, "the section did not follow the bell")
        let new = try #require(screen.debugSectionItem)
        #expect(new.title == "New · 8")
        #expect(new.customView == nil, "not the bar's own titled bubble")

        surface.pin(.earlier)
        let recent = try #require(screen.debugSectionItem)
        #expect(recent.title == "Recent", "a zero count was drawn")
        #expect(recent !== new && recent.identifier != new.identifier, "a title edited in place gets no morph")
        #expect(screen.navigationItem.leftBarButtonItems?.count == 2)

        screen.debugTapSectionItem()
        #expect(surface.scrolls == 1, "the item's tap did not scroll to its section")

        surface.pin(nil)
        #expect(screen.navigationItem.leftBarButtonItems?.count == 1)
        #expect(screen.debugSectionItem == nil)
    }

    /// The item follows the page in front: a page behind it is not named, and
    /// paging to it names its section, or none.
    @Test func theBarFollowsThePageInFront() throws {
        let chats = SectionedSurface(.all)
        let requests = SectionedSurface(.requests)
        let screen = MessagesInboxViewController(surfaces: [chats, requests])
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        screen.view.layoutIfNeeded()

        chats.pin(.new, count: 2)
        requests.pin(.earlier)
        #expect(screen.debugSectionItem?.title == "New · 2", "a page behind named its section")

        screen.setCategory(.requests, animated: false)
        #expect(screen.debugSectionItem?.title == "Recent")

        requests.pin(nil)
        screen.setCategory(.all, animated: false)
        #expect(screen.debugSectionItem?.title == "New · 2")
        screen.setCategory(.requests, animated: false)
        #expect(screen.debugSectionItem == nil)
    }
}
