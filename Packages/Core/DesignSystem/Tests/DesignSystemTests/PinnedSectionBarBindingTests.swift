import Testing
import UIKit
@testable import DesignSystem

/// The contract binding a screen's sections to a bar item that follows the
/// scroll (#1573): which section is pinned, the item it mints, where it goes
/// (leading or trailing, the screen's other items kept), a tap, the deferral
/// past a turn, and a bar toast taking the trailing group and giving it back.
@MainActor
@Suite(.serialized)
struct PinnedSectionBarBindingTests {
    private let sections = [
        PinnedSectionBarBinding.Section(id: "new", title: "New", count: 3),
        PinnedSectionBarBinding.Section(id: "yesterday", title: "Yesterday"),
        PinnedSectionBarBinding.Section(id: "week", title: "Last week"),
    ]
    private let tops: [CGFloat] = [0, 500, 1_200]

    private func hosting(_ body: (UIViewController) throws -> Void) rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let screen = UIViewController()
        let navigation = UINavigationController(rootViewController: screen)
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        let (clock, _) = ToastClock.manual()
        let previousClock = ToastClock.current
        ToastClock.current = clock
        defer {
            ToastClock.current = previousClock
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        // The toasts' haptics are recorded, never played.
        _ = try HapticRecorder.recording { try body(screen) }
    }

    /// The pinned section follows the headers against the pin line, and
    /// nothing while the list rests at its top.
    @Test func thePinnedSectionFollowsTheHeaders() {
        let binding = PinnedSectionBarBinding(viewController: UIViewController(), placement: .leading, scope: "test")
        binding.update(sections: sections, sectionTops: tops, pinLine: 0)
        #expect(binding.pinned == nil, "the list at rest names a section")
        #expect(binding.item == nil)
        binding.update(sections: sections, sectionTops: tops, pinLine: 300)
        #expect(binding.pinned?.section.id == "new")
        #expect(binding.item?.title == "New · 3")
        binding.update(sections: sections, sectionTops: tops, pinLine: 700)
        #expect(binding.pinned?.section.id == "yesterday")
        #expect(binding.item?.title == "Yesterday")
        binding.update(sections: sections, sectionTops: tops, pinLine: 1_300)
        #expect(binding.pinned?.index == 2)
    }

    /// The same section scrolled further mints no new item: the bar is
    /// rewritten only when the section (or its count) changes.
    @Test func theItemChangesOnlyWithTheSection() throws {
        let binding = PinnedSectionBarBinding(viewController: UIViewController(), placement: .leading, scope: "test")
        binding.update(sections: sections, sectionTops: tops, pinLine: 300)
        let first = try #require(binding.item)
        binding.update(sections: sections, sectionTops: tops, pinLine: 350)
        #expect(binding.item === first, "a scroll inside the section re-minted the item")
        var counted = sections
        counted[0] = .init(id: "new", title: "New", count: 4)
        binding.update(sections: counted, sectionTops: tops, pinLine: 350)
        #expect(binding.item !== first && binding.item?.title == "New · 4")
        #expect(binding.item?.identifier != first.identifier, "a new count must morph, not edit in place")
    }

    /// A tap asks the screen to scroll to the section's header — its index now.
    @Test func aTapScrollsToTheSection() throws {
        let binding = PinnedSectionBarBinding(viewController: UIViewController(), placement: .leading, scope: "test")
        var selected: [Int] = []
        binding.onSelect = { selected.append($0) }
        binding.update(sections: sections, sectionTops: tops, pinLine: 700)
        let item = try #require(binding.item)
        let action = try #require(item.primaryAction)
        action.performWithSender(nil, target: nil)
        #expect(selected == [1])
    }

    /// Leading: after the back chevron, then the screen's own leading items.
    @Test func leadingKeepsTheScreensItemsAfterIt() throws {
        let screen = UIViewController()
        let binding = PinnedSectionBarBinding(viewController: screen, placement: .leading, scope: "test")
        #expect(screen.navigationItem.leftItemsSupplementBackButton, "the chevron is not kept")
        let own = UIBarButtonItem(systemItem: .edit)
        binding.leadingItems = [own]
        binding.update(sections: sections, sectionTops: tops, pinLine: 300)
        binding.debugPlaceNow()
        let items = try #require(screen.navigationItem.leftBarButtonItems)
        #expect(items.count == 2 && items[0] === binding.item && items[1] === own)
        binding.update(sections: sections, sectionTops: tops, pinLine: 0)
        binding.debugPlaceNow()
        #expect(screen.navigationItem.leftBarButtonItems?.elementsEqual([own], by: ===) == true,
                "back at the top, the screen's item went too")
    }

    /// A list that works out its own pinned section hands it over: the same
    /// item rules as `update` — one per section and count, nothing at the top.
    @Test func aListsOwnPinnedSectionIsShown() throws {
        let binding = PinnedSectionBarBinding(viewController: UIViewController(), placement: .leading, scope: "test")
        binding.show(pinned: (1, sections[1]))
        let first = try #require(binding.item)
        #expect(first.title == "Yesterday")
        binding.show(pinned: (1, sections[1]))
        #expect(binding.item === first, "the same section re-minted the item")
        binding.show(pinned: (0, sections[0]))
        #expect(binding.item?.title == "New · 3")
        binding.show(pinned: nil)
        #expect(binding.item == nil && binding.pinned == nil)
    }

    /// Leading with items that come first (the inbox's bell): prefix, then
    /// the section, then the screen's other items.
    @Test func aLeadingPrefixStaysFirst() throws {
        let screen = UIViewController()
        let binding = PinnedSectionBarBinding(viewController: screen, placement: .leading, scope: "test")
        let bell = UIBarButtonItem(systemItem: .bookmarks)
        let own = UIBarButtonItem(systemItem: .edit)
        binding.leadingPrefix = [bell]
        binding.leadingItems = [own]
        binding.update(sections: sections, sectionTops: tops, pinLine: 300)
        binding.debugPlaceNow()
        let items = try #require(screen.navigationItem.leftBarButtonItems)
        #expect(items.count == 3 && items[0] === bell && items[1] === binding.item && items[2] === own)
    }

    /// Suspended (a bar of another kind — the inbox's search) the binding
    /// writes nothing but keeps up; resumed, it places what is pinned now.
    @Test func aSuspendedBindingWritesNothingAndCatchesUpOnResume() throws {
        let screen = UIViewController()
        let binding = PinnedSectionBarBinding(viewController: screen, placement: .leading, scope: "test")
        let bell = UIBarButtonItem(systemItem: .bookmarks)
        binding.leadingPrefix = [bell]
        binding.isSuspended = true
        screen.navigationItem.leftBarButtonItems = []
        binding.update(sections: sections, sectionTops: tops, pinLine: 700)
        binding.placeNow()
        #expect((screen.navigationItem.leftBarButtonItems ?? []).isEmpty, "a suspended binding wrote the bar")
        binding.isSuspended = false
        let items = try #require(screen.navigationItem.leftBarButtonItems)
        #expect(items.count == 2 && items[0] === bell && items[1].title == "Yesterday")
    }

    /// The tracker: the pinned value against the pin line, its index, told
    /// only on a change, and nothing over a section the host does not name.
    @Test func theTrackerTellsOnlyAChange() {
        let tracker = PinnedSectionTracker<String>()
        var told: [String?] = []
        tracker.onChange = { told.append($0) }
        let names: (Int) -> String? = { ["new", nil, "week"][$0] }
        tracker.update(sectionTops: tops, pinLine: 0, value: names)
        #expect(tracker.pinned == nil && told.isEmpty)
        tracker.update(sectionTops: tops, pinLine: 300, value: names)
        tracker.update(sectionTops: tops, pinLine: 350, value: names)
        #expect(tracker.pinned == "new" && tracker.index == 0)
        tracker.update(sectionTops: tops, pinLine: 700, value: names)
        #expect(tracker.pinned == nil, "an unnamed section was named")
        tracker.update(sectionTops: tops, pinLine: 1_300, value: names)
        #expect(tracker.pinned == "week" && tracker.index == 2)
        #expect(told == ["new", nil, "week"])
    }

    /// Trailing: before the screen's own trailing items.
    @Test func trailingGoesBeforeTheScreensItems() throws {
        hosting { screen in
            let binding = PinnedSectionBarBinding(viewController: screen, placement: .trailing, scope: "test")
            let trash = UIBarButtonItem(systemItem: .trash)
            binding.trailingItems = [trash]
            binding.update(sections: sections, sectionTops: tops, pinLine: 300)
            binding.debugPlaceNow()
            let items = screen.navigationItem.rightBarButtonItems ?? []
            // The bar lists trailing items right to left: the screen's first.
            #expect(items.count == 2 && items[0] === trash && items[1] === binding.item)
        }
    }

    /// A separator keeps the section item in its own glass beside the
    /// screen's items — and only when there are any (the profile's day).
    @Test func aSeparatorStandsBetweenTheScreensItemsAndTheSection() {
        hosting { screen in
            let space = UIBarButtonItem.fixedSpace(8)
            let binding = PinnedSectionBarBinding(
                viewController: screen, placement: .trailing, scope: "test", separator: space
            )
            binding.update(sections: sections, sectionTops: tops, pinLine: 300)
            binding.debugPlaceNow()
            let alone = screen.navigationItem.rightBarButtonItems ?? []
            #expect(alone.count == 1 && alone[0] === binding.item, "a separator with nothing to separate")

            let trash = UIBarButtonItem(systemItem: .trash)
            binding.trailingItems = [trash]
            binding.debugPlaceNow()
            let items = screen.navigationItem.rightBarButtonItems ?? []
            #expect(items.count == 3 && items[0] === trash && items[1] === space && items[2] === binding.item)
            #expect(binding.placedTrailing([trash]).elementsEqual(items, by: ===))
        }
    }

    /// An identical trailing group is not handed back: re-setting the same
    /// items rebuilt the glass mid-transition (the profile's guard, #1573).
    @Test func anIdenticalTrailingGroupIsNotHandedBack() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let screen = CountingScreen()
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.isHidden = false
        window.layoutIfNeeded()
        defer {
            window.rootViewController = nil
            window.isHidden = true
        }
        let binding = PinnedSectionBarBinding(viewController: screen, placement: .trailing, scope: "test")
        binding.trailingItems = [UIBarButtonItem(systemItem: .trash)]
        binding.update(sections: sections, sectionTops: tops, pinLine: 300)
        binding.placeNow(animated: true)
        let writes = screen.counted.trailingWrites
        #expect(writes >= 1)

        binding.placeNow(animated: true)
        let same = binding.trailingItems
        binding.trailingItems = same
        binding.placeNow()
        #expect(screen.counted.trailingWrites == writes, "the same group was handed back")
    }

    /// On screen, the placement waits a turn — a scroll can publish twice in
    /// one — and lands once.
    @Test func onScreenThePlacementWaitsATurn() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let screen = UIViewController()
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.isHidden = false
        window.layoutIfNeeded()
        defer {
            window.rootViewController = nil
            window.isHidden = true
        }
        let binding = PinnedSectionBarBinding(viewController: screen, placement: .leading, scope: "test")
        binding.update(sections: sections, sectionTops: tops, pinLine: 300)
        binding.update(sections: sections, sectionTops: tops, pinLine: 700)
        #expect((screen.navigationItem.leftBarButtonItems ?? []).isEmpty, "placed inside the scroll's turn")
        for _ in 0..<100 where (screen.navigationItem.leftBarButtonItems ?? []).isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(screen.navigationItem.leftBarButtonItems?.first?.title == "Yesterday")
    }

    /// A bar toast holding the trailing group gives the screen's items back
    /// with the section item in place.
    @Test func aToastGivesTheTrailingGroupBackWithTheSection() throws {
        try hosting { screen in
            let binding = PinnedSectionBarBinding(viewController: screen, placement: .trailing, scope: "test")
            let trash = UIBarButtonItem(systemItem: .trash)
            binding.trailingItems = [trash]
            binding.debugPlaceNow()
            let toast = Feedback.info("Cleared", from: screen)
            binding.update(sections: sections, sectionTops: tops, pinLine: 300)
            binding.debugPlaceNow()
            let during = screen.navigationItem.rightBarButtonItems ?? []
            #expect(during.allSatisfy(NavigationBarToasts.isToastItem), "the section item pushed into the toast's bar")
            toast.dismiss(animated: false)
            let back = try #require(screen.navigationItem.rightBarButtonItems)
            #expect(back.count == 2 && back[0] === trash && back[1] === binding.item)
        }
    }
}

/// A screen whose navigation item counts the trailing writes.
private final class CountingScreen: UIViewController {
    final class CountingItem: UINavigationItem {
        private(set) var trailingWrites = 0
        override func setRightBarButtonItems(_ items: [UIBarButtonItem]?, animated: Bool) {
            trailingWrites += 1
            super.setRightBarButtonItems(items, animated: animated)
        }
        override var rightBarButtonItems: [UIBarButtonItem]? {
            get { super.rightBarButtonItems }
            set {
                trailingWrites += 1
                super.rightBarButtonItems = newValue
            }
        }
    }

    let counted = CountingItem(title: "")
    override var navigationItem: UINavigationItem { counted }
}
