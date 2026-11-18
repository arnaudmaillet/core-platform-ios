import UIKit

/// The dashboard's own windows — its sheet, badges and overlays, and the
/// latency HUD — which the tools never inspect, outline, slow down or
/// screenshot. It lives with the instrumentation, the lowest of the
/// navigation targets, so the HUD and the dashboard can both adopt it (#2384).
@MainActor
package protocol DebugOverlayWindow: UIWindow {}
