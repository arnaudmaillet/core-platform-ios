// The grid's seam types moved down to PostGridSeam (#2380) so FeedInterface
// can name them without PostGrid and MediaCore. Re-exported here, once, so
// every module that reached them through `import PostGrid` — and every file
// of this one — still does.
@_exported import PostGridSeam
