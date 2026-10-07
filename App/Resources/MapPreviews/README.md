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

Cells keep the CLIP's aspect (`--native-aspect`, #539): 172px on the short
side, the long side proportional — 172x306 for a 9:16 clip. The marker
aspect-fills its square, so it shows exactly the crop a square cell held, and
the hero that opens it has the whole picture to reveal at its own aspect
instead of a square crop to stretch into a portrait page. Re-bake with
`Scripts/import-mock-clips.py --rebake-sheets`.

Before #539 the cells were square and `AtlasWriter.drawCell` aspect-FILLED
each frame into them; before 94db33a it stretched them.

## Cost

53 clip sheets (~19 MB; ~11 MB while the cells were square), 172px on the
short side, 24 frames each. A 9:16 sheet is 5.1 MB resident (2.8 MB square);
the 7-9 measured resident fit the 64 MB cache. That is the whole
budget: sprite sheets at this size were measured against the alternatives in
[[animated-map-icons]] (9 MB decomposed vs 217 MB projected for full sheets at
128 icons), and the map's marker count is bounded by clustering to ~19.
