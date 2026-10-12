import CoreStorage

/// The saved fact `PostBookmarkStore` reads first and writes after its pile
/// (#896): one per post, viewer-scoped, observed by every screen drawing a
/// save glyph (`observePost`, `observePosts`).
extension EntityStore: PostSaveFacts {}
