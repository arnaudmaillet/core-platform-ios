import UIKit

/// The clear root of a navigation stack a feed is pushed onto from INSIDE A
/// SHEET — the wallet's stakes, the sound sheet's posts.
///
/// ⚠️ **OVER THE SHEET, NOT INSIDE IT.** The feed flies with a navigation
/// push, and a sheet's own stack would keep the feed in the sheet's shape;
/// dismissing the sheet first would take away the tile the hero flies from.
/// So this stack is presented over the sheet, full screen, clear and without
/// animation, the feed is pushed onto it, and the flight measures the tile
/// through it — the sheet stays visible underneath for the whole trip, both
/// ways. It takes the stack away, unanimated, once the feed has been popped
/// back to it.
public final class OverSheetFeedHost: UIViewController {
    private var hasShownFeed = false
    private var onFinished: (() -> Void)?

    /// Presents a host over `sheet` and hands it to `open`, which pushes the
    /// feed onto it. `onFinished` runs when the feed has flown home and the
    /// host is gone.
    public static func present(
        over sheet: UIViewController,
        onFinished: (() -> Void)? = nil,
        open: @escaping (UIViewController) -> Void
    ) {
        let host = OverSheetFeedHost()
        host.onFinished = onFinished
        let stack = UINavigationController(rootViewController: host)
        // ⚠️ THE BAR STAYS, transparent and empty on the host: the feed pushed
        // onto this stack draws its back button and author pill in it. A hidden
        // bar is inherited by the push, and the feed arrived with no way back
        // but the grab.
        stack.modalPresentationStyle = .overFullScreen
        stack.view.backgroundColor = .clear
        sheet.present(stack, animated: false) { [weak host] in
            guard let host else { return }
            open(host)
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let clear = UINavigationBarAppearance()
        clear.configureWithTransparentBackground()
        navigationItem.standardAppearance = clear
        navigationItem.scrollEdgeAppearance = clear
        navigationItem.compactAppearance = clear
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Covered by the feed's push.
        if navigationController?.topViewController !== self { hasShownFeed = true }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Back on top after the feed: the trip is over.
        guard hasShownFeed else { return }
        let finished = onFinished
        onFinished = nil
        navigationController?.presentingViewController?.dismiss(animated: false) { finished?() }
    }
}
