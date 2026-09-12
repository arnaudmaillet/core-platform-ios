import Testing
import UIKit
@testable import Upload

/// **THE SELECTION IS AN ORDER, NOT A SET.** Everything the picker shows —
/// the number on a tile, the row of thumbnails, the count on "Next", what the
/// next step is handed — reads off the same ordered list, so the rules that
/// keep it honest are worth pinning without a photo library in the room.
@MainActor
struct MediaPickerSelectionTests {
    @Test func tilesAreNumberedInTheOrderTheyWereChosen() {
        var selection = MediaPickerSelection()
        selection.toggle("b")
        selection.toggle("a")
        selection.toggle("c")

        #expect(selection.order(of: "b") == 1)
        #expect(selection.order(of: "a") == 2)
        #expect(selection.order(of: "c") == 3)
        #expect(selection.order(of: "d") == nil, "never chosen, never numbered")
    }

    /// The whole reason the numbers are computed rather than stored.
    @Test func droppingOneFromTheMiddleClosesTheGap() {
        var selection = MediaPickerSelection()
        for id in ["a", "b", "c"] { selection.toggle(id) }

        selection.remove("b")

        #expect(selection.ids == ["a", "c"])
        #expect(selection.order(of: "c") == 2, "c moves up rather than staying 3")
    }

    /// ⚠️ EVERY MUTATION HERE HAPPENS ON ITS OWN LINE, and that is a rule rather
    /// than a style: `#expect` rewrites the expression it is handed into
    /// closures over immutable copies, so a `mutating` call written inside one
    /// does not compile — and the error arrives from inside the expanded macro,
    /// naming a `$0` that appears nowhere in this file.
    @Test func chosenTwiceIsGivenBack() {
        var selection = MediaPickerSelection()

        let chose = selection.toggle("a")
        let gaveBack = selection.toggle("a")

        #expect(chose == .added(order: 1))
        #expect(gaveBack == .removed)
        #expect(selection.isEmpty)
    }

    @Test func theCapRefusesTheNextOneAndKeepsWhatItHas() {
        var selection = MediaPickerSelection()
        for index in 0..<MediaPickerSelection.limit { selection.toggle("item-\(index)") }

        let refusal = selection.toggle("one-too-many")

        #expect(selection.isFull)
        #expect(refusal == .refused)
        #expect(selection.count == MediaPickerSelection.limit, "a refusal changes nothing")
        #expect(selection.order(of: "one-too-many") == nil)
    }

    @Test func aFinishedDragTakesTheOrderItLeftBehind() {
        var selection = MediaPickerSelection()
        for id in ["a", "b", "c"] { selection.toggle(id) }

        let took = selection.setOrder(["c", "a", "b"])

        #expect(took)
        #expect(selection.ids == ["c", "a", "b"])
        #expect(selection.order(of: "c") == 1)
    }

    /// A report that has lost or gained an item is a bug upstream, and applying
    /// it would drop a photo the viewer can still see in the tray.
    @Test func anOrderThatIsNotAPermutationIsRefused() {
        var selection = MediaPickerSelection()
        for id in ["a", "b", "c"] { selection.toggle(id) }

        let short = selection.setOrder(["a", "b"])
        let foreign = selection.setOrder(["a", "b", "d"])
        let doubled = selection.setOrder(["a", "b", "b"])

        #expect(short == false, "one short")
        #expect(foreign == false, "one it never held")
        #expect(doubled == false, "one of them twice")
        #expect(selection.ids == ["a", "b", "c"], "and the selection is untouched")
    }
}

/// **THE PICKER IS THE LIBRARY PLUS WHAT HAS BEEN CHOSEN FROM IT.** These run
/// against a library of their own: CI has no photo library at all, and a
/// simulator's is six stock images deep.
@MainActor
struct MediaPickerTests {
    /// Stands in for the device library.
    private final class StubLibrary: MediaLibraryReading {
        var access: MediaLibraryAccess
        private(set) var requestCount = 0
        private let grantOnRequest: MediaLibraryAccess
        private let albumList: [MediaLibraryAlbum]
        private let contents: [String: [MediaLibraryItem]]

        /// Milliseconds `albums()` waits before answering. A library that
        /// answers instantly cannot show that the screen said it was working.
        private let albumDelayMS: UInt64

        init(
            access: MediaLibraryAccess = .granted,
            grantOnRequest: MediaLibraryAccess = .granted,
            albums: [MediaLibraryAlbum],
            contents: [String: [MediaLibraryItem]],
            albumDelayMS: UInt64 = 0
        ) {
            self.access = access
            self.grantOnRequest = grantOnRequest
            albumList = albums
            self.contents = contents
            self.albumDelayMS = albumDelayMS
        }

        func requestAccess() async -> MediaLibraryAccess {
            requestCount += 1
            access = grantOnRequest
            return access
        }

        func albums() async -> [MediaLibraryAlbum] {
            if albumDelayMS > 0 {
                try? await Task.sleep(for: .milliseconds(albumDelayMS))
            }
            return albumList
        }

        func items(in album: MediaLibraryAlbum.ID) async -> [MediaLibraryItem] {
            contents[album] ?? []
        }

        func thumbnail(for item: MediaLibraryItem.ID, size: CGSize) async -> UIImage? {
            UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
                UIColor.gray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
        }
    }

    private struct Screen {
        let picker: MediaPickerViewController
        let navigation: UINavigationController
        let window: UIWindow
    }

    private static func library(
        photos: Int,
        videos: Int = 0,
        access: MediaLibraryAccess = .granted,
        grantOnRequest: MediaLibraryAccess = .granted
    ) -> StubLibrary {
        var items = (0..<photos).map { MediaLibraryItem(id: "photo-\($0)", kind: .photo) }
        items += (0..<videos).map { MediaLibraryItem(id: "video-\($0)", kind: .video(duration: 12)) }
        return StubLibrary(
            access: access,
            grantOnRequest: grantOnRequest,
            albums: [
                MediaLibraryAlbum(id: "recents", title: "Recents", count: items.count),
                MediaLibraryAlbum(id: "videos", title: "Videos", count: videos)
            ],
            contents: ["recents": items, "videos": items.filter(\.isVideo)]
        )
    }

    /// Hosted as the window's root, because the tray animates against a real
    /// layout and a cell only exists once the grid has a size to lay out in.
    private func open(_ library: StubLibrary) async throws -> Screen {
        let picker = MediaPickerViewController(library: library) { _ in UIViewController() }
        let navigation = UINavigationController(rootViewController: picker)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        try await settle(until: { !picker.debugItems.isEmpty || !picker.debugAlbumTitles.isEmpty })
        window.layoutIfNeeded()
        return Screen(picker: picker, navigation: navigation, window: window)
    }

    /// The library answers on its own turn, so the screen is given one.
    private func settle(until condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func labels(in view: UIView) -> [String] {
        var found: [String] = []
        for subview in view.subviews {
            if let label = subview as? UILabel, let text = label.text { found.append(text) }
            found += labels(in: subview)
        }
        return found
    }

    // MARK: - The albums

    /// The count rides in the pill's badge — the red bubble every other selector
    /// in the app states a number in — so the title carries the name alone.
    @Test func eachAlbumPillWearsItsCountInItsBadge() async throws {
        let screen = try await open(Self.library(photos: 7, videos: 3))

        #expect(screen.picker.debugAlbumTitles == ["Recents", "Videos"], "the name alone")
        let bar = try #require((screen.picker.toolbarItems ?? []).compactMap(\.customView).first)
        let marks = Self.labels(in: bar)
        #expect(marks.contains("10"), "Recents counts photos and videos alike: \(marks)")
        #expect(marks.contains("3"), "and Videos counts only the videos: \(marks)")
    }

    /// ⚠️ THE BADGE STOPS AT "99+", so a real library's exact size is not on
    /// screen — the title used to spell it out and the bubble cannot. That is the
    /// price of wearing the same badge as every other selector, and it is
    /// asserted here rather than left to be discovered on a device.
    @Test func aLibraryPastNinetyNineWearsTheBadgesCeiling() async throws {
        let screen = try await open(Self.library(photos: 12_400))

        let bar = try #require((screen.picker.toolbarItems ?? []).compactMap(\.customView).first)
        let marks = Self.labels(in: bar)
        #expect(marks.contains("99+"), "the ceiling, not the figure: \(marks)")
        #expect(screen.picker.debugAlbumTitles.first == "Recents", "and no count in the title")
    }

    @Test func theAlbumStripRidesTheToolbar() async throws {
        let screen = try await open(Self.library(photos: 3))

        let hosted = (screen.picker.toolbarItems ?? []).compactMap(\.customView)
        #expect(hosted.count == 1, "the strip, and nothing else competing for the band")
        #expect(screen.navigation.isToolbarHidden == false, "raised by the screen itself")
    }

    // MARK: - Choosing

    @Test func theTrayStaysDownUntilSomethingIsChosen() async throws {
        let screen = try await open(Self.library(photos: 6))
        #expect(screen.picker.debugTrayIsShowing == false)

        screen.picker.debugTapItem(at: 0)
        #expect(screen.picker.debugTrayIsShowing, "one photo is enough to raise it")

        screen.picker.debugTapItem(at: 0)
        #expect(screen.picker.debugTrayIsShowing == false, "and giving it back puts it away")
    }

    @Test func nextCountsWhatItWillCarryAndRefusesToGoEmptyHanded() async throws {
        let screen = try await open(Self.library(photos: 6))
        let next = try #require(screen.picker.navigationItem.rightBarButtonItems?.first)
        #expect(next.isEnabled == false, "nothing chosen, nowhere to go")
        #expect(next.title == "Next")

        screen.picker.debugTapItem(at: 0)
        screen.picker.debugTapItem(at: 2)

        #expect(next.isEnabled)
        #expect(next.title == "Next (2)")
    }

    /// Drafts sits between Cancel and Next, and Next sits at the edge — bar
    /// items are laid out from the trailing edge inwards.
    @Test func theTopBarKeepsItsPromisedOrder() async throws {
        let screen = try await open(Self.library(photos: 3))

        #expect(screen.picker.navigationItem.leftBarButtonItems?.map(\.title) == ["Cancel"])
        #expect(screen.picker.navigationItem.rightBarButtonItems?.map(\.title) == ["Next", "Drafts"])
    }

    @Test func theCapSaysSoRatherThanSwallowingTheTap() async throws {
        let screen = try await open(Self.library(photos: MediaPickerSelection.limit + 4))
        for index in 0..<MediaPickerSelection.limit { screen.picker.debugTapItem(at: index) }

        screen.picker.debugTapItem(at: MediaPickerSelection.limit)

        #expect(screen.picker.debugSelection.count == MediaPickerSelection.limit)
        #expect(
            screen.picker.presentedViewController is UIAlertController,
            "the viewer is told why the tile did not take"
        )
    }

    @Test func aDragInTheTrayReordersWhatWillBePosted() async throws {
        let screen = try await open(Self.library(photos: 6))
        for index in 0..<3 { screen.picker.debugTapItem(at: index) }
        let chosen = screen.picker.debugSelection

        screen.picker.debugReorder([chosen[2], chosen[0], chosen[1]])

        #expect(screen.picker.debugSelection == [chosen[2], chosen[0], chosen[1]])
    }

    // MARK: - The sheet

    /// One row tall, a three-column grid shows a third of a row and scrolls into
    /// a void. Sideways it says what it is: there is more of the album that way.
    ///
    /// ⚠️ AND IT TURNS ON ARRIVAL, NOT ON THE ANNOUNCEMENT. A sheet reports its
    /// new detent as the drag ends, while the animation towards that height is
    /// still running — an album that turned then would be seen reflowing as the
    /// sheet travelled.
    @Test func theAlbumTurnsSidewaysOnlyOnceTheSheetHasArrived() {
        let resting = MediaPickerViewController.restingDetentIdentifier

        #expect(
            MediaPickerViewController.axis(forDetent: resting, height: 352, restingHeight: 352)
                == .horizontal,
            "arrived at its resting height"
        )
        #expect(
            MediaPickerViewController.axis(forDetent: resting, height: 700, restingHeight: 352)
                == .vertical,
            "still travelling towards it"
        )
        #expect(
            MediaPickerViewController.axis(forDetent: .large, height: 352, restingHeight: 352)
                == .vertical,
            "opened, however tall it happens to be in mid-flight"
        )
    }

    /// The tray is part of what the sheet rests around, so choosing the first
    /// photo has to make the resting height taller by exactly the tray AND the
    /// air kept above it — without that gap the album's last row and the strip
    /// of chosen thumbnails read as one block with a seam down the middle.
    @Test func theSheetRestsTallerOnceTheTrayIsUp() async throws {
        let screen = try await open(Self.library(photos: 6))
        let bare = screen.picker.debugRestingHeight

        screen.picker.debugTapItem(at: 0)

        let expected = bare + SelectedMediaTrayView.height + MediaPickerViewController.debugTrayGap
        #expect(
            screen.picker.debugRestingHeight == expected,
            "grew by the tray and its gap, nothing else: \(bare) → \(screen.picker.debugRestingHeight)"
        )
    }

    /// The gap at the edges and the gap between two tiles are one measurement,
    /// so three tiles and four gaps fill the width with nothing left over.
    @Test func theEdgesAndTheTilesShareOneGap() {
        let width: CGFloat = 390
        let gutter = MediaPickerViewController.debugGutter
        let side = MediaPickerViewController.debugTileSide(forWidth: width)
        let leftOver = width - (side * 3 + gutter * 4)

        #expect(side > 0)
        #expect(leftOver >= 0, "three tiles and four gaps fit in \(width): tile \(side), left \(leftOver)")
        #expect(leftOver < 3, "and only rounding is left over: \(leftOver)")
    }

    // MARK: - Access

    @Test func anUnaskedLibraryIsAskedOnce() async throws {
        let library = Self.library(photos: 4, access: .undetermined)
        let screen = try await open(library)

        #expect(library.requestCount == 1)
        #expect(screen.picker.debugItems.count == 4, "and the grid fills once it is allowed")
    }

    /// Limited access hands back a real library that holds fewer things. Putting
    /// a wall in front of it would hide photos the viewer has already shared.
    @Test func limitedAccessIsALibraryLikeAnyOther() async throws {
        let library = Self.library(photos: 4, access: .limited)
        let screen = try await open(library)

        #expect(library.requestCount == 0, "already answered")
        #expect(screen.picker.debugItems.count == 4)
    }

    /// ⚠️ **A SCREEN THAT SAYS NOTHING WHILE IT WORKS READS AS A BROKEN ONE**,
    /// and the wait is not always ours: the system's permission sheet stands in
    /// front of this screen for as long as the viewer takes to answer it, with
    /// the album blank behind. The stub is deliberately slow, because a library
    /// that answers instantly cannot show that anything was ever said.
    @Test func theScreenSaysItIsWorkingUntilTheLibraryAnswers() async throws {
        let items = (0..<4).map { MediaLibraryItem(id: "photo-\($0)", kind: .photo) }
        let library = StubLibrary(
            albums: [MediaLibraryAlbum(id: "recents", title: "Recents", count: items.count)],
            contents: ["recents": items],
            albumDelayMS: 400
        )
        let picker = MediaPickerViewController(library: library) { _ in UIViewController() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: picker)
        window.isHidden = false
        window.layoutIfNeeded()

        #expect(picker.debugIsLoading, "the library has not answered yet")

        try await settle(until: { !picker.debugItems.isEmpty })
        #expect(picker.debugIsLoading == false, "and it stops once there is something to show")
    }

    @Test func aRefusedLibrarySaysSoInsteadOfShowingAnEmptyGrid() async throws {
        let library = Self.library(photos: 4, access: .undetermined, grantOnRequest: .denied)
        let picker = MediaPickerViewController(library: library) { _ in UIViewController() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: picker)
        window.isHidden = false
        window.layoutIfNeeded()

        try await settle(until: { Self.labels(in: picker.view).contains("No access to your photos") })
        #expect(Self.labels(in: picker.view).contains("No access to your photos"))
        #expect(picker.debugAlbumTitles.isEmpty, "and no strip of albums it cannot read")
        // ⚠️ A refusal ends the wait too. A spinner left turning over an empty
        // state is the most convincing way to look permanently broken.
        #expect(picker.debugIsLoading == false, "and it stops saying it is working")
    }
}
