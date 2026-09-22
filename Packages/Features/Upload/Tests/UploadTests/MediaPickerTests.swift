import DesignSystem
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

        /// Nothing to present against a stub — the seam exists so the picker can
        /// offer the system sheet without importing `Photos`.
        func presentLimitedPicker(from host: UIViewController) {}

        /// The picker only chooses; the file is fetched at publish time, which
        /// is `NewPostTests`' subject and not this one's.
        func videoFile(for item: MediaLibraryItem.ID) async -> URL? { nil }

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
        // ⚠️ ITEMS, OR A SCREEN THAT HAS STOPPED WORKING — NOT "titles yet".
        // `showAlbums` now runs BEFORE the first album is fetched, because the
        // pages have to exist before anything can be loaded into one. Waiting on
        // the titles would hand every test a picker whose visible page is still
        // empty, and `debugTapItem` would quietly toggle nothing.
        try await settle(until: { !picker.debugItems.isEmpty || !picker.debugIsLoading })
        window.layoutIfNeeded()
        return Screen(picker: picker, navigation: navigation, window: window)
    }

    /// ⚠️ **LIMITED IS A SUCCESS, SO THE GRID STAYS AND THE NOTICE SITS OVER IT.**
    /// `MediaLibraryAccess` records that treating limited access as a refusal
    /// would put an "allow access" wall in front of photos the viewer has already
    /// agreed to share. So this asserts both halves: the banner is up, AND the
    /// album still loaded behind it.
    ///
    /// The reserve is asserted too, because a banner laid OVER the grid without
    /// one would hide the first row permanently — it would cover the very photos
    /// it is talking about.
    @Test func limitedAccessOffersTheNoticeWithoutTakingTheGridAway() async throws {
        let screen = try await open(Self.library(photos: 6, access: .limited, grantOnRequest: .limited))

        #expect(screen.picker.debugAccessNoticeIsHidden == false, "the banner is up")
        #expect(!screen.picker.debugItems.isEmpty, "and the album loaded behind it")
        #expect(screen.picker.debugNoticeReserve > 0, "the first row is not left under it")
    }

    /// ⚠️ **THE HALF THAT MAKES THE OTHER TEST MEAN ANYTHING.** A banner mounted
    /// unconditionally would pass `limitedAccessOffers…` exactly as well. Only
    /// this says it is driven by the access at all.
    @Test func fullAccessShowsNoNoticeAtAll() async throws {
        let screen = try await open(Self.library(photos: 6, access: .granted, grantOnRequest: .granted))

        #expect(screen.picker.debugAccessNoticeIsHidden, "nothing to offer when everything is shared")
        #expect(screen.picker.debugNoticeReserve == 0, "and no room claimed from the grid")
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

    /// An album's count is how many photographs are in it, not how many things
    /// want an answer — so it does not wear the unread pill's red.
    @Test func theAlbumCountsAreNotNotificationRed() async throws {
        let screen = try await open(Self.library(photos: 7, videos: 3))

        let bar = try #require(
            (screen.picker.toolbarItems ?? []).compactMap(\.customView).first as? PagedTabBar
        )
        #expect(bar.badgeTint != .systemRed, "not the alarm colour")
        #expect(bar.badgeTint == .systemBlue)
    }

    /// The album and the pager over it hide the system's top edge effect like
    /// every other list under a header. This screen once opted OUT of the `.soft`
    /// style — it never had a fade under Cancel / Drafts / Next, and asked for
    /// `.soft` iOS 27 laid a heavy blur over its top rows (measured) — but hidden
    /// draws nothing on either system, so there is nothing left to opt out of.
    @Test func theAlbumHidesTheSystemsTopEdge() async throws {
        let screen = try await open(Self.library(photos: 7, videos: 3))
        let pager = try #require(screen.picker.debugPager)
        #expect(pager.pagingScrollView.topEdgeEffect.isHidden, "the pager")

        let page = MediaAlbumPageView()
        let grid = try #require(page.subviews.compactMap { $0 as? UICollectionView }.first)
        #expect(grid.topEdgeEffect.isHidden, "each album's grid")
    }

    /// The albums are TABS: one page each, and the strip selects between them.
    @Test func theGalleryIsOnePageForEachAlbum() async throws {
        let screen = try await open(Self.library(photos: 7, videos: 3))

        #expect(screen.picker.debugPageCount == 2, "Recents and Videos")
        #expect(screen.picker.debugPager != nil, "and a pager to carry them")
    }

    /// ⚠️ THE REGRESSION THIS PINS: a tap sets `selectedIndex` and announces
    /// `.valueChanged`, and by itself nothing else happens at all. The HOST is
    /// what turns that into a page — and the pill then follows the pages back
    /// through `onProgress`, which is why this asserts the PAGE and not the
    /// pill. Where the pill sits given a page is the component's own contract,
    /// and DesignSystem's suites hold it.
    @Test func tappingAnAlbumPagesToIt() async throws {
        let screen = try await open(Self.library(photos: 7, videos: 3))
        let bar = try #require(
            (screen.picker.toolbarItems ?? []).compactMap(\.customView).first as? PagedTabBar
        )
        screen.window.layoutIfNeeded()

        bar.debugSimulateTap(at: 1)

        #expect(bar.selectedIndex == 1)
        #expect(screen.picker.debugPager?.activeIndex == 1, "the pages followed the strip")
    }

    /// An album is read when it is first landed on, not all of them at once —
    /// opening the picker on a device full of albums should cost one fetch.
    @Test func anAlbumIsFetchedWhenItIsFirstLandedOn() async throws {
        let screen = try await open(Self.library(photos: 7, videos: 3))
        screen.window.layoutIfNeeded()
        let pager = try #require(screen.picker.debugPager)

        pager.setActivePage(1, animated: false)
        try await settle(until: { screen.picker.debugItems.count == 3 })

        // ⚠️ HOISTED OUT OF THE MACRO. `allSatisfy` is `rethrows`, and
        // swift-testing rewrites an `#expect` expression into closures that lose
        // the non-throwing inference — "call can throw, but it is not marked
        // with 'try'", reported from inside the expanded macro where no line of
        // ours appears.
        let videosOnly = screen.picker.debugItems.allSatisfy(\.isVideo)
        #expect(videosOnly, "the Videos album, fetched on arrival: \(screen.picker.debugItems)")
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

    // MARK: - The grid

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

/// **A PAGE OWES ITS REVEAL UNTIL IT HAS SOMEWHERE TO PLAY IT.** The album is
/// filled while the sheet is still presenting, and a `UIView.animate` committed
/// without an on-screen rectangle is not slow — it is instant. That is how the
/// spring was swallowed for six takes while every test stayed green, so what is
/// pinned here is the DEBT rather than the animation: a page that cannot yet
/// play its reveal must keep it, not spend it.
@MainActor
struct MediaAlbumPageRevealTests {
    private static func items(_ count: Int) -> [MediaLibraryItem] {
        (0..<count).map { MediaLibraryItem(id: "photo-\($0)", kind: .photo) }
    }

    @Test func aFilledPageOwesAReveal() {
        let page = MediaAlbumPageView()
        // ⚠️ STATED, NOT INHERITED FROM THE SESSION. Suites run in parallel and
        // any of them that opens a picker would otherwise have spent this
        // page's arrival before the test got to it.
        page.debugStagesArrival = true

        #expect(page.awaitingReveal == false, "nothing is owed before it is filled")

        page.setItems(Self.items(9), albumID: "recents")

        #expect(page.awaitingReveal, "and it is owed from the moment it is")
    }

    /// ⚠️ THE REGRESSION THIS EXISTS FOR. A page is filled long before the sheet
    /// has finished presenting; a reveal spent there leaves the viewer exactly
    /// the plain arrival the spring was meant to replace.
    @Test func aPageWithNoWindowKeepsTheDebtInsteadOfSpendingIt() {
        let page = MediaAlbumPageView()
        page.debugStagesArrival = true
        page.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        page.setItems(Self.items(9), albumID: "recents")

        page.playReveal()

        #expect(page.awaitingReveal, "no window, no rectangle — and the debt survives")
    }

    @Test func aPageOnScreenSpendsItOnce() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let page = MediaAlbumPageView()
        page.debugStagesArrival = true
        page.frame = window.bounds
        window.addSubview(page)
        window.isHidden = false
        window.layoutIfNeeded()
        page.setItems(Self.items(9), albumID: "recents")
        window.layoutIfNeeded()

        page.playReveal()
        #expect(page.awaitingReveal == false, "spent, once it had somewhere to play")

        page.playReveal()
        #expect(page.awaitingReveal == false, "and asking twice is not an error")
    }

    /// ⚠️ THE REGRESSION MEASURED ON DEVICE: opening the sheet, cancelling, and
    /// opening it again played the arrival a SECOND time (`arms=2, plays=2`).
    /// A reopened sheet is not an arrival — the viewer has already seen the
    /// library — but a fresh picker builds fresh, empty pages, so only
    /// session-scoped state can tell the two apart.
    @Test func aSecondOpeningDoesNotStageTheArrivalAgain() {
        let album = "reopened-\(UUID().uuidString)"
        let first = MediaAlbumPageView()
        first.debugStagesArrival = true
        first.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window = UIWindow(frame: first.frame)
        window.addSubview(first)
        window.isHidden = false
        window.layoutIfNeeded()
        first.setItems(Self.items(9), albumID: album)
        window.layoutIfNeeded()
        first.playReveal()

        // A fresh page for the SAME album, as a reopened sheet would build — and
        // it asks the session rather than being told.
        let second = MediaAlbumPageView()
        second.setItems(Self.items(9), albumID: album)

        #expect(first.awaitingReveal == false, "the first one spent its arrival")
        #expect(second.awaitingReveal == false, "and the same album does not get another")
    }

    /// ⚠️ **THE BUG THE SINGLE FLAG CAUSED.** Staging was one `Bool` for the
    /// whole process, so Recents consumed it and every other tab was suppressed
    /// for good — the animation looked like a Recents-only feature. A DIFFERENT
    /// album must still get its own arrival.
    @Test func anotherAlbumStillStagesItsOwnArrival() {
        let recents = MediaAlbumPageView()
        recents.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window = UIWindow(frame: recents.frame)
        window.addSubview(recents)
        window.isHidden = false
        window.layoutIfNeeded()
        recents.setItems(Self.items(9), albumID: "tab-recents-\(UUID().uuidString)")
        window.layoutIfNeeded()
        recents.playReveal()

        let videos = MediaAlbumPageView()
        videos.setItems(Self.items(9), albumID: "tab-videos-\(UUID().uuidString)")

        #expect(recents.awaitingReveal == false, "the first tab spent its own")
        #expect(videos.awaitingReveal, "and the second tab is still owed one")
    }

    /// ⚠️ **THE DEBT FLAG IS NOT THE ANIMATION, AND FILM PROVED THE DIFFERENCE.**
    /// Every other reveal test asserts that `awaitingReveal` flips — which is
    /// precisely what a guard passing over an EMPTY `visibleCells` also does: it
    /// spends the debt, un-hides the grid and animates nothing. On device that is
    /// a pop, and every one of those tests stayed green through it. Per-tile
    /// luminance at 48fps: 992 → final in ONE frame, stagger 0.000s.
    @Test func aRevealOnScreenAnimatesTheCellsItHas() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let page = MediaAlbumPageView()
        page.debugStagesArrival = true
        page.frame = window.bounds
        window.addSubview(page)
        window.isHidden = false
        window.layoutIfNeeded()
        page.setItems(Self.items(9), albumID: "revealed-\(UUID().uuidString)")
        window.layoutIfNeeded()

        page.playReveal()

        #expect(page.debugRevealedCells > 0, "a reveal that animates nothing is a pop")
    }

    @Test func anEmptyAlbumOwesNothing() {
        let page = MediaAlbumPageView()

        page.setItems([], albumID: "empty")

        #expect(page.awaitingReveal == false, "there is nothing to spring in")
    }
}
