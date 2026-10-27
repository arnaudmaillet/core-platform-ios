import DesignSystem
import UIKit

/// A picture arriving, on the media slot (#1505): the bone while a picture
/// not in memory is on its way, an optional placeholder, then the picture
/// decoded at its bucket — the plain view form of `MediaSlot`, for a host
/// with no decoration of its own.
///
/// ```
///   skeleton → placeholder (optional) → picture
///   a warm hit draws in the configure pass; a late one dissolves in 0.25 s
/// ```
///
/// ⚠️ **THE SIZE BUCKET IS REQUIRED.** There is no `.full` default here: a
/// view that decodes a 1200 px picture for a 40 pt slot holds forty times the
/// memory it shows (#894, #1086). Say the size the view draws at.
@MainActor
public final class ImageContentView: UIView {
    /// The ladder the view runs on.
    public var ladder: LoadingLadder { slot.ladder }
    /// The picture, addressable (hook 1).
    public let imageView = UIImageView()
    /// The floor under the picture, when the caller gives one.
    public let placeholderView = UIImageView()
    /// The bucket the picture is decoded at.
    public var size: ImageBucket { slot.size }
    private let slot: MediaSlot
    var url: URL? { slot.url }

    /// - Parameters:
    ///   - size: the bucket the picture is decoded at — required (see the
    ///     type's note).
    ///   - skeleton: the bone's rounding while nothing has arrived.
    public init(
        size: ImageBucket, skeleton: SkeletonBoneView.Rounding = .fixed(0),
        policy: LoadingLadder.Policy = .standard, clock: LoadingLadder.Clock = .system
    ) {
        let bone = SkeletonBoneView(rounding: skeleton)
        slot = MediaSlot(size: size, bone: bone, policy: policy, clock: clock)
        super.init(frame: .zero)
        clipsToBounds = true
        for view in [bone, placeholderView, imageView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isUserInteractionEnabled = false
            addSubview(view)
            view.pin(to: self)
        }
        placeholderView.contentMode = .scaleAspectFill
        imageView.contentMode = .scaleAspectFill
        placeholderView.clipsToBounds = true
        imageView.clipsToBounds = true
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
    /// the bone, then the picture dissolved in. The same URL again is a
    /// reconfigure and changes nothing (hook 8); another is a new item and
    /// cuts.
    ///
    /// - Parameter placeholder: a floor shown under the picture until it
    ///   lands (a glyph, a known colour, later a blurhash — #990).
    public func setImage(_ url: URL?, pipeline: ImagePipeline?, placeholder: UIImage? = nil) {
        if let url, url == slot.url, slot.isLoading || ladder.rung == .content { return }
        imageView.image = nil
        let token = slot.begin(url)
        if let placeholder {
            placeholderView.image = placeholder
            ladder.show(.placeholder, token: token, warm: true)
        }
        slot.load(url, using: pipeline) { [weak self] image, transition in
            guard let self else { return }
            imageView.image = image
            ladder.show(.content, token: token, warm: transition == .none)
        }
    }

    /// Forgets the picture — a recycled cell's first step. A late answer for
    /// the old one lands nowhere.
    public func reset() {
        slot.cancel()
        imageView.image = nil
        placeholderView.image = nil
        slot.begin(nil)
    }

    #if DEBUG
    /// Whether a load is in flight.
    public var debugIsLoading: Bool { slot.isLoading }
    /// Whether the bone shows now.
    public var debugShowsBone: Bool { slot.showsBone }
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
    /// The bucket the picture is decoded at — required (#894). A host whose
    /// view follows Dynamic Type restates it; the next load reads it.
    public var size: ImageBucket
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
