#if DEBUG
import CoreModels
import DesignSystem
import FeedInterface
import UIKit

/// `-comments-sandbox` (#2087): the two screens the comments redesign is
/// built on, apart from the app — the For You tab's Shots page, and a media
/// post opened full screen.
///
/// ⚠️ THE REAL SCREENS, NOT COPIES (the owner, 2026-11-03): each tab is built
/// by the same `FeedFeatureBuilding` factory the app uses, so what is tuned
/// here is what ships. The new comments space plugs in behind its flag; with
/// the flag off, these are exactly today's screens.
///
/// - **Shots**: `makeForYouFullScreenFeedViewController`, the page the For
///   You tab opens on, over the Discover list, with a tab bar under it as in
///   the app.
/// - **Post**: the mock's comment fixtures (`MockCommentService`'s seed sets)
///   as a list; a row opens the full-screen feed on that post, the other
///   fixtures a swipe away.
///
/// The value after the flag picks the opening: `shots` (the default), `post`
/// (the list), or a post id (`post-0004`: that post, open).
enum CommentsSandbox {
    static let argument = "-comments-sandbox"

    /// A fixture: a mock post and what its comments exercise.
    struct Fixture {
        let id: String
        let title: String
        let detail: String
    }

    /// Media posts only: the redesign is the media post's. Kinds and seeds
    /// as `MockCommentService` writes them (index % 3: 0 video, 1 image).
    static let fixtures: [Fixture] = [
        Fixture(id: "post-0000", title: "Dense — video", detail: "18 reactions + 6 sentences: ticker and subtitles"),
        Fixture(id: "post-0004", title: "Dense — image", detail: "18 reactions + 6 sentences: ticker and subtitles"),
        Fixture(id: "post-0001", title: "Sparse — image", detail: "Two comments"),
        Fixture(id: "post-0012", title: "Reactions only — video", detail: "W, 🔥🔥, GG: under the ticker's gate"),
        Fixture(id: "post-0013", title: "Reactions only — image", detail: "W, 🔥🔥, GG: under the ticker's gate"),
        Fixture(id: "post-0009", title: "Empty — video", detail: "No comments yet"),
        Fixture(id: "post-0010", title: "Empty — image", detail: "No comments yet"),
    ]

    /// The sandbox, opening where `arguments` say.
    @MainActor
    static func make(feed: any FeedFeatureBuilding, arguments: [String]) -> UIViewController {
        let opening = arguments.firstIndex(of: argument)
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            .flatMap { $0.hasPrefix("-") ? nil : $0 }

        let shots = UINavigationController(rootViewController: feed.makeForYouFullScreenFeedViewController())
        let posts = CommentsSandboxPostsViewController(fixtures: fixtures) { ids in
            let post = feed.makeSnapFeedViewController(
                postIDs: ids.map { PostID($0) }, ownsInteractiveDismissal: false, sourceIsComplete: true
            )
            // The app's tab bar is down under a full-screen post.
            post.hidesBottomBarWhenPushed = true
            return post
        }
        let postsStack = UINavigationController(rootViewController: posts)

        // `UITab`s, not tab bar items: a screen's own `title` ("Timeline")
        // would rename its tab.
        let shotsTab = UITab(title: "Shots", image: UIImage(systemName: "play.rectangle"), identifier: "shots") { _ in shots }
        let postTab = UITab(title: "Post", image: UIImage(systemName: "rectangle.portrait"), identifier: "post") { _ in
            postsStack
        }
        let tabs = UITabBarController(tabs: [shotsTab, postTab])
        tabs.modalPresentationStyle = .fullScreen
        switch opening {
        case nil, "shots"?:
            tabs.selectedTab = shotsTab
        case "post"?:
            tabs.selectedTab = postTab
        case let id?:
            tabs.selectedTab = postTab
            posts.open(id, animated: false)
        }
        return tabs
    }
}

/// The Post tab's root: the fixtures, each opening the full-screen feed on
/// its post — the others after it, then those before, a swipe away.
final class CommentsSandboxPostsViewController: UITableViewController {
    private let fixtures: [CommentsSandbox.Fixture]
    private let makeFeed: ([String]) -> UIViewController

    init(fixtures: [CommentsSandbox.Fixture], makeFeed: @escaping ([String]) -> UIViewController) {
        self.fixtures = fixtures
        self.makeFeed = makeFeed
        super.init(style: .insetGrouped)
        title = "Comments sandbox"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "fixture")
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.tabBarController?.closePresentation()
        })
    }

    /// Opens the feed on `id`; a post outside the fixtures opens alone.
    func open(_ id: String, animated: Bool) {
        let ids: [String]
        if let index = fixtures.firstIndex(where: { $0.id == id }) {
            ids = fixtures[index...].map(\.id) + fixtures[..<index].map(\.id)
        } else {
            ids = [id]
        }
        navigationController?.pushViewController(makeFeed(ids), animated: animated)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        fixtures.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Media posts (mock)"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "fixture", for: indexPath)
        let fixture = fixtures[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = fixture.title
        content.secondaryText = "\(fixture.id) · \(fixture.detail)"
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        open(fixtures[indexPath.row].id, animated: true)
    }
}
#endif
