import DesignSystem
import MediaCore
import UIKit

/// The carousel's pages as a filmstrip IN PLACE of the segment strip while a
/// finger slides along it (#1734) — Kuaishou's quick browse, which the owner
/// asked for as is (2026-10-25, after a first version with small tiles over
/// the segments): the segments step aside, a row of portrait previews takes
/// their line, the page under the finger drawn larger with a white edge, and
/// "4 / 14" centred under the row.
///
/// ⚠️ THE ROW IS CONTIGUOUS AND WIDER THAN THE SCREEN, and the chosen tile
/// stands under the finger. Tiles on equal slots of the strip's width (the
/// first version) were too small to read and still overlapped at twelve
/// pages. Here every tile keeps a legible size and the row slides: the chosen
/// tile is centred on the finger's slot (`anchorX`), its neighbours packed
/// either side of it, running off the edges when there are many.
///
/// The view spans the chrome's width; the chrome places it so the counter sits
/// on the strip's line (`SnapChromeView.placeBrowseStrip`).
final class SnapBrowseStripView: UIView {
    /// A tile at rest, portrait like the reference's.
    static let tileSize = CGSize(width: 36, height: 50)
    /// The chosen tile: larger, on the same centre line.
    static let selectedTileSize = CGSize(width: 44, height: 61)
    static let tileGap: CGFloat = 4
    static let selectedBorder: CGFloat = 2
    /// The room between the row and the counter.
    static let counterGap: CGFloat = 10
    static let counterHeight: CGFloat = 18
    /// How long the row takes to slide to the next page.
    static let selectionDuration: TimeInterval = 0.15
    static let fadeDuration: TimeInterval = 0.15

    /// The strip's height: the chosen tile, the gap, the counter.
    static var height: CGFloat { selectedTileSize.height + counterGap + counterHeight }

    private var tiles: [UIImageView] = []
    private var videoMarks: [UIImageView] = []
    private var loads: [Task<Void, Never>] = []
    private(set) var selectedPage = 0
    /// Where the chosen tile's centre goes, in this view's space.
    private var anchorX: CGFloat = 0
    private let counter: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        alpha = 0
        isHidden = true
        addSubview(counter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The pages' previews: their thumbnails, and which pages are clips.
    func configure(thumbnails: [URL?], videoPages: Set<Int>, pipeline: ImagePipeline?) {
        loads.forEach { $0.cancel() }
        loads = []
        tiles.forEach { $0.removeFromSuperview() }
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
        selectedPage = min(selectedPage, max(thumbnails.count - 1, 0))
        updateCounter()
        setNeedsLayout()
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

    func show(selecting page: Int, anchorX: CGFloat) {
        selectedPage = page
        self.anchorX = anchorX
        updateCounter()
        layoutTiles()
        guard isHidden || alpha < 1 else { return }
        isHidden = false
        UIView.animate(withDuration: Self.fadeDuration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = 1
        }
    }

    /// The finger chose `page`, whose slot is centred at `anchorX`: the row
    /// slides to put that tile there.
    func select(_ page: Int, anchorX: CGFloat) {
        guard page != selectedPage || anchorX != self.anchorX else { return }
        selectedPage = page
        self.anchorX = anchorX
        updateCounter()
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

    /// "4 / 14": the page in white, the count dimmer.
    private func updateCounter() {
        guard !tiles.isEmpty else { counter.attributedText = nil; return }
        let font = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        let text = NSMutableAttributedString(
            string: "\(selectedPage + 1)", attributes: [.font: font, .foregroundColor: UIColor.white]
        )
        text.append(NSAttributedString(
            string: " / \(tiles.count)",
            attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .regular),
                         .foregroundColor: UIColor.white.withAlphaComponent(0.6)]
        ))
        counter.attributedText = text
    }

    /// The chosen tile centred on `anchorX`, the others packed either side,
    /// every tile on the row's centre line; the counter centred under the row.
    private func layoutTiles() {
        let rowMidY = Self.selectedTileSize.height / 2
        counter.frame = CGRect(
            x: 0, y: Self.selectedTileSize.height + Self.counterGap,
            width: bounds.width, height: Self.counterHeight
        )
        guard !tiles.isEmpty else { return }
        let rest = Self.tileSize
        let chosen = Self.selectedTileSize
        for (index, tile) in tiles.enumerated() {
            let offset = index - selectedPage
            let x: CGFloat
            if offset == 0 {
                x = anchorX
            } else {
                // From the chosen tile's edge, whole resting tiles outward.
                let side: CGFloat = offset > 0 ? 1 : -1
                let steps = CGFloat(abs(offset))
                x = anchorX + side * (chosen.width / 2 + Self.tileGap + rest.width / 2
                    + (steps - 1) * (rest.width + Self.tileGap))
            }
            let size = offset == 0 ? chosen : rest
            // bounds + centre: the chosen tile's growth animates as a size.
            tile.bounds = CGRect(origin: .zero, size: size)
            tile.center = CGPoint(x: x, y: rowMidY)
            tile.layer.cornerRadius = offset == 0 ? 6 : 4
            tile.layer.borderWidth = offset == 0 ? Self.selectedBorder : 0
            let mark = videoMarks[index]
            let side = min(offset == 0 ? 16 : 12, size.width / 2)
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
    var debugCounterText: String? { counter.attributedText?.string }
    var debugCounterFrame: CGRect { counter.frame }
    #endif
}
