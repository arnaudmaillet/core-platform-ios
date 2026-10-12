import MediaCore

public extension GalleryPost {
    /// What a list's lookahead fetches ahead for this post (#970): the face
    /// its tile or card shows, at the size the cell asks the pipeline for
    /// (`.full`: a smaller bucket would not serve the cell's lookup). A video
    /// tile's poster comes through the image path like any still (Facebook's
    /// "current-only": no video bytes off screen). A text post has none.
    var lookaheadImages: [ImageRequest] {
        guard let thumbnailURL else { return [] }
        return [ImageRequest(url: thumbnailURL)]
    }
}
