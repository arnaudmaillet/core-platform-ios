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
            .bubble(AppButton(aspect: .pill(.quiet), size: .icon, content: .symbol("star"))),
            .bubble(AppButton(aspect: .pill(.quiet), size: .icon, content: .symbol("qrcode")))
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
        let bubble = AppButton(aspect: .pill(.quiet), size: .icon, content: .symbol("qrcode"))
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
}
