# Map preview sheets

Baked sprite sheets of the mock corpus's video fixtures. A video marker animates
one of these instead of playing a clip, so the map shows moving media with no
network and no decoder — see `AnimatedIconArt`, `PinCardView.setPreviewSheet`.

`mappreviews.json` is the manifest the app reads (`AppContainer.mapPreviewCatalog`).
Ids are `<clip>-<segment>`; `MockMediaFixtures.bakedClip(for:)` maps a fixture to
its `<clip>` and returns nil for the ones that have no sheet.

## Re-baking

The sources are the mock fixtures themselves (`MockMediaFixtures`), downloaded
first — ⚠️ AVFoundation refuses REMOTE assets here (-11800), so bake local files:

    curl -sSL -o /tmp/bbb.mp4 \
      https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4
    curl -sSL -o /tmp/sintel.mp4 https://media.w3.org/2010/05/sintel/trailer.mp4

    swift build --package-path Tools/IconBaker
    B=Tools/IconBaker/.build/debug/IconBaker
    $B --out <dir> --manifest a.json --square --cell 172 --max-frames 24 \
       --segments 6 --id bigbuckbunny  /tmp/bbb.mp4
    $B --out <dir> --manifest b.json --square --cell 172 --max-frames 24 \
       --segments 6 --id sinteltrailer /tmp/sintel.mp4

Then concatenate the two manifests into `mappreviews.json` (a flat JSON array,
sorted by id) and copy the `.heic` files here. The baker writes one manifest per
invocation; nothing merges them for you.

⚠️ `--square` selects the CLIP SHAPE, not the aspect policy. It sets
`AtlasWriter.Shape.square` (a rect rather than a disc) and a `Rasteriser.Fit`
that only the Lottie paths read. Omitting it masks every cell into a DISC, which
is right for an icon and wrong for a preview.

Cells are square and the frames are 16:9, so `AtlasWriter.drawCell` aspect-FILLS
and the clip crops the overflow — the same crop the marker and the page draw
media with. It did not always: until 94db33a it stretched, and every sheet was
1.78x too narrow in its own pixels.

## Cost

12 sheets, 172pt cells, 24 frames each, ~2.5 MB in the bundle. That is the whole
budget: sprite sheets at this size were measured against the alternatives in
[[animated-map-icons]] (9 MB decomposed vs 217 MB projected for full sheets at
128 icons), and the map's marker count is bounded by clustering to ~19.
