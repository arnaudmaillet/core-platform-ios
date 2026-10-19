#if DEBUG
import DesignSystem
internal import SwiftUI
import UIKit

/// PROTOTYPE (#1369), DEBUG only: the paused clip's play triangle MADE OF
/// Liquid Glass — the glass takes the triangle's outline. Not a glyph in a
/// glass bubble: a plate over the content would make an inert mark read as a
/// button.
///
/// `-glass-play-mark` turns it on (`.regular`); `-glass-play-mark clear` or
/// `-glass-play-mark tinted` pick the other variants. Without the flag,
/// `PausedClipMarkView` is today's white glyph, untouched.
///
/// ⚠️ WHY SWIFTUI. No public API turns an SF Symbol into glass, and UIKit's
/// `UIGlassEffect` only takes `cornerConfiguration` shapes; masking a glass
/// view only stencils a slab and loses the rim and the refraction. SwiftUI's
/// `glassEffect(_:in:)` takes any `Shape`, so the triangle is a `Path`.
///
/// ⚠️ NEVER THE GLASS'S ALPHA. Glass under a partial alpha renders wrong
/// (the repo's glass traps). It comes and goes by `Glass.identity` — the
/// glass materialising and dematerialising, the system's own way to fade it —
/// with the app's bounce-in / scale-out on top (`AppearMotion`'s numbers);
/// under Reduce Motion, the materialise alone.
enum GlassPlayMark {
    enum Variant: String {
        case regular, clear, tinted
    }

    /// The variant the launch arguments ask for; nil without the flag.
    static let variant: Variant? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-glass-play-mark") else { return nil }
        let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
        return Variant(rawValue: next) ?? .regular
    }()
}

/// A play triangle with `play.fill`'s proportions and softly rounded
/// corners, filling its frame: the point on the right, mid-height.
struct PlayTriangle: Shape {
    /// The corners' radius, as a fraction of the height (`play.fill` reads
    /// about this round at 56 pt semibold).
    var cornerFraction: CGFloat = 0.11

    func path(in rect: CGRect) -> Path {
        let radius = rect.height * cornerFraction
        let top = CGPoint(x: rect.minX, y: rect.minY)
        let tip = CGPoint(x: rect.maxX, y: rect.midY)
        let bottom = CGPoint(x: rect.minX, y: rect.maxY)
        var path = Path()
        // From mid-way down the flat side, each corner rounded on the
        // tangents of its two edges.
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addArc(tangent1End: top, tangent2End: tip, radius: radius)
        path.addArc(tangent1End: tip, tangent2End: bottom, radius: radius)
        path.addArc(tangent1End: bottom, tangent2End: top, radius: radius)
        path.closeSubpath()
        return path
    }
}

/// What the hosted view draws: shown or not, and how.
@MainActor @Observable
final class GlassPlayMarkModel {
    var shown = false
    var reducesMotion = false
    let variant: GlassPlayMark.Variant
    let size: CGSize

    init(variant: GlassPlayMark.Variant, size: CGSize) {
        self.variant = variant
        self.size = size
    }
}

struct GlassPlayMarkView: View {
    let model: GlassPlayMarkModel

    private var glass: Glass {
        switch model.variant {
        case .regular: .regular
        case .clear: .clear
        case .tinted: .regular.tint(.white.opacity(0.22))
        }
    }

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: model.size.width, height: model.size.height)
            .glassEffect(model.shown ? glass : .identity, in: PlayTriangle())
            .scaleEffect(model.shown || model.reducesMotion ? 1 : AppearMotion.appearScale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }
}

/// The hosted glass triangle, laid over the mark's whole frame.
@MainActor
final class GlassPlayMarkHost {
    let model: GlassPlayMarkModel
    private let controller: UIHostingController<GlassPlayMarkView>
    var view: UIView { controller.view }

    init(variant: GlassPlayMark.Variant, size: CGSize) {
        model = GlassPlayMarkModel(variant: variant, size: size)
        controller = UIHostingController(rootView: GlassPlayMarkView(model: model))
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
    }

    /// Shows or hides the glass; `completion` runs once the motion has
    /// settled (at once without animation).
    func setShown(_ shown: Bool, animated: Bool, reducesMotion: Bool, completion: @escaping () -> Void) {
        model.reducesMotion = reducesMotion
        guard animated else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { model.shown = shown }
            completion()
            return
        }
        let animation: Animation = if reducesMotion {
            .easeInOut(duration: AppearMotion.fadeDuration)
        } else if shown {
            .spring(duration: AppearMotion.appearDuration, bounce: AppearMotion.appearBounce)
        } else {
            .easeIn(duration: AppearMotion.disappearDuration)
        }
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            model.shown = shown
        } completion: {
            completion()
        }
    }
}
#endif
