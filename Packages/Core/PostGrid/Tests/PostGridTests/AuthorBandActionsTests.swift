import CoreModels
import MediaCore
import UIKit
import Testing
@testable import PostGrid

/// The band's trailing cluster — repost, save, "..." — and the rule that makes
/// it a cluster rather than three things competing with a name.
@MainActor
struct AuthorBandActionsTests {
    private func band(name: String, handle: String, width: CGFloat) -> PostAuthorBandView {
        let band = PostAuthorBandView()
        band.onRepostTapped = {}
        band.onBookmarkTapped = {}
        band.menuActions = { [.report(perform: {})] }
        let post = GalleryPost(
            id: PostID("p"), kind: .photo, isRepost: false,
            thumbnailURL: nil, caption: "", publishedAtMS: 0,
            authorID: ProfileID("a"), authorName: name, authorHandle: handle
        )
        band.configure(with: PostAuthorBandView.Model(post: post)!, imagePipeline: nil)
        band.frame = CGRect(x: 0, y: 0, width: width, height: PostAuthorBandView.avatarDiameter)
        band.layoutIfNeeded()
        return band
    }

    private func buttons(in band: PostAuthorBandView) -> [UIButton] {
        func walk(_ view: UIView) -> [UIButton] {
            if let button = view as? UIButton { return [button] }
            return view.subviews.flatMap(walk)
        }
        return walk(band).filter { !$0.isHidden }
    }

    /// ⚠️ THE REQUIREMENT: the controls outrank the name.
    ///
    /// A name and a handle are the compressible half of this band — they already
    /// truncate by tail — and a long one must give way rather than push a
    /// control off the card. It takes BOTH halves to decide that: required
    /// resistance on the cluster and low resistance on the labels. With only the
    /// first, the labels' default 750 wins some layouts and the buttons are
    /// clipped instead.
    @Test func aLongNameGivesWayToTheControls() {
        let squeezed = band(
            name: "Bartholomew Fitzgerald-Montgomery the Third",
            handle: "bartholomew.fitzgerald.montgomery.the.third",
            width: 300
        )
        let roomy = band(name: "Sofía", handle: "sofia", width: 300)

        let squeezedWidths = buttons(in: squeezed).map(\.bounds.width)
        let roomyWidths = buttons(in: roomy).map(\.bounds.width)
        #expect(squeezedWidths.count == 3)
        #expect(squeezedWidths == roomyWidths)
        // Every control is still its full width, inside the band.
        for button in buttons(in: squeezed) {
            #expect(abs(button.bounds.width - PostAuthorBandView.actionControlWidth) < 0.5)
            #expect(button.convert(button.bounds, to: squeezed).maxX <= squeezed.bounds.width + 0.5)
        }
    }

    private func pill(in band: PostAuthorBandView) -> PostMetaPillView? {
        func walk(_ view: UIView) -> [PostMetaPillView] {
            if let pill = view as? PostMetaPillView { return [pill] }
            return view.subviews.flatMap(walk)
        }
        return walk(band).first
    }

    /// ⚠️ THE REQUIREMENT: the cluster wears the SAME pill as the counters and
    /// the date, at the same height.
    ///
    /// Measured against a real counter chip rather than against the constant, so
    /// this fails if either side stops deriving its height from the shared one —
    /// two pills that agree on a number and disagree on screen is exactly the
    /// failure the constant was introduced to make impossible.
    @Test func theClusterIsTheSameHeightAsTheCardsOtherPills() throws {
        let cluster = try #require(pill(in: band(name: "Sofía", handle: "sofia", width: 300)))
        // ⚠️ Measured by FITTING, not by frame: a loose view keeps whatever
        // frame it was handed — a first version gave it 200x200 and read 200
        // back, which is what the pill's own height constraint is competing
        // with, not what it resolves to.
        let counter = PostMetaPillView(contents: [UILabel()])
        counter.translatesAutoresizingMaskIntoConstraints = false
        let counterHeight = counter
            .systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height

        #expect(abs(cluster.bounds.height - counterHeight) < 0.5)
        #expect(cluster.bounds.height > 0)
    }

    /// And it is not drawn at all when it holds nothing — an empty capsule
    /// beside a name is the same defect as an empty one on a photograph.
    @Test func anEmptyClusterDrawsNoCapsule() throws {
        let bare = PostAuthorBandView()
        bare.frame = CGRect(x: 0, y: 0, width: 300, height: PostAuthorBandView.avatarDiameter)
        bare.layoutIfNeeded()
        #expect(pill(in: bare)?.isHidden == true)

        bare.onBookmarkTapped = {}
        #expect(pill(in: bare)?.isHidden == false)
    }

    /// ⚠️ The pill is the height of a line of type, which is shorter than a
    /// finger — so a press just under the capsule still reaches the control.
    ///
    /// `point(inside:)` alone does not do this: it lets the touch reach the
    /// PILL, whose subviews are bounded normally, so the pill itself answers for
    /// a press aimed at a button. This asks what a touch below the capsule
    /// actually hits.
    @Test func aPressBelowTheCapsuleStillFindsItsControl() throws {
        let band = band(name: "Sofía", handle: "sofia", width: 300)
        let cluster = try #require(pill(in: band))
        let saveButton = try #require(
            buttons(in: band).first { $0.accessibilityLabel == "Save" }
        )
        let slop = (PostMetaPillView.minimumTouchTarget - cluster.bounds.height) / 2
        let target = CGPoint(
            x: cluster.convert(saveButton.bounds, from: saveButton).midX,
            y: cluster.bounds.height + slop - 1
        )

        #expect(slop > 1)
        #expect(cluster.hitTest(target, with: nil) === saveButton)
    }

    /// ⚠️ THE GLYPHS ARE SIZED TO THE PILL, NOT TO THE CARD'S TYPE — and they
    /// are therefore BIGGER than the counters' icons, on purpose.
    ///
    /// "Every icon on the card at one size" is the tidy-looking rule, and it is
    /// wrong here: a glyph beside a number is read against that number, a glyph
    /// alone in a capsule is read against the capsule. Matched to the counters,
    /// these measured 13pt of ink against the heart's 9 — bigger, and reading as
    /// smaller, because of the empty field around them.
    ///
    /// So the assertion is the INEQUALITY, plus the band a lone glyph belongs
    /// in: comfortably over half its container and not filling it.
    @Test func aLoneGlyphIsLargerThanOneSetBesideANumber() throws {
        let band = band(name: "Sofía", handle: "sofia", width: 300)
        let cluster = try #require(pill(in: band))
        let saveButton = try #require(
            buttons(in: band).first { $0.accessibilityLabel == "Save" }
        )
        let glyph = try #require(saveButton.imageView?.image?.size.height)
        let inlineGlyph = try #require(
            UIImage(
                systemName: "heart.fill",
                withConfiguration: UIImage.SymbolConfiguration(
                    font: PostMetaPillView.font, scale: .small
                )
            )?.size.height
        )

        #expect(glyph > inlineGlyph)
        #expect(glyph > cluster.bounds.height * 0.5)
        #expect(glyph < cluster.bounds.height)
    }

    /// And the name really is being squeezed — otherwise the assertion above
    /// would pass on a band that simply had room for everything.
    @Test func theNameIsWhatShrinks() {
        let narrow = band(name: "Bartholomew Fitzgerald-Montgomery", handle: "bart", width: 240)

        func labels(_ view: UIView) -> [UILabel] {
            if let label = view as? UILabel { return [label] }
            return view.subviews.flatMap(labels)
        }
        let nameLabel = labels(narrow).first { $0.text?.hasPrefix("Bartholomew") == true }
        let intrinsic = nameLabel?.intrinsicContentSize.width ?? 0
        #expect(intrinsic > 0)
        #expect((nameLabel?.bounds.width ?? 0) < intrinsic)
    }

    /// A control with no handler is not drawn. The same rule the "..." follows:
    /// visibility tracks the ANSWER, never the presence of a provider.
    @Test func aControlWithNoHandlerIsNotDrawn() {
        let band = PostAuthorBandView()
        band.frame = CGRect(x: 0, y: 0, width: 300, height: PostAuthorBandView.avatarDiameter)
        band.layoutIfNeeded()

        #expect(buttons(in: band).isEmpty)

        band.onBookmarkTapped = {}
        #expect(buttons(in: band).count == 1)
    }

    /// The save control reports the store's answer and never its own: it is set
    /// from outside, before and after a toggle, so a store that refused would
    /// leave the glyph telling the truth.
    @Test func theSaveGlyphFollowsTheStateItIsGiven() {
        let band = band(name: "Sofía", handle: "sofia", width: 300)
        band.isBookmarked = false
        let outline = buttons(in: band).compactMap { $0.configuration?.image }.count

        band.isBookmarked = true

        #expect(outline > 0)
        #expect(band.visibleActionControls.saved)
        // Pressing does not flip it — only the host does.
        band.onBookmarkTapped?()
        #expect(band.visibleActionControls.saved)
    }

    /// A stand-in card must match the ROW, not the design: a surface that wired
    /// neither control shows neither, and a stand-in drawing all three would end
    /// every dismissal with two controls vanishing.
    @Test func aStandInIsToldWhatTheRowActuallyDraws() {
        let row = band(name: "Sofía", handle: "sofia", width: 300)
        let standIn = PostAuthorBandView()
        let shown = row.visibleActionControls

        standIn.showActionControlsAsScenery(
            repost: shown.repost, bookmark: shown.bookmark, saved: shown.saved
        )

        #expect(standIn.visibleActionControls == shown)
    }
}
