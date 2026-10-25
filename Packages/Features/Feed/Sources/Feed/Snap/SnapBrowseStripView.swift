import DesignSystem
import MediaCore
import UIKit

/// The carousel's pages as a row of previews over the segment strip, while a
/// finger slides along it (#1734, the owner 2026-10-25, after another app's
/// filmstrip): one tile per page, the page under the finger enlarged.
///
/// ⚠️ EACH TILE STANDS ON ITS PAGE'S BROWSING SLOT, not on its drawn segment.
/// The strip cuts its run into equal slots to read the finger
/// (`SnapMediaPageBarView.browsePage(atX:)`) because the drawn segments reflow
/// as the page changes; tiles on those same slots keep the tile under the
/// finger the page the finger picks.
///
/// The view is the strip's width and sits right above it; the chrome places
/// it (`SnapChromeView.placeBrowseStrip`).
final class SnapBrowseStripView: UIView {
    /// A tile's widest, and its shape (width / height): portrait, like most
    /// of what a carousel holds.
    static let maxTileWidth: CGFloat = 34
    static let tileAspect: CGFloat = 3.0 / 4.0
    /// How much larger the page under the finger is drawn.
    static let selectedScale: CGFloat = 1.5
    /// The room between two tiles at the least.
    static let tileGap: CGFloat = 3
    /// How long the enlarged tile takes to move to the next page.
    static let selectionDuration: TimeInterval = 0.15
    static let fadeDuration: TimeInterval = 0.15

    private var tiles: [UIImageView] = []
    private var videoMarks: [UIImageView] = []
    private var loads: [Task<Void, Never>] = []
    private(set) var selectedPage = 0
    /// Each page's slot centre and the slot's width, in this view's space.
    private var slotCenters: [CGFloat] = []
    private var slotWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        alpha = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The height the strip needs: an enlarged tile.
    static func height(slotWidth: CGFloat) -> CGFloat {
        tileSize(slotWidth: slotWidth).height * selectedScale
    }

    /// A tile at rest, for a slot `slotWidth` wide.
    static func tileSize(slotWidth: CGFloat) -> CGSize {
        let width = max(min(maxTileWidth, slotWidth - tileGap), 4)
        return CGSize(width: width, height: (width / tileAspect).rounded())
    }

    /// The pages' previews: their thumbnails, and which pages are clips.
    func configure(thumbnails: [URL?], videoPages: Set<Int>, pipeline: ImagePipeline?) {
        loads.forEach { $0.cancel() }
        loads = []
        tiles.forEach { $0.removeFromSuperview() }
        videoMarks.forEach { $0.removeFromSuperview() }
        tiles = thumbnails.indices.map { _ in
            let tile = UIImageView()
            tile.contentMode = .scaleAspectFill
            tile.clipsToBounds = true
            tile.backgroundColor = UIColor.white.withAlphaComponent(0.18)
            tile.layer.cornerCurve = .continuous
            tile.layer.borderColor = UIColor.white.cgColor
            addSubview(tile)
            return tile
        }
        videoMarks = thumbnails.indices.map { index in
            let mark = UIImageView(image: UIImage(systemName: "play.fill"))
            mark.tintColor = .white
            mark.contentMode = .scaleAspectFit
            mark.isHidden = !videoPages.contains(index)
            mark.layer.shadowColor = UIColor.black.cgColor
            mark.layer.shadowOpacity = 0.5
            mark.layer.shadowRadius = 2
            mark.layer.shadowOffset = .zero
            tiles[index].addSubview(mark)
            return mark
        }
        guard let pipeline else { return }
        for (index, url) in thumbnails.enumerated() {
            guard let url else { continue }
            if let image = pipeline.cachedImage(for: url, size: .px256) ?? pipeline.cachedImage(for: url) {
                tiles[index].image = image
                continue
            }
            loads.append(Task { @MainActor [weak self] in
                guard let image = try? await pipeline.image(for: url, size: .px256) else { return }
                guard let self, !Task.isCancelled, self.tiles.indices.contains(index) else { return }
                self.tiles[index].image = image
            })
        }
    }

    /// Puts the tiles on the strip's slots: `centers` in this view's space,
    /// one per page.
    func setSlots(centers: [CGFloat], width: CGFloat) {
        slotCenters = centers
        slotWidth = width
        layoutTiles()
    }

    func show(selecting page: Int) {
        selectedPage = page
        layoutTiles()
        guard isHidden || alpha < 1 else { return }
        isHidden = false
        UIView.animate(withDuration: Self.fadeDuration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = 1
        }
    }

    func select(_ page: Int) {
        guard page != selectedPage else { return }
        selectedPage = page
        guard window != nil, UIView.areAnimationsEnabled else { return layoutTiles() }
        UIView.animate(
            withDuration: Self.selectionDuration, delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
        ) { self.layoutTiles() }
    }

    func hide(animated: Bool = true) {
        guard !isHidden else { return }
        guard animated else {
            layer.removeAllAnimations()
            alpha = 0
            isHidden = true
            return
        }
        UIView.animate(withDuration: Self.fadeDuration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = 0
        } completion: { [weak self] finished in
            guard finished, let self, self.alpha == 0 else { return }
            self.isHidden = true
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutTiles()
    }

    /// Every tile on its slot, resting on the strip's bottom; the selected one
    /// enlarged upward from there.
    private func layoutTiles() {
        guard tiles.count == slotCenters.count, slotWidth > 0 else { return }
        let rest = Self.tileSize(slotWidth: slotWidth)
        for (index, tile) in tiles.enumerated() {
            let selected = index == selectedPage
            let scale = selected ? Self.selectedScale : 1
            let size = CGSize(width: rest.width * scale, height: rest.height * scale)
            // bounds + centre: the selected tile's growth animates as a size.
            tile.bounds = CGRect(origin: .zero, size: size)
            tile.center = CGPoint(x: slotCenters[index], y: bounds.height - size.height / 2)
            tile.layer.cornerRadius = 4 * scale
            tile.layer.borderWidth = selected ? 1.5 : 0
            tile.alpha = selected ? 1 : 0.7
            let mark = videoMarks[index]
            let side = min(10 * scale, size.width / 2)
            mark.frame = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
        }
    }

    #if DEBUG
    /// A tile's frame in this view's space. Tests.
    func debugTileFrame(_ page: Int) -> CGRect? {
        guard tiles.indices.contains(page) else { return nil }
        let tile = tiles[page]
        return CGRect(
            x: tile.center.x - tile.bounds.width / 2, y: tile.center.y - tile.bounds.height / 2,
            width: tile.bounds.width, height: tile.bounds.height
        )
    }
    var debugTileCount: Int { tiles.count }
    var debugIsShown: Bool { !isHidden && alpha > 0 }
    #endif
}
