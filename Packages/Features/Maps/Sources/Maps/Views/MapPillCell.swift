import UIKit

/// One filter pill inside a bar's collection view: a `MapPillButton` hosted
/// non-interactively (the collection view owns taps, selection, and context
/// menus — the pill is pure presentation). The cell self-sizes from the
/// pill's intrinsic width, so compositional `.estimated` items land exactly
/// on the content-determined widths the bars guarantee.
///
/// Reuse & glass: the pill is created once per cell and kept across
/// reconfigures (`setContent` swaps identity), so the Liquid Glass material
/// is materialized once on window attach — reuse never re-contacts the
/// render server (the CI doctrine survives recycling).
final class MapPillCell: UICollectionViewCell {
    private var pill: MapPillButton?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Glass halos bleed past the pill's bounds — nothing may clip.
        clipsToBounds = false
        contentView.clipsToBounds = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(content: MapPillButton.Content, height: CGFloat, selected: Bool) {
        let pill = existingPill(height: height, initialContent: content)
        pill.setContent(content)
        pill.setSelectedAppearance(selected)
    }

    /// Routes a resolved avatar to the pill (owner calls after async load).
    func setAvatar(_ image: UIImage?) {
        pill?.setAvatar(image)
    }

    private func existingPill(height: CGFloat, initialContent: MapPillButton.Content) -> MapPillButton {
        if let pill { return pill }
        let pill = MapPillButton(content: initialContent, height: height)
        pill.isUserInteractionEnabled = false
        pill.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            pill.topAnchor.constraint(equalTo: contentView.topAnchor),
            pill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        self.pill = pill
        return pill
    }
}

/// The sticky "All" header: a boundary supplementary hosting the All pill.
/// Interactive (unlike cells) — supplementaries sit outside item selection,
/// so the pill itself takes the tap and reports through `onTap`.
final class MapAllHeaderView: UICollectionReusableView {
    var onTap: (() -> Void)?
    private var pill: MapPillButton?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        // Pinned headers float over cells; make the stacking explicit so the
        // duck-fade never renders a pill above the header.
        layer.zPosition = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(content: MapPillButton.Content, height: CGFloat, selected: Bool) {
        let pill = existingPill(height: height, initialContent: content)
        pill.setContent(content)
        pill.setSelectedAppearance(selected)
    }

    private func existingPill(height: CGFloat, initialContent: MapPillButton.Content) -> MapPillButton {
        if let pill { return pill }
        let pill = MapPillButton(content: initialContent, height: height)
        pill.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: MapFilterBarView.pillHeight)
        ])
        self.pill = pill
        return pill
    }
}
