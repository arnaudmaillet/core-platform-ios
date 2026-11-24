import CoreModels
import CoreStorage
import PostGrid
import ThreadKit
import UIKit

/// What the composer's boost asks of its panel (#2523): the composer, the
/// post, whether the post's actions still show, and the panel's notices.
@MainActor
protocol PostDetailComposerBoostHost: UIViewController {
    var composeBar: CommentsInputBar { get }
    var viewModel: PostDetailViewModel { get }
    var showsPostActions: Bool { get }
    func presentNotice(_ title: String, _ message: String)
}

/// The stakes a comments panel's composer spends through (#2532).
enum PostDetailStakes {
    /// The panel's own session: it ends it when it leaves the screen.
    case own(StakeSession)
    /// The session of the Snap page that embeds the panel (one burst and one
    /// toast for the post on that page): the page's to end.
    case page(StakeSession)

    var session: StakeSession {
        switch self {
        case .own(let session), .page(let session): session
        }
    }
}

/// The composer's boost, wired to the panel's stake session (#2523, #2532).
/// The session owns the spend, its receipts on the bar, the stake toast that
/// is the burst's undo window (#957, #1375), the undo and the commit; this
/// says which post the bar stakes on, when the post can take a stake, and
/// what a draft says instead.
///
/// ⚠️ SYNCHRONOUS WITH ITS PANEL: every entry point runs in the caller's
/// turn, where the panel ran it before. The panel alone holds it.
@MainActor
final class PostDetailComposerBoost {
    private unowned let host: any PostDetailComposerBoostHost
    /// The stakes the bar spends through. Nil leaves the button visible but
    /// inert.
    private let owner: PostDetailStakes?
    private var stakes: StakeSession? { owner?.session }

    init(host: any PostDetailComposerBoostHost, stakes: PostDetailStakes?) {
        self.host = host
        owner = stakes
    }

    /// The panel left the screen: a burst with no toast is sent now (#676);
    /// one whose toast is up stays undoable until it ends (#1375). A page's
    /// session is the page's to end.
    func end() {
        if case .own(let session) = owner { session.end() }
    }

    /// The bar wears the post's stake — nothing on a draft, which is not a
    /// post yet: `install`, and again once the draft is published.
    func bindStake() {
        guard let stakes, let postID = host.viewModel.postID else { return }
        stakes.bind(host.composeBar, to: postID)
    }

    /// Wires the bar's boost button and its Undo entry: `configureComposeBar`,
    /// once.
    func install() {
        host.composeBar.onBoost = { [weak self] spend in self?.boost(spend) }
        host.composeBar.onBoostUndo = { [weak self] in
            guard let self, let postID = host.viewModel.postID else { return }
            stakes?.undo(on: postID, from: host.composeBar)
        }
        bindStake()
    }

    private func boost(_ spend: WalletStakeSpend) {
        guard let stakes else { return }
        // A DRAFT is not a post yet, and a boost has nothing to land on —
        // said, rather than spent against an id that does not exist.
        guard let postID = host.viewModel.postID else {
            return host.presentNotice("Boost", "You can boost your post once it's published.")
        }
        // A sign-up that finished after the post went unavailable (#1404)
        // has nothing left to boost.
        stakes.stake(spend, on: postID, from: host.composeBar, lands: { [weak host] in
            host?.showsPostActions ?? false
        })
    }
}

extension PostDetailViewController: PostDetailComposerBoostHost {}
