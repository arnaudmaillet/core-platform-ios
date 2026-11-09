#if DEBUG
import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// The embed card's catalogue (#2216), beside `-voice-catalog`: every size ×
/// every state of the channel card — Join, Request to Join, Requested, Open,
/// a banned viewer, a deleted, a private and a blocked channel — light and
/// dark, on a text face. `-embed-catalog` at launch, or the debug
/// dashboard's Screens.
///
/// Its buttons work: with no actions registered (a launch straight into
/// the catalogue), a stand-in answers after a beat, so each state's tap can
/// be seen.
public final class EmbedCatalogViewController: UIViewController {
    /// `-embed-catalog` at launch.
    public static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-embed-catalog") }

    private let pipeline: ImagePipeline?
    private let scroll = UIScrollView()
    private let column = UIStackView()

    public init(pipeline: ImagePipeline? = nil) {
        self.pipeline = pipeline
        super.init(nibName: nil, bundle: nil)
        title = "Embed card"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Every state the card draws, named.
    static let states: [(name: String, channel: ChannelEmbed)] = {
        func channel(
            _ id: String, _ state: ChannelEmbed.ViewerState, _ visibility: ChannelEmbed.Visibility = .public,
            availability: ChannelEmbed.Availability = .available
        ) -> ChannelEmbed {
            ChannelEmbed(
                conversationID: ConversationID("catalog-\(id)"), name: "Harbour notes",
                photoURL: URL(string: "https://picsum.photos/seed/harbour/400/400"),
                description: "Boats in, boats out — every tide, every evening, from the harbour wall.",
                subscriberCount: 12_400, visibility: visibility, viewerState: state, availability: availability,
                lastMessagePreview: "Tonight's light: the pier at 19:42, gold all the way down."
            )
        }
        return [
            ("Join — public, not in", channel("join", .none)),
            ("Request to Join — on request", channel("request", .none, .onRequest)),
            ("Requested", channel("requested", .requested, .onRequest)),
            ("Open — subscriber", channel("open", .subscriber)),
            ("Banned — no button", channel("banned", .banned)),
            ("Deleted", channel("deleted", .none, availability: .deleted)),
            ("Private", channel("private", .none, availability: .private)),
            ("Blocked", channel("blocked", .none, availability: .blocked)),
        ]
    }()

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        if PostEmbedView.channelActions == nil { PostEmbedView.channelActions = StandInActions.shared }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        column.axis = .vertical
        column.spacing = Spacing.lg
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(column)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.lg),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.lg),
            column.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.lg),
            column.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg),
        ])
        for style in [UIUserInterfaceStyle.light, .dark] {
            for size in PostEmbeds.Size.allCases {
                column.addArrangedSubview(section(style: style, size: size))
            }
        }
    }

    /// One ground and one size: every state on it.
    private func section(style: UIUserInterfaceStyle, size: PostEmbeds.Size) -> UIView {
        let title = UILabel()
        title.font = .appFont(forTextStyle: .footnote)
        title.textColor = .secondaryLabel
        title.text = "\(style == .dark ? "Dark" : "Light") · \(size)"

        let ground = UIStackView()
        ground.axis = .vertical
        ground.spacing = Spacing.md
        ground.overrideUserInterfaceStyle = style
        // A card, as the surfaces that will hold the embed are (#1494).
        Surface.dressCard(ground)
        ground.isLayoutMarginsRelativeArrangement = true
        ground.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Spacing.md, leading: Spacing.md, bottom: Spacing.md, trailing: Spacing.md
        )
        for state in Self.states {
            let name = UILabel()
            name.font = .appFont(forTextStyle: .caption1)
            name.textColor = .tertiaryLabel
            name.text = state.name
            let card = PostEmbedView()
            card.show(.channel(state.channel), size: size, pipeline: pipeline)
            ground.addArrangedSubview(name)
            ground.addArrangedSubview(card)
            ground.setCustomSpacing(Spacing.xs, after: name)
        }
        let section = UIStackView(arrangedSubviews: [title, ground])
        section.axis = .vertical
        section.spacing = Spacing.sm
        return section
    }

    /// The catalogue's own answers, when the app registered none: a beat,
    /// then the state a server would give.
    @MainActor
    private final class StandInActions: ChannelEmbedActing {
        static let shared = StandInActions()

        func join(_ id: ConversationID) async throws -> ChannelEmbed.ViewerState {
            try await Task.sleep(for: .milliseconds(600))
            return .subscriber
        }

        func requestToJoin(_ id: ConversationID) async throws -> ChannelEmbed.ViewerState {
            try await Task.sleep(for: .milliseconds(600))
            return .requested
        }

        func cancelJoinRequest(_ id: ConversationID) async throws -> ChannelEmbed.ViewerState {
            try await Task.sleep(for: .milliseconds(400))
            return .none
        }

        func open(_ id: ConversationID) {}
    }
}
#endif
