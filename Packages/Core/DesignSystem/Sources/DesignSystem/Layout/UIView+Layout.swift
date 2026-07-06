import UIKit

/// The app-wide layout micro-DSL over native `NSLayoutAnchor`.
/// This replaces third-party constraint libraries: it batch-activates
/// constraints and handles `translatesAutoresizingMaskIntoConstraints`.
///
/// Note: hot scrolling cells should prefer manual frame layout in
/// `layoutSubviews` with precomputed sizes; anchors are for everything else.
extension UIView {
    /// Adds the view to `parent` and activates the constraints built in `constraints`.
    public func constrain(
        in parent: UIView,
        @LayoutConstraintsBuilder _ constraints: (UIView) -> [NSLayoutConstraint]
    ) {
        parent.addSubview(self)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate(constraints(parent))
    }

    /// Pins all four edges to `parent`, optionally to its layout margins or safe area.
    public func pin(
        to parent: UIView,
        insets: NSDirectionalEdgeInsets = .zero,
        relativeTo reference: LayoutReference = .edges
    ) {
        parent.addSubview(self)
        translatesAutoresizingMaskIntoConstraints = false
        let anchors = reference.anchors(of: parent)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: anchors.leading, constant: insets.leading),
            topAnchor.constraint(equalTo: anchors.top, constant: insets.top),
            trailingAnchor.constraint(equalTo: anchors.trailing, constant: -insets.trailing),
            bottomAnchor.constraint(equalTo: anchors.bottom, constant: -insets.bottom)
        ])
    }
}

public enum LayoutReference {
    case edges
    case safeArea
    case margins

    @MainActor
    func anchors(of view: UIView) -> (
        leading: NSLayoutXAxisAnchor,
        top: NSLayoutYAxisAnchor,
        trailing: NSLayoutXAxisAnchor,
        bottom: NSLayoutYAxisAnchor
    ) {
        switch self {
        case .edges:
            (view.leadingAnchor, view.topAnchor, view.trailingAnchor, view.bottomAnchor)
        case .safeArea:
            (
                view.safeAreaLayoutGuide.leadingAnchor,
                view.safeAreaLayoutGuide.topAnchor,
                view.safeAreaLayoutGuide.trailingAnchor,
                view.safeAreaLayoutGuide.bottomAnchor
            )
        case .margins:
            (
                view.layoutMarginsGuide.leadingAnchor,
                view.layoutMarginsGuide.topAnchor,
                view.layoutMarginsGuide.trailingAnchor,
                view.layoutMarginsGuide.bottomAnchor
            )
        }
    }
}

@resultBuilder
public enum LayoutConstraintsBuilder {
    public static func buildBlock(_ components: NSLayoutConstraint...) -> [NSLayoutConstraint] {
        components
    }

    public static func buildArray(_ components: [[NSLayoutConstraint]]) -> [NSLayoutConstraint] {
        components.flatMap(\.self)
    }
}
