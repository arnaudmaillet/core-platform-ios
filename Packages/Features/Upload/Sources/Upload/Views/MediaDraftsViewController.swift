import DesignSystem
import UIKit

/// The posts the viewer started and kept, pushed from the picker's "Drafts"
/// button.
///
/// ⚠️ EMPTY UNTIL A MEDIA DRAFT IS A THING. `PostDraftStore` holds text and a
/// timestamp — a draft of a post with media would have to remember which assets
/// were chosen and in what order, which is a store this app does not have yet.
/// The button and its screen ship now so the picker's chrome is whole, and the
/// user's decision of 2026-09-12 was exactly that: the list arrives with the
/// step that can save into it.
final class MediaDraftsViewController: UIViewController {
    private let emptyState = EmptyStateView()

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Drafts"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        emptyState.configure(
            symbolName: "photo.on.rectangle.angled",
            title: "No drafts",
            subtitle: "Posts you save as drafts will appear here."
        )
        emptyState.isUserInteractionEnabled = false
        emptyState.pin(to: view)
    }
}
