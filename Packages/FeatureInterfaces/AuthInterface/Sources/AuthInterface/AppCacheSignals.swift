import CacheKit
import Foundation

/// The signals the app's one `CacheCoordinator` listens to (epic #890).
///
/// - `SystemCacheSignals`: memory warning and critical pressure, background
///   and foreground, Low Power Mode, thermal state, the network path.
/// - `.viewerDidChange` → `.viewerChanged`: a logout, an account switch or a
///   profile switch wipes the viewer-scoped and signed namespaces and keeps
///   public media (decision 4).
///
/// ⚠️ `.viewerDidChange`, NOT `StorageScope.didChangeNotification`. The
/// storage scope also changes at every cold start (unscoped → member →
/// member with its resolved profile), so mapping it would wipe every
/// viewer-scoped cache on each launch. `.viewerDidChange` is posted only for a
/// real transition, after the startup sign-in sequence
/// (`AppContainer.observeViewerTransitions`).
public enum AppCacheSignals {
    /// - Parameters:
    ///   - center: where UIKit, `ProcessInfo` and the viewer session post.
    ///     Tests pass a private one.
    ///   - observesSystemMonitors: whether to start the memory-pressure
    ///     dispatch source and the network path monitor. Tests turn them off.
    public static func sources(
        center: NotificationCenter = .default,
        observesSystemMonitors: Bool = true
    ) -> [any CacheSignalSource] {
        var sources: [any CacheSignalSource] = [
            SystemCacheSignals(
                center: center,
                observesMemoryPressure: observesSystemMonitors,
                observesNetwork: observesSystemMonitors
            ),
            NotificationCacheSignals(center: center, .viewerDidChange, signal: .viewerChanged)
        ]
        #if DEBUG
        // `-cache-signal <name>@<seconds>`: a release signal on cue, for the
        // `-cache-audit` instrument (#898). Nothing without the argument.
        if observesSystemMonitors { sources.append(DebugCacheSignals(center: center)) }
        #endif
        return sources
    }
}
