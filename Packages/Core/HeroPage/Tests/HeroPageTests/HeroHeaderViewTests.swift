import DesignSystem
import MediaCore
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
    @Test func aRedactedAvatarWearsOnlyItsOwnBone() async throws {
        let header = makeHeader(avatar: .person)
        header.setRedacted(true)
        let avatar = try #require(first(AvatarView.self, in: header))
        let disc = try #require(avatar.superview)
        #expect(disc.subviews.filter { $0 is SkeletonBoneView }.isEmpty, "a redaction bone over the avatar's own")
        #expect(disc.backgroundColor == Surface.mediaGround)
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
        #expect((widths.max() ?? 0) - (widths.min() ?? 0) < 0.5, "unequal cells: \(widths)")
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
        #expect(collapsed.debugBannerFrame.maxY < standard.debugBannerFrame.maxY - 50,
                "the card is not shorter: \(collapsed.debugBannerFrame) vs \(standard.debugBannerFrame)")
        #expect((collapsed.bandAvatarDetent ?? 99) < 1, "a collapsed band has no notch left to rest on")
    }

    /// Any view can stand in the disc — a place's flag — filling it; with no
    /// person's avatar to wait for, the pictures are settled.
    /// ⚠️ ONE QUIET GREY ROUND THE AVATAR (#1792): the ring is
    /// `Surface.avatarRim` in both styles, never the page's white or black,
    /// and follows a style flip (a `CGColor` does not resolve itself).
    @Test func theAvatarRingIsOneQuietGreyInBothStyles() throws {
        let header = makeHeader()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.addSubview(header)
        window.isHidden = false
        var rings: [UIUserInterfaceStyle: UIColor] = [:]
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            header.layoutIfNeeded()
            let ring = try #require(header.debugAvatarRingColor)
            let expected = Surface.avatarRim.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            #expect(UIColor(cgColor: ring) == expected, "the \(style == .dark ? "dark" : "light") ring is not the rim's grey")
            #expect(UIColor(cgColor: ring) != Surface.page.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)))
            rings[style] = UIColor(cgColor: ring)
        }
        // "Barely varies": the two styles' rings are a few points apart at most.
        var light: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var dark: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        rings[.light]?.getRed(&light.0, green: &light.1, blue: &light.2, alpha: &light.3)
        rings[.dark]?.getRed(&dark.0, green: &dark.1, blue: &dark.2, alpha: &dark.3)
        #expect(abs(light.0 - dark.0) < 0.05 && abs(light.1 - dark.1) < 0.05 && abs(light.2 - dark.2) < 0.05)
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
}
