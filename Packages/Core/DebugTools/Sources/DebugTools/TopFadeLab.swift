#if DEBUG
import DesignSystem
import UIKit

/// `-top-fade-lab`: measures where UIKit's soft top-edge fade really ends
/// (#2286). A titled header over a uniform checkerboard that runs under the
/// bar: where the squares are sharp again is the fade's end, read off a
/// screenshot (`dev/scripts` has no reader; the PR states the numbers).
///
/// - `-top-fade-lab-header inline|search|large`: an inline title with bar
///   buttons; the same with a search field stacked under it (the inbox); a
///   large title folded into the bar (scrolled).
/// - `-top-fade-lab-dark`: the dark appearance.
/// - `-top-fade-lab-scroll <pt>`: how far past its rest the list sits.
/// - `-top-fade-lab-square <pt>`: the squares' side (2 by default; 4 to 8
///   read closer to text, whose strokes are lower in frequency).
/// - `-top-fade-trace` prints the edge-effect views' frames as well.
@MainActor
public enum TopFadeLab {
    public static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-top-fade-lab") }

    public static func makeRoot() -> UIViewController {
        let lab = TopFadeLabViewController(header: UserDefaults.standard.string(forKey: "top-fade-lab-header") ?? "inline")
        let navigation = UINavigationController(rootViewController: lab)
        if ProcessInfo.processInfo.arguments.contains("-top-fade-lab-dark") {
            navigation.overrideUserInterfaceStyle = .dark
        }
        return navigation
    }
}

@MainActor
private final class TopFadeLabViewController: UIViewController {
    private let header: String
    private let scrollView = UIScrollView()
    /// One side of a square, in points: small enough that the fade's ramp
    /// shows square by square, large enough to stay crisp at 3×.
    private let square: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: "top-fade-lab-square")
        return stored > 0 ? stored : 2
    }()

    public init(header: String) {
        self.header = header
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "Followers"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "chevron.left"), style: .plain,
                                                           target: nil, action: nil)
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), style: .plain,
                                                            target: nil, action: nil)
        switch header {
        case "search":
            let search = UISearchController(searchResultsController: nil)
            navigationItem.searchController = search
            navigationItem.preferredSearchBarPlacement = .stacked
            navigationItem.hidesSearchBarWhenScrolling = false
            navigationItem.largeTitleDisplayMode = .never
        case "large":
            navigationController?.navigationBar.prefersLargeTitles = true
            navigationItem.largeTitleDisplayMode = .always
        default:
            navigationItem.largeTitleDisplayMode = .never
        }

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        // The pattern runs well above the content's top, so it fills the bar
        // and its fade at rest, wherever the inset puts the content.
        let pattern = UIView(frame: CGRect(x: 0, y: -800, width: view.bounds.width, height: 4000))
        pattern.autoresizingMask = [.flexibleWidth]
        pattern.backgroundColor = UIColor(patternImage: checkerboard())
        scrollView.addSubview(pattern)
        scrollView.contentSize = CGSize(width: view.bounds.width, height: 3000)
        scrollView.applyTopEdge(for: .titled)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // `-top-fade-lab-scroll <pt>`: how far past its rest the list sits
        // (UIKit shows the effect only once content has scrolled under the
        // bar). A large title only meets the fade once folded: 200 by default.
        let stored = UserDefaults.standard.double(forKey: "top-fade-lab-scroll")
        let scrolled: CGFloat = stored != 0 ? stored : (header == "large" ? 200 : 0)
        scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top + scrolled), animated: false)
        NSLog("[top-fade-lab] safeTop=\(scrollView.safeAreaInsets.top) adjustedTop=\(scrollView.adjustedContentInset.top) "
            + "scrolled=\(scrolled)")
    }

    /// Black and white squares: the same full contrast in both appearances.
    private func checkerboard() -> UIImage {
        let side: CGFloat = square * 2
        let format = UIGraphicsImageRendererFormat()
        format.scale = traitCollection.displayScale
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: square, height: square))
            context.fill(CGRect(x: square, y: square, width: square, height: square))
        }
    }
}
#endif
