import DesignSystem
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import HeroPage

/// The hero header as a page kind composes it (#1654): as many counters as
/// it counts, a banner or none, a person's avatar or any view in the disc,
/// its own action row — at the default text size and at the app's ceiling.
@MainActor
struct HeroHeaderViewTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    /// A place's counters and a profile's.
    nonisolated static let captionSets: [[String]] = [["Ranking", "Likes"], ["Followers", "Following", "Likes"]]
    nonisolated static let textSizes: [UIContentSizeCategory] = [.large, .extraExtraExtraLarge]

    private func makeHeader(
        captions: [String] = ["Ranking", "Likes"], avatar: HeroHeaderAvatar = .person,
        banner: URL? = nil, width: CGFloat = 393, textSize: UIContentSizeCategory? = nil
    ) -> HeroHeaderView {
        let header = HeroHeaderView(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), counters: captions, avatar: avatar
        )
        if let textSize { header.traitOverrides.preferredContentSizeCategory = textSize }
        header.chromeTopInset = 103
        header.setActions([
            .capsule(AppButton(aspect: .pill(.quiet), size: .header, content: .title("Pin"))),
            .bubble(AppIconButton(style: .bubble(.quiet), content: .symbol("star"))),
            .bubble(AppIconButton(style: .bubble(.quiet), content: .symbol("qrcode")))
        ])
        header.configure(with: HeroHeaderContent(
            title: "Paris", subtitle: "France",
            counterValues: captions.indices.map { "\(($0 + 1) * 1_234)" },
            bannerImageURL: banner
        ))
        header.frame = CGRect(x: 0, y: 0, width: width, height: 1)
        header.frame.size.height = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        header.setNeedsLayout()
        header.layoutIfNeeded()
        return header
    }

    private func first<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        for subview in view.subviews {
            if let match = subview as? T { return match }
            if let found = first(type, in: subview) { return found }
        }
        return nil
    }

    /// ⚠️ ONE BONE ON THE DISC (#1771): a redacted header holds the avatar's
    /// place with `AvatarView`'s own skeleton, never a redaction bone stacked
    /// over it — two skeletons on one disc.
    /// ⚠️ AIR BETWEEN THE COUNTERS (#2182): at the app's ceiling on an
    /// iPhone SE's width, "Followers" filled its cell and ran into
    /// "Following". Each word keeps `statCellInset` (4 pt) from its cell's
    /// edges, so two neighbours stand at least 8 pt apart, at every text size.
    ///
    /// ⚠️ IN A WINDOW carrying the text size: off one, the test host ignores
    /// the override and the captions stay at the default size, where they
    /// never fill their cells (the test passed with no inset at all).
    @Test(arguments: textSizes, [false, true])
    func theCountersWordsNeverTouch(textSize: UIContentSizeCategory, bold: Bool) {
        let width: CGFloat = 375
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 900))
        window.traitOverrides.preferredContentSizeCategory = textSize
        // Bold Text, and Care Mode's heavier type: the wider words that ran
        // into each other on the SE.
        if bold { window.traitOverrides.legibilityWeight = .bold }
        defer { window.isHidden = true }
        let header = makeHeader(captions: ["Followers", "Following", "Likes"], width: width)
        window.addSubview(header)
        header.frame.size.height = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        header.setNeedsLayout()
        header.layoutIfNeeded()
        let captions = header.counters.map { $0.debugLabels[1] }
        if textSize == .extraExtraExtraLarge {
            // The guard against measuring the default size again.
            #expect((captions.first?.font.pointSize ?? 0) > 14, "the window's text size did not reach the captions")
        }
        let words = captions.map { $0.convert($0.bounds, to: header) }
        for (left, right) in zip(words, words.dropFirst()) {
            // 8 pt, written out: a bound read from `statCellInset` itself
            // would pass with no inset at all.
            #expect(right.minX - left.maxX >= 8 - 0.5,
                    "\(textSize.rawValue)\(bold ? ", bold" : ""): \(right.minX - left.maxX) pt between two counters' words")
        }
    }

    /// The name wears a chevron only while it opens something, and a tap
    /// on it says so (the owner, 2026-11-08: the own profile's switcher).
    @Test func theNameWearsAChevronWhileItOpensSomething() {
        let header = makeHeader()
        #expect(!header.debugShowsTitleChevron)
        var taps = 0
        header.onTitleTapped = { taps += 1 }
        #expect(header.debugShowsTitleChevron)
        header.debugTapTitle()
        #expect(taps == 1)
        header.onTitleTapped = nil
        #expect(!header.debugShowsTitleChevron)
    }

    /// ⚠️ A very long name is cut, never its chevron: it ends in "…" and the
    /// chevron stays whole, inside the header (the owner, 2026-11-08).
    @Test(arguments: textSizes)
    func aVeryLongNameIsCutAndKeepsItsChevron(_ textSize: UIContentSizeCategory) {
        let header = makeHeader(width: 375, textSize: textSize)
        header.onTitleTapped = {}
        header.configure(with: HeroHeaderContent(
            title: "Maximilian Alexander Christopher Montgomery-Wellington the Third of Westminster",
            subtitle: "@maximilian", counterValues: ["1", "2"]
        ))
        header.setNeedsLayout()
        header.layoutIfNeeded()
        let chevron = header.debugTitleChevronFrame
        #expect(chevron.width > 4, "the chevron was squeezed away: \(chevron)")
        #expect(chevron.maxX <= header.bounds.width, "the chevron runs off the header: \(chevron)")
        #expect(header.debugNameIsTruncated, "the long name was not cut")
        #expect(chevron.minX >= header.debugNameFrame.maxX - 0.5, "the chevron sits on the name")
    }

    /// The name (#2334): title2 bold, on ONE line at the default size,
    /// shrinking to 0.85 before its "…"; on TWO at the app's largest size,
    /// which every accessibility size is drawn as (#482).
    ///
    /// ⚠️ IN A WINDOW carrying the text size (`hostedHeader`): off one, the
    /// test host ignores the override and the name stays at the default
    /// size, on the default line count.
    @Test(arguments: textSizes)
    func theNameIsTitle2BoldOnOneLineUntilTheLargestSize(_ textSize: UIContentSizeCategory) throws {
        let (header, window) = hostedHeader(textSize: textSize)
        defer { window.isHidden = true }
        let font = try #require(header.debugNameFont)
        let weight = (font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
        #expect((weight ?? 0) >= UIFont.Weight.bold.rawValue - 0.01, "the name is not bold: \(String(describing: weight))")
        let large = textSize == .large
        if large {
            #expect(abs(font.pointSize - UIFont.defaultPointSize(for: .title2)) < 0.5, "not title2: \(font.pointSize)")
        } else {
            #expect(font.pointSize > UIFont.defaultPointSize(for: .title2), "the name did not scale: \(font.pointSize)")
        }
        #expect(header.debugNameLineCount == (large ? 1 : 2), "\(textSize.rawValue): \(header.debugNameLineCount) lines")
        #expect(header.debugNameShrinks == large, "\(textSize.rawValue): shrinks \(header.debugNameShrinks)")
        // UILabel keeps the factor as a Float: 0.8500000238.
        #expect(abs(header.debugNameMinimumScaleFactor - 0.85) < 0.001, "\(header.debugNameMinimumScaleFactor)")
    }

    /// A header in a window carrying `textSize` (the app's way: a trait
    /// override on the window, `TextSizeCeiling`), measured and laid out
    /// there. The caller hides the window.
    private func hostedHeader(
        textSize: UIContentSizeCategory, width: CGFloat = 393
    ) -> (HeroHeaderView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 900))
        window.traitOverrides.preferredContentSizeCategory = textSize
        let header = makeHeader(width: width)
        window.addSubview(header)
        header.frame.size.height = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        header.setNeedsLayout()
        header.layoutIfNeeded()
        return (header, window)
    }

    /// Every accessibility size and the largest standard one keep two lines;
    /// the usual ones, one.
    @Test func theNamesLinesFollowTheTextSize() {
        for size in [UIContentSizeCategory.extraSmall, .large, .extraLarge, .extraExtraLarge] {
            #expect(HeroHeaderView.nameLineCount(for: size) == 1, "\(size.rawValue)")
        }
        for size in [UIContentSizeCategory.extraExtraExtraLarge, .accessibilityMedium, .accessibilityExtraExtraExtraLarge] {
            #expect(HeroHeaderView.nameLineCount(for: size) == 2, "\(size.rawValue)")
        }
    }

    /// ⚠️ THE @HANDLE STAYS ON ITS OWN LINE UNDER THE NAME (#2334), long
    /// name or short — never after it on the same line, where it would be
    /// the first thing cut.
    @Test(arguments: textSizes)
    func theHandleStaysOnItsOwnLineUnderTheName(_ textSize: UIContentSizeCategory) {
        for title in ["Lena", "Maximilian Alexander Christopher Montgomery-Wellington"] {
            let (header, window) = hostedHeader(textSize: textSize)
            defer { window.isHidden = true }
            header.configure(with: HeroHeaderContent(title: title, subtitle: "@lena", counterValues: ["1", "2"]))
            header.setNeedsLayout()
            header.layoutIfNeeded()
            let name = header.debugNameFrame
            let handle = header.debugHandleFrame
            #expect(handle.minY >= name.maxY - 0.5, "\(title): the handle is not under the name (\(name) / \(handle))")
            #expect(abs(handle.minX - name.minX) < 0.5, "\(title): the handle does not start under the name")
            #expect(handle.height > 0)
        }
    }

    @Test func aRedactedAvatarWearsOnlyItsOwnBone() async throws {
        let header = makeHeader(avatar: .person)
        header.setRedacted(true)
        let avatar = try #require(first(AvatarView.self, in: header))
        let disc = try #require(avatar.superview)
        #expect(disc.subviews.filter { $0 is SkeletonBoneView }.isEmpty, "a redaction bone over the avatar's own")
        #expect(disc.backgroundColor == Surface.avatarGround)
        // The avatar waits for its picture under its skeleton.
        for _ in 0..<100 where avatar.skeleton.alpha == 0 || avatar.skeleton.isHidden {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(avatar.skeleton.alpha > 0 && !avatar.skeleton.isHidden)
    }

    private func label(withText text: String, in view: UIView) -> UILabel? {
        for subview in view.subviews {
            if let label = subview as? UILabel, label.text == text { return label }
            if let found = label(withText: text, in: subview) { return found }
        }
        return nil
    }

    /// One equal cell per counter, across the column beside the disc, each
    /// counter centred in its own and never past it — two for a place, three
    /// for a profile, at the default size and the ceiling.
    @Test(arguments: captionSets, textSizes)
    func eachCounterHasAnEqualCellAcrossTheColumn(captions: [String], textSize: UIContentSizeCategory) throws {
        let header = makeHeader(captions: captions, textSize: textSize)
        let cells = header.debugStatCellFrames
        #expect(cells.count == captions.count)
        let widths = cells.map(\.width)
        // Within half a point, inclusive: a 2× screen (the iPhone SE) rounds
        // a third of the column to the half point — 81.5, 82, 81.5 (#2182).
        #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 0.5, "unequal cells: \(widths)")
        let row = header.debugStatsFrame
        #expect(abs((cells.first?.minX ?? 0) - row.minX) < 0.5 && abs((cells.last?.maxX ?? 0) - row.maxX) < 0.5)
        #expect(abs(row.minX - header.debugNameHalfFrame.minX) < 0.5)
        for (index, frame) in header.debugStatFrames.enumerated() {
            let stat = try #require(frame, "counter \(index) is hidden")
            #expect(abs(stat.midX - cells[index].midX) < 0.5, "counter \(index) is not centred")
            #expect(stat.minX >= cells[index].minX - 0.5 && stat.maxX <= cells[index].maxX + 0.5,
                    "counter \(index) spills out of its cell at \(textSize.rawValue)")
        }
    }

    /// The title and the subtitle get their whole line, whatever the text
    /// size: the disc's side never squashes them.
    @Test(arguments: textSizes)
    func theTitleAndSubtitleAreNeverSquashed(textSize: UIContentSizeCategory) throws {
        let header = makeHeader(textSize: textSize)
        let title = try #require(label(withText: "Paris", in: header))
        let subtitle = try #require(label(withText: "France", in: header))
        #expect(title.bounds.height >= title.font.lineHeight - 0.5)
        #expect(subtitle.bounds.height >= subtitle.font.lineHeight - 0.5)
        // The two halves beside the disc stand inside the header.
        #expect(header.debugStatsHalfFrame.maxY <= header.bounds.maxY)
    }

    /// No picture is the bannerless layout — no banner, page ink; a picture
    /// takes a band card.
    @Test(arguments: [false, true])
    func theBannerFollowsThePicture(hasPicture: Bool) {
        let header = makeHeader(banner: hasPicture ? URL(string: "https://paris.example/banner.jpg") : nil)
        #expect(header.bannerFormat == (hasPicture ? .band : HeroBannerFormat.none))
        #expect(header.debugBannerIsHidden == !hasPicture)
        if !hasPicture {
            #expect(header.debugNameInk == HeroHeaderView.pageNameInk)
        }
    }

    /// A band card resting COLLAPSED (a place's, #1656): its avatar a
    /// detent's gap under the chrome, the card shorter than a profile's.
    @Test func aCollapsedBandRestsItsAvatarUnderTheChrome() {
        let banner = URL(string: "https://paris.example/banner.jpg")
        let standard = makeHeader(banner: banner)
        let collapsed = makeHeader(banner: banner)
        collapsed.bandRestsCollapsed = true
        collapsed.frame.size.height = collapsed.systemLayoutSizeFitting(
            CGSize(width: 393, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        collapsed.layoutIfNeeded()
        #expect(collapsed.bannerFormat == .band)
        let avatarTop = collapsed.debugAvatarFrame.minY
        #expect(abs(avatarTop - (103 + HeroBannerMetrics.bandAvatarDetentGap)) < 1, "avatar at \(avatarTop)")
        // Clearly shorter, on every screen: the standard card's foot stands at
        // 30 % of the screen's height (`bandScreenFraction`), so on an iPhone
        // SE (667 pt) it is 36 pt under the collapsed one, on a Pro over 50
        // (#2182).
        #expect(collapsed.debugBannerFrame.maxY < standard.debugBannerFrame.maxY - 20,
                "the card is not shorter: \(collapsed.debugBannerFrame) vs \(standard.debugBannerFrame)")
        #expect((collapsed.bandAvatarDetent ?? 99) < 1, "a collapsed band has no notch left to rest on")
    }

    /// Any view can stand in the disc — a place's flag — filling it; with no
    /// person's avatar to wait for, the pictures are settled.
    /// ⚠️ NO EDGE ROUND THE AVATAR (#2082, the owner 2026-11-03, replacing
    /// #1792's quiet grey rim): the face alone, in both styles.
    @Test func theAvatarWearsNoEdgeInEitherStyle() {
        let header = makeHeader()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.addSubview(header)
        window.isHidden = false
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            header.layoutIfNeeded()
            #expect(header.debugAvatarRingWidth == 0, "an edge in \(style == .dark ? "dark" : "light")")
        }
        window.isHidden = true
    }

    @Test func aCustomViewFillsTheDisc() {
        // A picture with a size of its own, as a flag is: it must not vote.
        let flag = UIImageView(image: UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200)).image { _ in })
        let header = makeHeader(avatar: .custom(flag))
        let disc = header.debugAvatarFrame
        #expect(disc.width > 0 && abs(disc.width - disc.height) < 0.5, "the disc is not square: \(disc)")
        let shown = flag.convert(flag.bounds, to: header)
        #expect(abs(shown.minX - disc.minX) < 0.5 && abs(shown.minY - disc.minY) < 0.5)
        #expect(abs(shown.width - disc.width) < 0.5 && abs(shown.height - disc.height) < 0.5)
        #expect(header.arePicturesSettled)
        #expect(!header.debugHasAvatarPicture)
    }

    /// The action row: the capsule takes what the bubbles leave, each bubble
    /// a circle `bubbleSize` across, the row the page's width under the bio.
    @Test func theActionRowSharesItsWidthBetweenCapsulesAndBubbles() {
        let header = makeHeader()
        let views = header.debugTrayViews
        #expect(views.count == 3)
        for bubble in views.dropFirst() {
            #expect(abs(bubble.bounds.width - HeroHeaderView.bubbleSize) < 0.5)
            #expect(abs(bubble.bounds.width - bubble.bounds.height) < 0.5)
        }
        let tray = header.debugTrayFrame
        let capsule = views[0].convert(views[0].bounds, to: header)
        #expect(abs(capsule.minX - tray.minX) < 0.5)
        #expect(capsule.width > HeroHeaderView.bubbleSize * 2, "the capsule did not take the rest: \(capsule)")
        #expect(abs(tray.minX - HeroHeaderView.pageMargin) < 0.5)
        #expect(abs(tray.maxX - (header.bounds.width - HeroHeaderView.pageMargin)) < 0.5)
    }

    /// Filling the row again replaces it: the bubbles keep one size each.
    @Test func fillingTheActionRowAgainReplacesIt() {
        let header = makeHeader()
        let bubble = AppIconButton(style: .bubble(.quiet), content: .symbol("qrcode"))
        func activeConstraints() -> Int { bubble.constraints.filter(\.isActive).count }
        let own = activeConstraints()
        header.setActions([.bubble(bubble)])
        let once = activeConstraints()
        header.setActions([.bubble(bubble)])
        #expect(header.debugTrayViews.count == 1)
        #expect(once > own, "the row gave the bubble no size")
        #expect(activeConstraints() == once, "the bubble's sides piled up")
    }

    /// A hidden action row collapses: the header is shorter by its height.
    @Test func aHiddenActionRowCollapses() {
        let shown = makeHeader()
        let hidden = makeHeader()
        let revision = hidden.layoutRevision
        hidden.showsActionTray = false
        #expect(hidden.layoutRevision > revision)
        hidden.frame.size.height = hidden.systemLayoutSizeFitting(
            CGSize(width: 393, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        #expect(hidden.bounds.height < shown.bounds.height - HeroHeaderView.bubbleSize + 0.5)
    }

    /// ⚠️ A loading banner (no picture yet) casts no card shadow (#1757):
    /// the shadow comes with the picture.
    @Test func aBannerWithoutItsPictureCastsNoShadow() throws {
        let header = makeHeader(banner: try #require(URL(string: "mock://banner/never")))
        #expect(header.debugBannerShadowOpacity == 0)
        // Nor a black ground where the banner is not drawn yet.
        #expect(header.debugBannerShadowGround == Surface.skeleton)
    }

    // MARK: - The foot's hairline (#2289)

    /// Off by default — a conversation's info page and the profile card's
    /// sheet are no post lists — and, once a page asks for it, one device
    /// pixel of `.separator` edge to edge, half the rows' gap over the
    /// header's foot: where a row above would draw its line, so the list's
    /// first row draws none of its own.
    @Test func theFootDrawsTheListsHairlineOnlyWhenAsked() throws {
        let header = makeHeader()
        #expect(header.debugFootHairlineFrame == nil, "a hairline nobody asked for")
        header.drawsFootHairline = true
        let line = try #require(header.debugFootHairlineFrame)
        #expect(line.minX == 0)
        #expect(line.width == header.bounds.width)
        #expect(line.height == Surface.hairline(for: header.traitCollection))
        #expect(abs(line.midY - (header.bounds.height - PostGridListRowCell.separatorOffset)) < 0.01)
        // Under the actions, never across them.
        let tray = header.debugTrayFrame
        #expect(line.minY > tray.maxY, "the line \(line) crosses the actions \(tray)")
        header.drawsFootHairline = false
        #expect(header.debugFootHairlineFrame == nil)
    }
}
