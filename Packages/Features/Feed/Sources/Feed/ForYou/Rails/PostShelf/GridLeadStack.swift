import DesignSystem
import UIKit

/// A section that can lead a grid page's list (`ForYouGridPage.setLead`):
/// it says how tall it is at a width, zero when it has nothing to show, and
/// when that may have changed.
@MainActor
protocol GridLeadSection: UIView {
    func preferredHeight(forWidth width: CGFloat) -> CGFloat
    var onHeightChange: (() -> Void)? { get set }
}

/// What leads a grid page's list (#1271): its sections stacked, then the
/// list's own title, a way in like theirs.
///
/// ```
///     Popular ›                ← a section (a `PostShelfSection`)
///   ┌──────┐ ┌──────┐ ┌───
///   └──────┘ └──────┘ └───
///     Recent ›                 ← the list's title
///   ─── the list ─────────
/// ```
///
/// A section with nothing to show takes no room; with none shown, the stack
/// is zero tall and the title is not drawn either — alone at the top of the
/// screen it would title the only thing there. The gaps are the app's ONE
/// section gap (`ForYouRailsView.Metrics.rowGap`) between sections and before
/// the title, and the title's own (`listGap`) before the list.
///
/// Hosted as the list's LEADING HEADER, never as sections of its own — see
/// `ForYouRailsView` for why. The host owns the stack (the page holds its
/// lead weakly) and re-sizes the lead on `onHeightChange`.
@MainActor
final class GridLeadStack: UIView {
    let sections: [any GridLeadSection]
    private let listTitleView = SectionTitleView(content: .init(title: "", isLink: true))

    /// The list's title.
    var listTitle = "" {
        didSet { listTitleView.content = .init(title: listTitle, isLink: true) }
    }
    /// The list's title was tapped: the host pushes the whole list.
    var onListTitleTapped: (() -> Void)? {
        didSet { listTitleView.onTap = onListTitleTapped }
    }
    var listTitleAccessibilityHint: String? {
        get { listTitleView.accessibilityHint }
        set { listTitleView.accessibilityHint = newValue }
    }
    /// A section changed how tall it is — the host re-sizes the lead.
    var onHeightChange: (() -> Void)?

    init(sections: [any GridLeadSection]) {
        self.sections = sections
        super.init(frame: .zero)
        for section in sections {
            addSubview(section)
            section.onHeightChange = { [weak self] in
                self?.setNeedsLayout()
                self?.onHeightChange?()
            }
        }
        addSubview(listTitleView)
        listTitleView.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The height the stack needs at `width`.
    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        Self.height(sections: sections.map { $0.preferredHeight(forWidth: width) })
    }

    /// The stack's height for sections of these heights: the shown ones with
    /// a gap between, then the list's title — nothing at all with none shown.
    static func height(sections: [CGFloat]) -> CGFloat {
        let shown = sections.filter { $0 > 0 }
        guard !shown.isEmpty else { return 0 }
        let gap = ForYouRailsView.Metrics.rowGap
        return shown.reduce(0, +) + gap * CGFloat(shown.count - 1)
            + gap + SectionTitleView.Metrics.height + ForYouRailsView.Metrics.listGap
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let gap = ForYouRailsView.Metrics.rowGap
        var y: CGFloat = 0
        var anyShown = false
        for section in sections {
            let height = section.preferredHeight(forWidth: width)
            section.isHidden = height == 0
            guard height > 0 else { continue }
            if anyShown { y += gap }
            section.frame = CGRect(x: 0, y: y, width: width, height: height)
            y += height
            anyShown = true
        }
        listTitleView.isHidden = !anyShown
        guard anyShown else { return }
        listTitleView.frame = CGRect(
            x: 0, y: y + gap, width: width, height: SectionTitleView.Metrics.height
        )
    }

    #if DEBUG
    var debugListTitleView: SectionTitleView { listTitleView }
    #endif
}

extension PostShelfSection: GridLeadSection {}
