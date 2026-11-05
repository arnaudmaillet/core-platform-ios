#if DEBUG
import CoreNavigation
import UIKit

/// `-latency-bench` (#2116): UIKit's own floor for each kind of response,
/// measured with `-interaction-latency` and real taps — a tab, a push, a
/// sheet, a full-screen cover, an alert, a menu — on screens that hold
/// nothing of the app's. A response that costs the same in the app is the
/// system's; the difference is ours.
///
/// The shell is the app's (a `UITabBarController` with the UITab API, two
/// tabs, a navigation stack each), so the tab and the push pay the same
/// chrome; the screens are empty.
enum LatencyBench {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-latency-bench") }

    static func makeRoot() -> UIViewController {
        let tabs = UITabBarController()
        tabs.tabs = [
            UITab(title: "Bench", image: UIImage(systemName: "stopwatch"), identifier: "bench") { _ in
                UINavigationController(rootViewController: LatencyBenchViewController(title: "Bench"))
            },
            UITab(title: "Other", image: UIImage(systemName: "square"), identifier: "other") { _ in
                UINavigationController(rootViewController: LatencyBenchViewController(title: "Other"))
            },
        ]
        return tabs
    }
}

/// One empty screen with the bench's buttons; every screen it opens is
/// another of these, so each can open the next and close itself.
final class LatencyBenchViewController: UIViewController {
    init(title: String) {
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let stack = UIStackView(arrangedSubviews: [
            button("Push") { [weak self] in
                self?.navigationController?.pushViewController(LatencyBenchViewController(title: "Pushed"), animated: true)
            },
            button("Sheet") { [weak self] in
                let sheet = LatencyBenchViewController(title: "Sheet")
                sheet.sheetPresentationController?.detents = [.medium()]
                self?.present(sheet, animated: true)
            },
            button("Full screen") { [weak self] in
                let cover = LatencyBenchViewController(title: "Cover")
                cover.modalPresentationStyle = .fullScreen
                self?.present(cover, animated: true)
            },
            button("Alert") { [weak self] in
                let alert = UIAlertController(title: "Bench", message: nil, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(alert, animated: true)
            },
            menuButton(),
            button("Close") { [weak self] in
                guard let self else { return }
                if presentingViewController != nil {
                    dismiss(animated: true)
                } else {
                    navigationController?.popViewController(animated: true)
                }
            },
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
        ])
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.bordered()
        configuration.title = title
        return UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    }

    private func menuButton() -> UIButton {
        var configuration = UIButton.Configuration.bordered()
        configuration.title = "Menu"
        let button = UIButton(configuration: configuration)
        // A choice shows as the button's subtitle: the menu's own response
        // is what is measured, the row's is only there to do something.
        let choose: UIActionHandler = { [weak button] action in
            button?.configuration?.subtitle = action.title
        }
        button.menu = UIMenu(children: ["One", "Two", "Three"].map { UIAction(title: $0, handler: choose) })
        button.showsMenuAsPrimaryAction = true
        return button
    }
}
#endif
