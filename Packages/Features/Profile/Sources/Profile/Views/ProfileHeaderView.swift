import DesignSystem
import HeroPage
import MediaCore
import MediaUI
import ProfileData
import UIKit

/// The profile's hero header (`HeroHeaderView`, #1654): the person's avatar,
/// name over @handle, Followers · Following · Likes, bio and link.
///
/// ⚠️ NO ACTION ROW (#2475, the owner 2026-11-28): Follow, Message, the bell
/// and the QR code are someone else's bottom toolbar (`ProfileRelationToolbar`),
/// Edit and ⋯ the own profile's bar. Where the row stood, the page selector
/// sits at rest (`HeroPageSelector.Placement.header`).
///
/// What it adds to the hero header is the profile's own: the relationship
/// lists behind two of the counters, the relation mark on the avatar, and the
/// model it shows (`ProfileDisplayModel`).
final class ProfileHeaderView: HeroHeaderView {
    init(imagePipeline: ImagePipeline) {
        // The likes the profile's posts have received, summed — the heart
        // every tile of the gallery below counts. Was "Reactions" beside a
        // "Views" total until 2026-09-30.
        super.init(imagePipeline: imagePipeline, counters: ["Followers", "Following", "Likes"])
        // Followers and Following open the relationship lists; Likes is a
        // total with nothing behind it.
        for (stat, direction) in zip(counters, [RelationshipDirection.followers, .following]) {
            stat.isTappable = true
            stat.addAction(
                UIAction { [weak self] _ in self?.onRelationshipsTapped?(direction) },
                for: .touchUpInside
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Invoked when the Followers or Following counter is tapped — the two
    /// columns that lead somewhere. Likes is a read-only total with no list
    /// behind it, and stays inert.
    var onRelationshipsTapped: ((RelationshipDirection) -> Void)?

    // MARK: - Configuration

    /// Shows `model` — see `HeroHeaderView.configure(with:)`.
    func configure(with model: ProfileDisplayModel) {
        configure(with: HeroHeaderContent(model))
    }

    /// Shows `model` group by group — see
    /// `HeroHeaderView.configure(with:staggered:)`.
    func configure(with model: ProfileDisplayModel, staggered: Bool) {
        configure(with: HeroHeaderContent(model), staggered: staggered)
    }

    // MARK: - The profile's phases (#1757)

    /// THE ONE MAPPING from the profile's phase to the header, for every
    /// screen that shows a profile's header — the profile and the profile
    /// card. Each screen used to write its own; the two drifted (the card
    /// never drew its loading state, nor kept the profile's switch), and the
    /// card opened on the header's blank default: a "transparent" avatar, a
    /// bare banner (the owner's recording, 2026-10-27).
    ///
    /// - Parameters:
    ///   - profileKnown: whether a profile has ever loaded — a failure keeps
    ///     its header, a first failure shows none.
    ///   - switching: a profile switch — the header is HELD rather than
    ///     redacted (a fast load's shimmer read as a wipe), and the content
    ///     lands group by group.
    ///   - animated: the reveal cross-fades (on screen).
    func render(_ phase: ProfileViewModel.Phase, profileKnown: Bool, switching: Bool = false, animated: Bool) {
        switch phase {
        case .loading:
            isHidden = false
            if !switching { setRedacted(true) }
        case .seeded(let seed):
            // The person as the origin showed them, for real (#1859): only
            // the counters are bones, and nothing is reserved that may not
            // exist — no bio, no link, a banner only when certain.
            isHidden = false
            setRedacted(false)
            super.configure(with: HeroHeaderContent(seed))
            setCountersRedacted(true)
        case .content(let model):
            isHidden = false
            // Content first — the labels adopt their text while still
            // invisible under the bones — then the alpha-only reveal. Over a
            // seed it replaces field by field: an equal name or avatar does
            // not move (`HeroHeaderView.configure` diffs).
            configure(with: model, staggered: switching)
            setRedacted(false, animated: animated)
            setCountersRedacted(false, animated: animated)
        case .failed:
            setRedacted(false)
            // Nothing ever loaded: an empty badge and counters would show
            // around the screen's failure block.
            isHidden = !profileKnown
        case .notFound:
            // A plain page (#1406): no header for no one.
            setRedacted(false)
            isHidden = true
        }
    }

    // MARK: - The relation mark (#2014)

    /// THE ONE MAPPING from the relationship to the badge, for the avatar
    /// (#2014), on the profile and its card: following, friends when mutual
    /// (#2419: the badge keeps only those two, passive; no "+" and no clock,
    /// the toolbar's Follow is the action). Nil for a profile with no badge
    /// to show: not followed, asked, the viewer's own, one the viewer cannot
    /// follow, one not read yet.
    static func relationBadge(for state: ProfileViewModel.FollowButton, mutual: Bool) -> PersonPill.Badge? {
        switch state {
        case .following: mutual ? .friends : .following
        default: nil
        }
    }

    /// The avatar's mark (#2014, #2419): the one mapping, as the author pill
    /// and the inbox wear it. Passive, never a control.
    ///
    /// None for good for the viewer's own profile (known at once, so it never
    /// wears the skeleton's badge first), someone blocked, a profile the
    /// viewer cannot follow, one not followed or only asked. A relation not
    /// read yet wears the skeleton's badge (#2098), never nothing. Pure, for
    /// tests.
    static func avatarMark(
        for state: ProfileViewModel.FollowButton, mutual: Bool, blocked: Bool, isOwnProfile: Bool
    ) -> PersonPill.Badge {
        guard !blocked, !isOwnProfile else { return .none }
        if state == .hidden { return .loading }
        return relationBadge(for: state, mutual: mutual) ?? .none
    }

    /// Wears the relationship on the avatar — through the badge's replace
    /// once on screen; the header never moves for it.
    func configureRelationMark(
        _ state: ProfileViewModel.FollowButton, mutual: Bool, blocked: Bool, isOwnProfile: Bool
    ) {
        setRelationMark(
            Self.avatarMark(for: state, mutual: mutual, blocked: blocked, isOwnProfile: isOwnProfile),
            animated: window != nil
        )
    }
}

extension HeroHeaderContent {
    /// A person known from where they were opened (#1859): the counters'
    /// cells hold a blank figure under their bones.
    init(_ seed: ProfileSeedModel) {
        self.init(
            title: seed.displayName,
            subtitle: seed.handle ?? "",
            counterValues: [" ", " ", " "],
            avatarURL: seed.avatarURL,
            avatarMonogram: seed.avatarMonogram,
            avatarFrameID: seed.avatarFrameID,
            bannerPending: seed.reservesBanner
        )
    }

    /// A profile, as the hero header shows it.
    init(_ model: ProfileDisplayModel) {
        self.init(
            title: model.displayName,
            subtitle: model.handleLine,
            isVerified: model.isVerified,
            bio: model.hasBio ? model.bio : nil,
            websiteText: model.websiteText,
            websiteURL: model.websiteURL,
            counterValues: [model.followerText, model.followingText, model.likesText],
            avatarURL: model.avatarURL,
            avatarMonogram: model.avatarMonogram,
            avatarFrameID: model.avatarFrameID,
            bannerImageURL: model.bannerImageURL,
            bannerVideoURL: model.bannerVideoURL
        )
    }
}
