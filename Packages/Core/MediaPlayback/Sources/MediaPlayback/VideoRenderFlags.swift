import Foundation

/// Which render surface `VideoRenderView` is backed by, for the duration of the
/// process.
///
/// The two paths — `AVPlayerLayer` and `AVSampleBufferDisplayLayer` — differ in
/// exactly one place, `VideoRenderView.layerClass`, and `layerClass` is a class
/// property read once per instance. That only works because the flag is
/// **process-constant**: a launch argument, resolved once, never toggled. Do not
/// make this a settable var — half the surfaces in a running app being one kind
/// and half the other is not a state the controller knows how to hold.
///
/// Deliberately NOT `#if DEBUG`. Phase 1's exit criterion 5 is an Instruments
/// pass at six concurrent tiles, and a perf measurement taken against a debug
/// build measures the wrong binary. The flag has to survive into a release
/// build for the A/B to mean anything.
public enum VideoRenderFlags {
    /// `AVSampleBufferDisplayLayer` fed by `VideoFrameRenderer` is the DEFAULT
    /// backing (promoted 2026-08-02). It is the mode every no-window guarantee
    /// of the hero transition actually holds in — N surfaces per playback, no
    /// render slot to move — and while it was opt-in, the shipping
    /// configuration was the one with the 65–100ms re-bind gaps that all the
    /// hold/grace machinery exists to paper over.
    ///
    /// `-avplayer-render` (or `AVSBDL_RENDER=0` by environment) reverts to the
    /// historical `AVPlayerLayer` path — the escape hatch, and the A/B's other
    /// arm. The env var exists because `layerClass` is resolved once per
    /// process, so a unit-test bundle can only ever exercise ONE backing per
    /// run; CI runs the MediaPlayback suite a second time with it set to keep
    /// the legacy path covered. The old `-avsbdl-render` / `AVSBDL_RENDER=1`
    /// spellings still select the (now default) new path, so existing QA
    /// recipes keep meaning what they meant.
    public static let usesSampleBufferLayer: Bool = {
        let info = ProcessInfo.processInfo
        if info.arguments.contains("-avplayer-render")
            || info.environment["AVSBDL_RENDER"] == "0" {
            return false
        }
        return true
    }()

    /// `-avsbdl-log` traces frame dispatch: renderer lifecycle, first frame per
    /// surface, and enqueue failures. Separate from `-zoom-live-log`, which
    /// traces a flight — these two answer different questions and mixing them
    /// buried the signal last time.
    static let logsFrameDispatch: Bool =
        ProcessInfo.processInfo.arguments.contains("-avsbdl-log")

    /// TEMPORARY DIAGNOSTIC (2026-08-02): `-zoom-covers-only` suppresses video
    /// playback at both producers of the hero transition — grid tiles never
    /// autoplay and feed pages never start their player — so every live seam
    /// (donate, attach, mirror, hoist, adopt, park) naturally reports nothing
    /// and the whole flight is static images end to end. The control arm of
    /// the frame-0 device test: a flash that survives THIS is a raw UIKit
    /// layer/transition artifact with no media involved at all. Delete with
    /// the experiment.
    public static let debugCoversOnly: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-zoom-covers-only")
        #else
        return false
        #endif
    }()
}
