import UIKit

/// A row action under way (#1775): unblock, unmute, restore — an action that
/// removes its row once the server agrees. The row says so at its trailing
/// edge with the kit's loader, after its grace (`LoaderGate`), then leaves —
/// or comes back as it was, with the error. Never a row that sits unchanged
/// until an alert.
public extension UICellAccessory {
    static func busy() -> UICellAccessory {
        .customView(configuration: .init(
            customView: RowBusyView(), placement: .trailing(), reservedLayoutWidth: .actual
        ))
    }
}

/// The accessory's view: a small loader that starts its grace when it is on
/// screen and stops when it leaves. Public for a row that is not a list
/// cell — a `UITableViewCell`'s `accessoryView` (#1775).
public final class RowBusyView: UIView {
    private let loader = AppLoaderView(size: .medium)
    private lazy var gate = LoaderGate(loader: loader)

    public init() {
        super.init(frame: CGRect(origin: .zero, size: loader.intrinsicContentSize))
        isUserInteractionEnabled = false
        loader.hidesWhenStopped = true
        loader.constrain(in: self) { parent in
            loader.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            loader.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        isAccessibilityElement = true
        accessibilityLabel = "In progress"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var intrinsicContentSize: CGSize { loader.intrinsicContentSize }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        window != nil ? gate.begin() : gate.cancel()
    }
}
