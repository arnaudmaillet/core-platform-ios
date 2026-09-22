import UIKit

/// Who draws the capsule a selector sits in — and, from that, where the
/// capsule's visible edge is relative to the selector's own view.
///
/// Three selectors share it (`PagedTabBar`, `IconSelectorBar`,
/// `IconActionBar`), and they share it because the ONE rule it exists to state
/// is a rule about how they look side by side: **the selection pill sits
/// `SelectorCapsuleMetrics.clearance` inside the capsule the viewer sees, on
/// every side, on every host — and nothing else in the capsule keeps a margin
/// of its own.** The strip of segments runs edge to edge under the glass, so a
/// crowded strip scrolls its titles right up to the capsule's edge instead of
/// vanishing 4pt short of it, and the pill is the only thing that stands off
/// the edge.
///
/// Before this existed, the margin was the STRIP's: a strip inset 4pt inside
/// the accessory's container, a lens filling its segment, and a scroll viewport
/// that therefore ended 4pt inside the glass. At rest the two arrangements draw
/// the same pixels; under a scroll they do not, and the old one clipped the
/// titles against an edge the viewer could not see.
///
/// ⚠️ **THE HOST DECIDES THIS, NOT THE SCREEN.** `SelectorAccessoryHost` sets
/// `.container` on the strip it wraps; a screen putting a bar in a toolbar item
/// sets `.platter`. A screen that sets it on a bar it then hands to a host is
/// stating an opinion the host will overwrite.
public enum SelectorHosting: Sendable, Equatable {
    /// The bar draws its own glass. The capsule the viewer sees IS this view.
    case standalone
    /// A host draws glass EXACTLY around this view — a `UITabAccessory`
    /// container, measured to be the content view's own size in both
    /// environments. The bar draws no material; its geometry is unchanged.
    case container
    /// A host draws glass AROUND this view with an overhang — a
    /// `UIBarButtonItem` platter, measured 4pt larger than the view it hosts on
    /// every side (a 149×36 host in a 157×44 platter). The capsule the viewer
    /// sees is wider than the bar, and the bar lays itself out against THAT.
    case platter

    /// Whether the bar materialises a `UIGlassEffect` of its own.
    ///
    /// ⚠️ Glass inside glass loses its edge entirely (see `PagedTabBar`'s type
    /// comment) — the selected segment stops reading as selected, which is the
    /// one thing a selector exists to say. Only a bar standing on its own draws.
    public var drawsBackdrop: Bool { self == .standalone }

    /// How far the visible capsule reaches beyond this view, per side — the
    /// STATED number, which a bar in a platter refines by measuring (see
    /// `measuredPlatterOverhang(around:)`) once it is in a window.
    public var overhang: CGFloat {
        switch self {
        case .standalone, .container: 0
        case .platter: SelectorCapsuleMetrics.platterOverhang
        }
    }

    /// How far the host's glass actually reaches beyond `view`, per side and
    /// per axis — or nil when nothing around the view looks like a platter.
    ///
    /// ⚠️ **MEASURED, BECAUSE THE STATED 4pt IS ONLY SOMETIMES TRUE.** A 36pt
    /// icon bar in a navigation bar sits in a 44pt platter (4pt a side); a 46pt
    /// tab strip in the bottom toolbar sits in a 58×(w+11) one — 6pt above and
    /// below, 5.5pt at each end (`-tabbar-shape-trace`, iPhone 18 Pro, iOS 27).
    /// A bar that assumed 4 there drew its pill 6pt off the glass, a visibly
    /// thicker ring than the same pill in an accessory.
    ///
    /// The platter is found by SHAPE, not by class name: the nearest ancestor
    /// that is larger than the view AND centred on it. The wrappers UIKit puts
    /// between a bar item's custom view and its glass are exactly the view's
    /// size, so the first larger one is the glass; a toolbar or a screen is
    /// larger too but not centred, and is refused. Anything reaching more than
    /// `platterOverhangCeiling` is not a ring and is refused as well.
    ///
    /// ⚠️ **IN THE VIEW'S OWN SPACE, NEVER THE WINDOW'S.** A sheet's toolbar
    /// presents its items under a scale transform, and a bar item lays out
    /// while it runs: in window points a 188×36 strip read 37×8, its wrapper
    /// 37×8 and the glass 195×48 — 79pt "wider", refused, and the bar kept the
    /// stated 4pt for the life of the screen because nothing laid it out again
    /// once the transform had gone. Converting the ancestor's bounds INTO the
    /// view's space walks only the frames between them, which a transform on
    /// an ancestor does not touch.
    static func measuredPlatterOverhang(around view: UIView) -> CGSize? {
        guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let own = view.bounds
        var ancestor = view.superview
        for _ in 0..<6 {
            guard let current = ancestor else { return nil }
            let frame = current.convert(current.bounds, to: view)
            let dx = frame.width - own.width
            let dy = frame.height - own.height
            if dx > 0.5 || dy > 0.5 {
                let ceiling = SelectorCapsuleMetrics.platterOverhangCeiling * 2
                guard dx >= -0.5, dy >= -0.5, dx <= ceiling, dy <= ceiling,
                      abs(frame.midX - own.midX) < 1, abs(frame.midY - own.midY) < 1
                else { return nil }
                return CGSize(width: max(0, dx) / 2, height: max(0, dy) / 2)
            }
            ancestor = current.superview
        }
        return nil
    }
}

/// Re-asks a platter measurement a few times after it was first taken.
///
/// ⚠️ **A BAR ITEM LAYS OUT MID-TRANSITION, AND NOTHING LAYS IT OUT AGAIN.** A
/// sheet's toolbar grows its items in from nothing: the bar's own frame is
/// mid-flight when its `layoutSubviews` runs (a 188×36 strip measured its ring
/// at 4.65×4.91 with the glass already at its final 195×48), and once the
/// animation has landed the bar's bounds have not changed, so no layout pass
/// ever re-measures. A short series of re-asks after the first one — each
/// guarded on change by the bar — is what lands the true number; the
/// animations in question are all under a second.
@MainActor
final class PlatterRemeasureSchedule {
    private var armed = false
    private var tasks: [Task<Void, Never>] = []

    /// Arms the series once; later calls are no-ops until `reset`.
    func arm(_ remeasure: @escaping @MainActor () -> Void) {
        guard !armed else { return }
        armed = true
        for delay in [0.35, 0.75, 1.5] {
            tasks.append(Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                remeasure()
            })
        }
    }

    /// Cancels what is pending, so the next arm starts the series again — for
    /// a bar that left its window or changed host.
    func reset() {
        for task in tasks { task.cancel() }
        tasks = []
        armed = false
    }
}

/// The numbers every selector capsule is cut to.
///
/// Deliberately NOT public: the three bars are in this module, and a metric a
/// feature can read is a metric a feature can build its own bar out of.
enum SelectorCapsuleMetrics {
    /// From the capsule's visible edge to the selection pill, on EVERY side.
    ///
    /// One number for both axes. It was 5 horizontally and 4 vertically once,
    /// which put the pill closer to the capsule's top and bottom than to its
    /// ends — invisible on a wide segment and obvious on a round one, where the
    /// eye reads the pill against the capsule's own curve.
    static let clearance: CGFloat = 4

    /// How much larger a `UIBarButtonItem`'s glass platter is than the custom
    /// view it hosts, per side — the number a bar assumes until it has measured
    /// its own (`SelectorHosting.measuredPlatterOverhang(around:)`). True of a
    /// 36pt bar in a 44pt platter; a taller bar in the bottom toolbar measures
    /// more.
    static let platterOverhang: CGFloat = 4

    /// The most a platter is believed to reach beyond its view, per side. A
    /// larger ancestor is a container of some other kind, not a ring.
    static let platterOverhangCeiling: CGFloat = 12
}
