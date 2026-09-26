# Map preview sheets

Baked sprite sheets of the mock corpus's video clips. A video marker animates
one of these instead of playing a clip, so the map shows moving media with no
network and no decoder — see `AnimatedIconArt`, `PinCardView.setPreviewSheet`.

`mappreviews.json` is the manifest the app reads (`AppContainer.mapPreviewCatalog`).
Ids are `<clip>-<segment>`; `MockMediaFixtures.bakedClip(for:)` maps a video URL
to its `<clip>` and returns nil for one that has no sheet.

## The mock clips' sheets (`clip-NN-0`)

One sheet per real clip of the mock corpus, baked by
`Scripts/import-mock-clips.py` together with the clips themselves — never by
hand. One segment each: the clip's opening, which is also the poster the feed
shows (`MockMediaFixtures.bakedClip(for:)` names the clip, `openingSegment`
finds its `-0`).

These are the only sheets. The Big Buck Bunny and Sintel film sheets that used
to sit beside them went with the public video fixtures: the mock plays only its
own clips.

## Baking notes

⚠️ `--square` selects the CLIP SHAPE, not the aspect policy. It sets
`AtlasWriter.Shape.square` (a rect rather than a disc) and a `Rasteriser.Fit`
that only the Lottie paths read. Omitting it masks every cell into a DISC, which
is right for an icon and wrong for a preview.

Cells are square and most clips are not, so `AtlasWriter.drawCell` aspect-FILLS
and the clip crops the overflow — the same crop the marker and the page draw
media with. It did not always: until 94db33a it stretched, and every sheet was
too narrow (or too short) in its own pixels.

## Cost

53 clip sheets (~11 MB), 172pt cells, 24 frames each. That is the whole
budget: sprite sheets at this size were measured against the alternatives in
[[animated-map-icons]] (9 MB decomposed vs 217 MB projected for full sheets at
128 icons), and the map's marker count is bounded by clustering to ~19.
