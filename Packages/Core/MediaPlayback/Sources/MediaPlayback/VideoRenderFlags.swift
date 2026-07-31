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
    /// `-avsbdl-render` routes playback through `VideoFrameRenderer` into an
    /// `AVSampleBufferDisplayLayer`. Absent, `VideoRenderView` behaves exactly
    /// as it did before this subsystem existed.
    ///
    /// `AVSBDL_RENDER=1` is the same switch by environment, and it exists for
    /// one reason: because `layerClass` is resolved per process, a unit-test
    /// bundle can only ever exercise ONE of the two backings per run. The env
    /// var is what lets CI run the suite twice — once each way — instead of
    /// leaving the new path covered by nothing.
    public static let usesSampleBufferLayer: Bool = {
        let info = ProcessInfo.processInfo
        return info.arguments.contains("-avsbdl-render")
            || info.environment["AVSBDL_RENDER"] == "1"
    }()

    /// `-avsbdl-log` traces frame dispatch: renderer lifecycle, first frame per
    /// surface, and enqueue failures. Separate from `-zoom-live-log`, which
    /// traces a flight — these two answer different questions and mixing them
    /// buried the signal last time.
    static let logsFrameDispatch: Bool =
        ProcessInfo.processInfo.arguments.contains("-avsbdl-log")
}
