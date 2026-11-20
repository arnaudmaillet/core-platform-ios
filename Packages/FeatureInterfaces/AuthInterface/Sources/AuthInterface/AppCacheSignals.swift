import CacheKit
import CoreModels
import Foundation

/// The signals the app's one `CacheCoordinator` listens to (epic #890).
///
/// - `SystemCacheSignals`: memory warning and critical pressure, background
///   and foreground, Low Power Mode, thermal state, the network path.
/// - A viewer change on the app's `ViewerEvents` → `.viewerChanged`: a
///   logout, an account switch or a profile switch wipes the viewer-scoped
///   and signed namespaces and keeps public media (decision 4).
///
/// ⚠️ THE VIEWER'S CHANGES, NOT THE STORAGE SCOPE'S (`StorageScope.ownerChanges`).
/// The storage scope also changes at every cold start (unscoped → member →
/// member with its resolved profile), so mapping it would wipe every
/// viewer-scoped cache on each launch. `ViewerEvents.publishViewerChange()`
/// is called only for a real transition, after the startup sign-in sequence
/// (`AppContainer.observeViewerTransitions`).
///
/// ⚠️ THE WIPE RUNS BEFORE ANY SCREEN RE-READS (#2376): it subscribes in the
/// `.caches` phase, which `ViewerEvents` delivers before every observer,
/// synchronously, so no screen reads the previous viewer's facts and no
/// first write of the new viewer is wiped after it.
public enum AppCacheSignals {
    /// - Parameters:
    ///   - center: where UIKit and `ProcessInfo` post. Tests pass a private
    ///     one.
    ///   - viewerEvents: the app's one channel of viewer changes.
    ///   - observesSystemMonitors: whether to start the memory-pressure
    ///     dispatch source and the network path monitor. Tests turn them off.
    @MainActor
    public static func sources(
        center: NotificationCenter = .default,
        viewerEvents: ViewerEvents,
        observesSystemMonitors: Bool = true
    ) -> [any CacheSignalSource] {
        var sources: [any CacheSignalSource] = [
            SystemCacheSignals(
                center: center,
                observesMemoryPressure: observesSystemMonitors,
                observesNetwork: observesSystemMonitors
            ),
            ViewerCacheSignals(viewerEvents: viewerEvents)
        ]
        #if DEBUG
        // `-cache-signal <name>@<seconds>`: a release signal on cue, for the
        // `-cache-audit` instrument (#898). Nothing without the argument.
        if observesSystemMonitors { sources.append(DebugCacheSignals(center: center)) }
        #endif
        return sources
    }
}

/// `.viewerChanged` on every viewer change of one `ViewerEvents`, delivered
/// synchronously, in its `.caches` phase. Subscribed from the moment it is
/// built, for as long as the coordinator keeps it; it delivers only between
/// `start` and `stop`, as a notification source did.
final class ViewerCacheSignals: CacheSignalSource {
    private let manual: ManualCacheSignals
    private let subscription: ViewerEventSubscription

    @MainActor
    init(viewerEvents: ViewerEvents) {
        let manual = ManualCacheSignals()
        self.manual = manual
        subscription = viewerEvents.onViewerChange(.caches) { manual.send(.viewerChanged) }
    }

    func start(_ deliver: @escaping @Sendable (CacheSignal) -> Void) {
        manual.start(deliver)
    }

    func stop() {
        manual.stop()
    }
}
