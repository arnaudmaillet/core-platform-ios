import UIKit

/// A list section's loading on the kit's timing (#1770): what a section whose
/// rows are on their way shows — nothing for 0.15 s, its skeleton rows held
/// 0.3 s once up, and after 10 s a "Taking longer" row a tap retries.
///
/// For the lists that draw their loading state as rows of their own
/// snapshot (Settings, the relationship lists): building the snapshot, the
/// loading section asks `loading()` what to put in; applying the answer goes
/// through `landed(_:)`; `onChange` redraws when the gate decides.
///
///     case .loading:
///         switch gate.loading() {
///         case .bones: snapshot.appendItems([.loading])
///         case .takingLonger: snapshot.appendItems([.takingLonger])
///         case .nothing: break
///         }
@MainActor
public final class ListSkeletonGate {
    /// What the loading section shows now.
    public enum Shown: Equatable, Sendable {
        /// Nothing yet: the wait is under its delay.
        case nothing
        /// The section's skeleton rows.
        case bones
        /// "Taking longer than usual. Tap to try again." (`TakingLongerCopy.row`).
        case takingLonger
    }

    /// The gate decided: the bones come, or the wait ran long. Redraw.
    public var onChange: (@MainActor () -> Void)?

    private let gate: SkeletonGate
    private var tookLonger = false

    public init(timing: SkeletonGate.Timing = .standard, clock: LoadingClock = .system) {
        gate = SkeletonGate(timing: timing, clock: clock)
        gate.onSkeletonChange = { [weak self] _ in self?.onChange?() }
        gate.onTakingLonger = { [weak self] in
            guard let self else { return }
            tookLonger = true
            gate.finish { [weak self] in self?.onChange?() }
        }
    }

    /// What a loading section shows now. The first ask starts the wait.
    public func loading() -> Shown {
        if tookLonger { return .takingLonger }
        // ⚠️ AN ANSWER WAITING OUT THE MINIMUM KEEPS ITS BONES: a section
        // still loading beside it (or a redraw before the phase moved) must
        // not begin again — that would drop the answer.
        if gate.isRevealing { return .bones }
        gate.begin()
        return gate.showsSkeleton ? .bones : .nothing
    }

    /// The answer: `apply` runs now, or once the bones have had their
    /// minimum — the newest answer, once.
    public func landed(_ apply: @escaping @MainActor () -> Void) {
        tookLonger = false
        gate.finish(apply)
    }

    /// Whether the wait ran past 10 s and no answer has landed since.
    public var isTakingLonger: Bool { tookLonger }

    /// Try Again: the next `loading()` starts the wait over.
    public func retry() {
        tookLonger = false
    }
}
