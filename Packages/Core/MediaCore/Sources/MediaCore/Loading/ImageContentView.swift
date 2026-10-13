import DesignSystem
import UIKit

/// A picture arriving, on the loading ladder (#1085): an optional bone or
/// placeholder, then the picture decoded at its bucket — the one place the
/// app writes "cache first, else a task, then a dissolve".
///
/// ```
///   skeleton (optional) → placeholder (optional) → picture
///   a warm hit draws in the configure pass; a late one dissolves in 0.25 s
/// ```
///
/// ⚠️ **THE SIZE BUCKET IS REQUIRED.** There is no `.full` default here: a
/// view that decodes a 1200 px picture for a 40 pt slot holds forty times the
/// memory it shows (#894, #1086). Say the size the view draws at.
///
/// ⚠️ **NOT FOR THE HERO'S SOURCES YET.** The tiles, rows, carousel, flight
/// cards, snap cards and map pins keep their covers until the media surface
/// (#1088) moves them, on this same ladder and its hero hooks.
@MainActor
public final class ImageContentView: UIView {
    /// The ladder the view runs on — its hooks are the hero's (`hold`,
    /// `lendContent`, …) once a hero source adopts it (#1088).
    public let ladder: LoadingLadder
    /// The picture, addressable (hook 1).
    public let imageView = UIImageView()
    /// The floor under the picture, when the caller gives one.
    public let placeholderView = UIImageView()
    /// The bucket the picture is decoded at.
    public let size: ImageBucket
    private let skeleton: SkeletonBoneView?
    private var task: Task<Void, Never>?
    private(set) var url: URL?

    /// - Parameters:
    ///   - size: the bucket the picture is decoded at — required (see the
    ///     type's note).
    ///   - skeleton: a bone's rounding while nothing has arrived, or nil for
    ///     none (a placeholder or a plain ground says it instead).
    public init(
        size: ImageBucket, skeleton: SkeletonBoneView.Rounding? = nil,
        policy: LoadingLadder.Policy = .standard, clock: LoadingLadder.Clock = .system
    ) {
        self.size = size
        ladder = LoadingLadder(policy: policy, clock: clock)
        self.skeleton = skeleton.map { SkeletonBoneView(rounding: $0) }
        super.init(frame: .zero)
        clipsToBounds = true
        for view in [self.skeleton, placeholderView, imageView].compactMap({ $0 }) {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isUserInteractionEnabled = false
            addSubview(view)
            view.pin(to: self)
        }
        placeholderView.contentMode = .scaleAspectFill
        imageView.contentMode = .scaleAspectFill
        placeholderView.clipsToBounds = true
        imageView.clipsToBounds = true
        if let skeleton = self.skeleton { ladder.setView(skeleton, for: .skeleton) }
        ladder.setView(placeholderView, for: .placeholder)
        ladder.setView(imageView, for: .content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// How the picture (and its placeholder) fill the view.
    public var imageContentMode: UIView.ContentMode {
        get { imageView.contentMode }
        set {
            imageView.contentMode = newValue
            placeholderView.contentMode = newValue
        }
    }

    /// The picture on show, nil while none has landed — what a hero would
    /// read as the still this view draws (hook 1).
    public var image: UIImage? { ladder.rung == .content ? imageView.image : nil }

    /// Shows the picture at `url`: drawn now when the pipeline has it, else
    /// loaded and dissolved in. The same URL again is a reconfigure and
    /// changes nothing (hook 8); another is a new item and cuts.
    ///
    /// - Parameter placeholder: a floor shown under the picture until it
    ///   lands (a glyph, a known colour, later a blurhash — #990).
    public func setImage(_ url: URL?, pipeline: ImagePipeline?, placeholder: UIImage? = nil) {
        if let url, url == self.url, task != nil || ladder.rung != nil { return }
        task?.cancel()
        task = nil
        self.url = url
        imageView.image = nil
        let token = ladder.begin(item: url)
        if let placeholder {
            placeholderView.image = placeholder
            ladder.show(.placeholder, token: token, warm: true)
        }
        guard let url, let pipeline else {
            ladder.fail(token: token)
            return
        }
        if let cached = pipeline.cachedImage(for: url, size: size) {
            imageView.image = cached
            ladder.show(.content, token: token, warm: true)
            return
        }
        let bucket = size
        task = Task { [weak self] in
            let image = try? await pipeline.image(for: url, size: bucket)
            guard !Task.isCancelled, let self, ladder.isCurrent(token) else { return }
            task = nil
            if let image {
                imageView.image = image
                ladder.show(.content, token: token)
            } else {
                ladder.fail(token: token)
            }
        }
    }

    /// Forgets the picture — a recycled cell's first step. A late answer for
    /// the old one lands nowhere.
    public func reset() {
        task?.cancel()
        task = nil
        url = nil
        imageView.image = nil
        placeholderView.image = nil
        ladder.begin(item: nil)
    }

    #if DEBUG
    /// Whether a load is in flight.
    public var debugIsLoading: Bool { task != nil }
    #endif
}

/// The picture loads of a list's rows, ONE PER ROW (#780), on the ladder's
/// rules (#1085): cache first and drawn at once, else loaded, and a late
/// answer for a row that moved on lands nowhere.
///
/// ⚠️ KEYED BY ROW. A cell is recycled: scrolled from A to B, it is
/// configured for B while A's load is still on its way. Keyed by the row,
/// configuring it again cancels what it was waiting for, so a late picture
/// only ever lands on the row that asked for it.
///
/// One copy for the app: it lived twice, in Search and in Profile's
/// settings lists, word for word (#1085).
@MainActor
public final class RowImageLoads {
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// The bucket every row's picture is decoded at.
    public let size: ImageBucket

    /// - Parameter size: required — a row's avatar is `.avatar`, not 1200 px
    ///   (#894).
    public init(size: ImageBucket) {
        self.size = size
    }

    /// Starts `row`'s load, cancelling the one it had. A row with no URL (or
    /// no pipeline) only cancels, and keeps its floor (initials).
    ///
    /// - Parameter apply: draws the picture; `animated` is false for a warm
    ///   hit drawn in the configure pass. Capture the cell weakly.
    public func load(
        _ url: URL?, using pipeline: ImagePipeline?, for row: AnyObject,
        apply: @escaping @MainActor (UIImage, _ animated: Bool) -> Void
    ) {
        let key = ObjectIdentifier(row)
        tasks.removeValue(forKey: key)?.cancel()
        guard let url, let pipeline else { return }
        if let cached = pipeline.cachedImage(for: url, size: size) {
            apply(cached, false)
            return
        }
        let bucket = size
        tasks[key] = Task { [weak self] in
            let image = try? await pipeline.image(for: url, size: bucket)
            // Cancelled means the row moved on, and its slot already belongs
            // to the next load.
            guard !Task.isCancelled else { return }
            self?.tasks[key] = nil
            if let image { apply(image, true) }
        }
    }

    /// Whether `row` has a load in flight.
    public func isLoading(for row: AnyObject) -> Bool { tasks[ObjectIdentifier(row)] != nil }
}

/// One picture load for a host that draws the picture itself (a banner's
/// blurred backdrop, a context-menu preview), on the ladder's rules (#1085):
/// cache first and drawn in the configure pass, else loaded; a new URL
/// cancels the old load, and a late answer for it lands nowhere. The host
/// is handed the transition to run — `Transition.perform` runs it — and
/// never picks a duration itself.
@MainActor
public final class ImageLoadSlot {
    /// The bucket the picture is decoded at — required (#894).
    public let size: ImageBucket
    /// How a late picture arrives.
    public let arrival: LoadingLadder.Transition
    private var task: Task<Void, Never>?
    private var generation = 0
    public private(set) var url: URL?

    public init(size: ImageBucket, arrival: LoadingLadder.Transition = .pictureArrives) {
        self.size = size
        self.arrival = arrival
    }

    /// Loads `url`: `apply` gets the picture and how to bring it in (`.none`
    /// for a warm hit), `failed` a missing or broken picture.
    public func load(
        _ url: URL?, using pipeline: ImagePipeline?,
        apply: @escaping @MainActor (UIImage, LoadingLadder.Transition) -> Void,
        failed: (@MainActor () -> Void)? = nil
    ) {
        cancel()
        self.url = url
        guard let url, let pipeline else {
            failed?()
            return
        }
        if let cached = pipeline.cachedImage(for: url, size: size) {
            apply(cached, .none)
            return
        }
        let current = generation
        let bucket = size
        let arrival = arrival
        task = Task { [weak self] in
            let image = try? await pipeline.image(for: url, size: bucket)
            guard !Task.isCancelled, let self, generation == current else { return }
            task = nil
            if let image { apply(image, arrival) } else { failed?() }
        }
    }

    /// Drops the load in flight; its answer lands nowhere.
    public func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        url = nil
    }

    /// Whether a load is in flight.
    public var isLoading: Bool { task != nil }
}

public extension LoadingLadder.Transition {
    /// Runs this transition over `view` while `change` swaps what it shows —
    /// the one place a picture's arrival is animated (#1085). `.none` and
    /// `.firstFrame` change at once; a view off screen changes at once too.
    @MainActor
    func perform(on view: UIView, _ change: @escaping @MainActor () -> Void) {
        guard case .dissolve(let duration) = self, view.window != nil else {
            change()
            return
        }
        UIView.transition(
            with: view, duration: duration, options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]
        ) {
            change()
        }
    }
}
