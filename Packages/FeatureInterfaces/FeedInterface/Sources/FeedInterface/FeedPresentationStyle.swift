/// How the Feed feature renders its timeline. The composition root picks one
/// and hands it to `FeedFeatureBuilding`; the Feed package never reads launch
/// arguments itself.
///
/// - `classic`: the scrollable, content-height list (the original timeline).
/// - `snap`: a full-screen, page-snapping vertical media feed (Phase 1 renders
///   image posts; the same cell-lifecycle seam later drives video).
public enum FeedPresentationStyle: Sendable, Equatable {
    case classic
    case snap
}
