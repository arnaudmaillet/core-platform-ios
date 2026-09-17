# Editor completion plan (PR 2)

Every editing option of the Upload media editor, for photos and videos. Written before the work started (2026-09-17); the adjustments and the wave schedule below override the original plan where they disagree.

## PR 2 plan — adjustments after PR 1 landed (READ FIRST, overrides the plan where they disagree)

The full plan is `plan-pr2-original.md` next to this file. PR 1's real contract differs from what the plan assumed:

## Real PR 1 names and behaviour (Packages/Core/MediaPlayback/Sources/MediaPlayback)
- `VideoCompositor.swift`:
  - `VideoCompositionScene` (Sendable, Equatable): `orientation` (Core Image y-up transform to upright-at-origin), `renderSize`, `transition: Transition?` (`kind`, `opens`, `cut`, `closes` in seconds, `progress(at:)`).
  - `VideoCompositorInstruction` (NSObject, `@unchecked Sendable`, immutable): `timeRange`, `laneA`, `laneB`, `scene`.
  - `VideoCompositor` (custom `AVVideoCompositing`): `static let context` is **UNMANAGED** (`workingColorSpace`/`outputColorSpace` = NSNull) on purpose (measured: managed blending brightened dips and shifted green by 17). Source buffers without a YCbCr matrix are tagged Rec.709 before reading. Output buffers are BGRA IOSurface, tagged 709.
  - `static func draw(_ scene:, laneA:, laneB:, at:) -> CIImage` — pure, testable; `static func cross(...)` draws the 11 two-picture CI transitions.
  - **Do NOT unify this context with the photo pipeline's managed sRGB context.** Photo stays managed (sRGB); video stays unmanaged 709. A look graph (`FrameLookRenderer`) is just `CIImage -> CIImage` and works under both; parity tests need tolerance.
- `VideoExporter.arrangement(of:cut:orientation:)` returns `Arrangement { asset, videoComposition, audioMix, windows, videoTracks, composed: ComposedVideo? }`. Instructions currently tile: plain stretches + two per transition (split at the cut). Lane B (`otherSides`) holds the other side of two-picture cuts. `private struct Canvas` holds size/orientation/frame.
- `ComposedFrameReader.swift`: `ComposedVideo(asset:tracks:composition:)`; `ComposedFrameReader.frame(at:)` (never waits, hands each frame once, restarts on jumps, throttled 80ms, lookahead 6).
- `VideoFrameSource.setItem(_:composing:)` / `VideoFrameRenderer.setItem(_:composing:)`: the item stays PLAIN; the renderer composes. `VideoPlaybackController.present(_:on:)` decides (legacy `-avplayer-render` path still assigns `item.videoComposition`). `debugComposition(in:)` returns what draws the view.
- ⚠️ iOS 27 simulator: NEVER set `item.videoComposition` on a player item that renders — it fails (-11800/-12784). AVAssetImageGenerator and AVAssetExportSession DO honour the custom compositor on iOS 27 (all pixel tests pass through the generator).
- `MediaPreviewPlayer`/`MediaVideoPreviewing` gained `advancingRate(in:)` (4 test stubs updated).

## Changes to the plan
1. **Live look on video (plan §4.6/S2):** no "kept base image". The compositor reads the whole look from a lock-protected board (`VideoLiveLook`) referenced by the instructions; a look change on a video calls a new `ComposedFrameReader.refresh()` (restart at the last wanted time, `handedOut` reset) through `VideoFrameSource`/renderer/controller (`setLiveLook(_:in:)` = board.set + refresh). No new player item. Frames already read ahead are dropped by the refresh.
2. **Preview render scale (S2):** measure whether `AVAssetReaderVideoCompositionOutput` honours `renderScale`; if not, build the preview composition with a smaller `renderSize` and scale the orientation transform (the compositor draws into `renderSize`). Cap the preview's long side at 1280.
3. **Segment looks need instructions split at EVERY piece boundary** (plan S2) — PR 1 splits only at transition windows.
4. **Crop on video:** the compositor applies the crop after the transition and before the whole look; `renderSize` becomes the crop's output size. Keep `Canvas` as the single place orientation/size are worked out.
5. **StickerKit (S4):** keep the plan (move the 12 `.lottie` files from Chat to a new `Packages/Core/StickerKit`, shim in Chat). If the move breaks Chat in ways that take more than 20 minutes, fall back to COPYING the files into StickerKit and leaving Chat untouched.
6. **Base branch:** PR 2 work starts from `feature/upload-video-transitions` (PR 1) and is rebased onto `develop` once PR 1 squash-merges. Integration branch: `feature/upload-editor-complete`.
7. **Simulators:** iPhone 18 Pro iOS 27 `710B76BE-B75A-44EE-871C-ADC41FB0EBE3` is reserved for the integrator (me). Agents use the iPhone SE iOS 27 `99CE52A6-48B6-42AA-8B5E-0C548DCB810C`, or a parallel-testing clone (`-parallel-testing-enabled YES -parallel-testing-worker-count 1`), and must never launch the app on the 18 Pro. The iPhone 17 Pro Max iOS 26.5 `B7811136-F084-4D35-B6D4-5FBB8838DDFC` may be used for the iOS 26 check (its first launches can hang under Xcode 27 — retry after a minute).
8. **Per-segment filter UX (user's words):** "dans la toolbar de gauche avoir une icône filtre (à côté de l'icône des ciseaux et de la vitesse), qui sera active que lorsqu'un segment sera sélectionné dans la timeline, et le clic sur ce bouton activera le mode compact de la timeline et affichera en dessous une scrollview horizontale avec les filtres disponibles (exactement comme on a fait avec l'affichage des transitions disponibles). Il faut tout de même garder dans la toolbar en bas à droite l'autre icône de filtre qui permet d'appliquer un filtre au média entier."

## PR 2 wave schedule (integrator's order — overrides plan §9.1)

The plan's wave 1 put S2 beside S1, but S2's pixel tests need S1's look graph. Re-ordered by dependency:

- **Wave A** (in parallel, from the integration branch with S0): S1 (look pipeline), S3 (overlay rasteriser + photo bake), S4 (StickerKit), S11 (soundtrack — its own files; fill the S0 stubs `VideoExporter+Soundtrack.swift`, `VideoPlaybackController` sound stubs, the preview player sound bodies).
- **Wave B** (after A merges): S2 (compositor finish, live look, export route — uses S1), S5+S6 (Effects UI + video Filters — uses S1; video live look through the S2 API: call the controller API; tests use the stub preview), S7 (segment filters: model, row, UI, charter; the compositor's per-piece look comes from S2 — S7 must only put `look` on the plan's segments), S9 (overlay canvas + Text — uses S3).
- **Wave C** (after B merges): S8 (video crop — uses S2), S10 (stickers UI — uses S4 + S9), S12 (publish path — uses S2, S3, S4, S11).
- **S13**: the integrator.

Integration branch: `feature/upload-editor-complete`. Each wave's agents start from its tip.

---

## Upload media editor: every editing option for photos and videos (PR 2)

I read the editor, the timeline, the exporter and playback, the publish path, the chat stickers, DesignSystem, CI and the project memory. Nothing was modified.

**Path shorthands used below** (all absolute):
- `ROOT` = `<repo root>`
- `UP` = `ROOT/Packages/Features/Upload/Sources/Upload`
- `UT` = `ROOT/Packages/Features/Upload/Tests/UploadTests`
- `MP` = `ROOT/Packages/Core/MediaPlayback/Sources/MediaPlayback`
- `MT` = `ROOT/Packages/Core/MediaPlayback/Tests/MediaPlaybackTests`
- `DS` = `ROOT/Packages/Core/DesignSystem/Sources/DesignSystem/Components`
- `CH` = `ROOT/Packages/Features/Chat/Sources/Chat`

---

## 0. Summary of the decisions I made

| Question | Decision | Why |
|---|---|---|
| Where the shared look, overlay and soundtrack types live | New folder `MP/Editing/` inside **MediaPlayback**. Upload keeps its names through typealiases (`MediaFilter = LookPreset`, `MediaCrop = FrameCrop`). | The compositor lives in MediaPlayback, and MediaPlayback may not depend on Upload. A separate package would cost manifest work, and MediaPlayback's manifest says it deliberately depends on no local package. Upload already uses MediaPlayback types in its model (`MediaSegment.transitionOut: VideoTransitionKind?`, `UP/Data/MediaTimeline.swift:35`). |
| Order of the per-segment filter and the whole-media filter | Per lane: **segment filter → transition blend → crop → whole look → overlays**. | (1) A dissolve then blends two pieces that already carry their filters, instead of snapping at the cut. (2) The whole-media filter acts as a master grade over the finished film, like a clip effect under an adjustment layer in an NLE. (3) For photos the filter is already the last colour stage. (4) The whole look runs once per frame; a segment filter runs only inside its own piece. |
| Order inside a look | adjustments (`CIColorControls`, warmth, highlights/shadows) → preset (`CIPhotoEffect*`) → stylised effect (blended with the source by intensity via `CIMix`) → sharpness → vignette → grain | Grain and vignette come last so nothing blurs or recolours them. |
| Time range for text on video | **Version 1: overlays (text and stickers) cover the whole film. No time-range field.** | Shippable. The repo rule is "an unused slot is dead code" (`MP/VideoExporter.swift:37`). A lane UI would roughly double slice S9. The compositor already receives composition time, so adding a window later is a one-line filter. Logged as "not yet met". |
| How overlays appear in the editor | As **views inside the page cell**, drawn from the same rasteriser the export uses. They are **not** burned into the editor's preview. | Moving, pinching and rotating stays at 60fps with no re-composition, works while paused, and overlays scroll with their page. The publish path bakes them. |
| Live look changes on video | A **live-look board**: a lock-protected value the compositor reads on every frame. A paused frame is re-finished from the last base image the compositor kept. **No new player item** is built. | Rebuilding the item or reader at 60Hz during a slider drag is not viable. Crop, segment filters and the soundtrack are discrete changes and do reload the item, as transitions already do. |
| Where animated stickers come from | New package `ROOT/Packages/Core/StickerKit`. The 12 `.lottie` files and the catalogue move there from Chat. | Features cannot import each other. Lottie can only be rendered on the main actor, so frames are **baked ahead of time** at 30fps into PNG `Data` strips that the compositor can read. |
| Emoji source | Built at runtime from `Unicode.Scalar.Properties`, plus flags from `Locale.Region.isoRegions`. Each entry is kept only if Apple Color Emoji draws it as one glyph (`CTLineGetGlyphCount == 1`). | Needs no download. Getting ZWJ sequences (families, professions) would require downloading `emoji-test.txt`, which needs the user's permission, so it is a follow-up. |
| Soundtrack scope | One soundtrack per **video** item, stored in `MediaEdits.soundtrack`. On a photo page the pill shows a notice in the band. | Photo attachments cannot carry audio. |
| Preview audio | The editor's player is **unmuted while a soundtrack is attached**. The audio session switches to `.playback` while the editor is visible with a soundtrack, then back to `.ambient`. | Today every player is muted (`MP/VideoPlaybackController.swift:399`) under `.ambient` (`:218`), so the song could never be heard. |
| Undo arrow in each new mode | Effects: reset adjustments and effect. Filters: back to Original. Song: reset excerpt and volumes (a Remove button exists). Text and Stickers: **disabled** (each overlay has its own delete). Trim: unchanged; resetting pieces also drops their filters, which belong to the pieces. | Avoids one-tap destructive resets. |
| Tapping the category that is already selected | Add `IconSelectorBar.onReselect`. | Today a tap on the selected icon is silent (`DS/IconSelectorBar.swift:322-323`). "Effects" is index 0 and selected at launch with an empty band, so without this Effects could never be opened on first entry. |

---

## 1. Preconditions and what this plan assumes from PR 1

- PR 2 branches from `develop` **after PR 1 merges** (memory `editor-completion-decisions`). The current worktree has uncommitted PR-1 work and a scratch test, `MT/ScratchComposedPlaybackTests.swift` ("Deleted before commit"). Neither may appear in PR 2.
- Assumed PR 1 contract. If PR 1's names differ, only slice S2 adapts; none of the value types below change.
  - `VideoCompositor: AVVideoCompositing`, with one shared Metal `CIContext`.
  - A custom instruction class (`NSObject, AVVideoCompositionInstructionProtocol`, `@unchecked Sendable`, immutable `let`s) carrying: lane A/B track IDs, per-track orientation, and an optional transition (kind plus progress window).
  - `VideoExporter.arrangement(of:cut:orientation:)` still builds both preview and export.
  - The preview never sets `item.videoComposition`. `AVAssetReaderVideoCompositionOutput` feeds `VideoFrameSource`/`VideoFrameRenderer` in step with the item's timebase, and seeking while paused recreates or repositions the reader.
  - 14 transition kinds exist in `VideoTransitionKind`.
- Simulators (memory `simulator-roster`):

  | Device | Runtime | UDID |
  |---|---|---|
  | iPhone 18 Pro | iOS 27 | `710B76BE-…` |
  | iPhone SE 2nd gen | iOS 27 | `99CE52A6-…` |
  | iPhone 17 Pro Max | iOS 26.5, the same OS family as CI | `B7811136-…` |

  CI runs Xcode 26 on an iOS 26 simulator (`ROOT/.github/workflows/ci.yml`), so no iOS 27-only API may be used. New packages are found automatically by `ROOT/.github/scripts/select_packages.py`.

---

## 2. Current state and gaps

### 2.1 The editor, `UP/Views/MediaEditorViewController.swift` (3,202 lines)

| Area | Where | What it does today |
|---|---|---|
| Categories | `:105-120` | Effects, Text, Stickers, Filters, Crop, Trim. **Tests hard-code the indices** (`Mode.trim = 5`, `filters = 3` in `UT/MediaEditorTransitionsTests.swift:21-24`). Do not reorder. |
| `TrackAction` (split, speed) and `actionBar` | `:167-207` | Two items. |
| Undo arrow | `resetTheCurrentMode` `:245-251`, `refreshResetItem` `:272-289` | Handles timeline or crop only. |
| Per-item edits | `edits` `:316`; `change(_:_:)` `:423-427` removes neutral entries | |
| Photo render | `render` `:395-412` (off-main, latest wins), `draw` `:416` | Calls `MediaEdits.applied`. |
| Filter row | `filterRow` `:432-439`, `refreshFilterRow` `:1182-1202`, `applyFilter`/`redraw`/`show` `:1760-1803` | |
| Sound pill | `soundPill` `:547` | Comment says "DRAWN, AND WIRED TO NOTHING". |
| Save draft | `saveDraftItem` `:562-569` | Inert (out of scope). |
| **Mode switch** | `showAccessory(for:)` `:1142-1174` | Filters shows `filtersUnavailable` on a video (`:1156-1157`). Trim and Crop are wired. **Effects, Text and Stickers fall to `default: setEditingAccessory(nil)` (`:1171`) and do nothing.** |
| Toolbar leading slot | `refreshToolbarItems` `:1062-1074` | Pill or action bar. |
| Toolbar sharing | `shareTheBarBetweenTheTwoStrips` `:1088-1107` | Applies `EditorSelectorLayout`. |
| Timeline | `refreshTimelineTrack` `:1227-1299`, `followPlayhead` `:1388-1435` | |
| Preview | `PreviewSubject` `:1447-1459`, `loadPreview` `:1501-1554`, `refreshPreview` `:1559-1573` | **The plan carries only `sourceURL` and `segments`** (`:1521-1524`). |
| Scrubbing and rates | `scrubbed` `:1621-1648`, `aim` `:1658-1675`, `scrubbing` `:1682-1708` | |
| Timeline tools | `:1943-1984` | |
| Transitions | `:1997-2131`: `TransitionFocus`, `rehearsal`, `openTransitions`, `chooseTransition`, `landOnTheFocus`, `closeTransitions` | Pattern to mirror for segment filters. |
| Split, rates, action enablement | `splitAtTheNeedle` `:2150`, `toggleTheRateChips` `:2179`, `targetPiece` `:2199`, `chooseRate` `:2215`, `refreshTrackActions` `:2239-2257` | |
| Tap on media | `mediaTapped` `:2279` | Comment `:2271-2278` expects a guard to return "with the compositor". |
| Notices | `trimUnavailable` `:2307`, `trimTooShort` `:2317`, `filtersUnavailable` `:2322`, `cropUnavailable` `:1929` | |
| Crop | `enterCrop` `:2369-2434`, **refuses video** `:2371-2382`; lock at `:2386-2406`; `exitCrop` `:2472`; `showCropPicture` `:2533`; `dress` `:2563` | `dress` applies only `filter`. |
| Stack gestures | `updateStackGestures` `:2603`, `setStackGesturesEnabled` `:2623-2636` | One predicate: `isCropping \|\| isTouchingStrip`. |
| Page cell | `MediaEditorPageCell` `:2640-2805` (`picture` plus `VideoRenderView` pinned to it; `lay(_:within:)`) | |
| Playing the settled page | `playSettledPage`/`stopPreview` `:2821-2872` | |
| Settle hooks | `:2885-2920` (three copies) | |
| Band funnel | `setEditingAccessory` `:2944-2985` | Must stay outside `#if DEBUG`. |
| Debug hooks | `:2988-3179` | |
| **Access levels** | Nearly every member is `private` | An extension or mode file in another file **cannot reach them**. |

### 2.2 Data model

- `UP/Data/MediaEdits.swift:24-83`
  - Fields: `fit`, `filter`, `crop`, `timeline`.
  - **`signature` is written by hand** (`:64-66`).
  - `applied(to:)` crops, then applies the filter (`:79-82`), with two separate CI renders.
- `UP/Data/MediaFilter.swift:18-94`: 9 `CIPhotoEffect` looks. The renderer keeps its own static context.
- `UP/Data/MediaCrop.swift:19-80` (rect is a fraction of the **turned** bounding box, plus angle and `isMirrored`). `MediaCropRenderer` at `:94-184` turns the image upright first.
- `UP/Data/MediaTimeline.swift`: `MediaSegment` `:21-52` (start, end, speed, transitionOut) and `MediaTimeline` `:69-79`.
- `UP/Data/MediaTimeline+Export.swift`: `exportSegments` `:15-27`; `playsTheSame` `:44-55` **merges touching pieces at the same rate** (`film` `:67-89`).
- `UP/Data/MediaTimelining.swift`:
  - `split` `:293-315` copies the piece, so new fields are inherited automatically.
  - `setRate` `:355`, `resolved` `:1058-1106` ("a copy, not a rebuild").
  - **`cuts` `:1135-1143` looks only at start, end and speed.**
  - `reordered` `:1152`, `settled` `:1170`, `seams` `:1198`, `settingTransition` `:1229`, `rehearsal` `:1245`.
- Drafts:
  - `UP/Views/PostDraft.swift:27-41` holds only title, caption, settings and cover, for the session only.
  - `UP/Views/MediaDraftsViewController.swift:13-35` is an empty list.
  - Edits survive moving back and forward only because the editor stays in the navigation stack (`UP/UploadFeatureBuilder.swift:60-71`). **Nothing is saved to disk.**

### 2.3 Export, playback and publish

- `MP/VideoExporter.swift`
  - `VideoExportPlan` `:39-78` (sourceURL, segments, preset); its doc says the builder slot is "not here yet".
  - `VideoTransitionKind` `:88`, `VideoExportSegment` `:103-125`, `needsComposition` `:153-155`.
  - `insertPieces` `:217-258` calls **`scaleTimeRange` on the composition while inserting**.
  - `arrangement` `:313-358` (empty segments means the file itself), `soundDips` `:519-540`.
  - `export` `:548-633`: passthrough override `:571-574` covers **only the video composition**; **dimensions are read from the SOURCE track** (`:612-616`).
  - Posters `:654-725` are read from the exported file.
- `MP/VideoPlaybackController.swift`: `load(plan)` `:450-528`, `swap` `:535-565`, `bindFresh` `:381-406` mutes every player.
- `UP/Views/MediaPreviewPlayer.swift`: the `MediaVideoPreviewing` protocol `:18-109` has **4 test stubs**:
  - `UT/MediaEditorPlaybackTests.swift:62`
  - `UT/MediaEditorTimelineTests.swift:59`
  - `UT/MediaEditorTrackToolsTests.swift:57`
  - `UT/MediaEditorTransitionsTests.swift:51`
- `UP/Views/NewPostViewController.swift`, `post()` `:643-738`:
  - Video builds `PickedVideo(sourceURL:keptPieces:)` (`:701-703`).
  - Photo bakes with `applied(to:)` **on the main actor** (`:725`); `publishPixels` is 1080 (`:132`).
- `UP/Views/NewPostCells.swift:92-156`: the thumbnail cache key is `signature` (`:102`), and video posters also go through `applied(to:)` (`:154`).
- `UP/Data/PostComposer.swift`: `PickedVideo` `:18-44` (Equatable), `uploadVideo` `:248-291`.

### 2.4 Other UI parts

| Part | Location | Notes |
|---|---|---|
| Band host | `UP/Views/MediaEditorBandView.swift:31-76` | `BandNoticeView` at `:93-119`. |
| Timeline tools | `UP/Views/MediaTimelineToolsView.swift:37-134` | Stack of speeds and track; transitions row overlaid on the collapsed track. |
| Track | `UP/Views/MediaTimelineTrackView.swift` | `setCompact` `:2243` **deselects the held piece**; `showRehearsal` `:2317`; `selectedPiece` `:732`; `onSelect` `:215`. |
| Transitions row | `UP/Views/MediaTransitionRowView.swift:35-347` | Cards 56×42, fade mask on a host view, glass close button; height from `:64-66`. |
| Filter row | `UP/Views/MediaFilterRowView.swift:27-156` | 56pt chips plus caption; `ChipScrollView` `:177-220`. |
| Action bar | `DS/IconActionBar.swift` | `setEnabled` `:180`, `setActive` `:195`. |
| Category bar | `DS/IconSelectorBar.swift` | `tapped` `:322-332` is silent on a repeat tap. |
| Sound pill | `DS/SoundPillView.swift:22` | No action, no way to change the title. |
| Chat stickers | `CH/Views/FavoriteStickerCatalog.swift:14-121`, `CH/Views/FavoriteStickerStripView.swift`, `CH/Resources/Stickers/*.lottie` | 12 files, all **512×512, 60fps, about 3s (136–180 frames)**. Lottie 4.6.1 is declared in Chat's `Package.swift`. |

### 2.5 Gaps

| Category | Photo | Video |
|---|---|---|
| Effects | nothing | nothing |
| Text | nothing | nothing |
| Stickers | nothing | nothing |
| Filters (whole media) | done: 9 presets | **refused** (`:1156`) |
| Filters (per segment) | not applicable | nothing: no field, no action, no row |
| Crop | done | **refused** (`:2371`) |
| Trim, split, speed, order, transitions | not applicable | done |
| Add a song | inert pill | inert pill; preview muted |
| Publish bakes | crop and filter | trim, speed, order, transitions only; **dimensions wrong once crop exists** |

---

## 3. Data model

### 3.1 New MediaPlayback types (`MP/Editing/`, all `public`, `Sendable`, `Equatable`)

These names are fixed now so that agents working in parallel agree on them.

```swift
// MP/Editing/FrameLook.swift
public enum LookPreset: String, CaseIterable, Sendable {           // moved from Upload's MediaFilter
    case original, chrome, fade, instant, mono, noir, process, tonal, transfer
}
public struct LookAdjustments: Equatable, Sendable {
    public var brightness = 0.0, contrast = 0.0, saturation = 0.0, warmth = 0.0  // -1...1
    public var highlights = 0.0, shadows = 0.0                                    // -1...1
    public var sharpness = 0.0, vignette = 0.0, grain = 0.0                       // 0...1
    public static let neutral = LookAdjustments()
    public var isNeutral: Bool { self == .neutral }
    public enum Key: String, CaseIterable, Sendable { case brightness, contrast, saturation, warmth,
        highlights, shadows, sharpness, vignette, grain
        public var range: ClosedRange<Double> { ... } }
    public subscript(key: Key) -> Double { get set }   // setter clamps, and snaps |v| < 0.005 to 0
}
public enum LookEffectKind: String, CaseIterable, Sendable {
    case blur, pixellate, rgbSplit, vhs, posterize, comic, bloom, zoomBlur, crystallize, halftone, thermal, xray
}
public struct LookEffect: Equatable, Sendable { public var kind: LookEffectKind; public var intensity: Double } // 0...1
public struct FrameLook: Equatable, Sendable {
    public var preset: LookPreset = .original
    public var adjustments: LookAdjustments = .neutral
    public var effect: LookEffect? = nil          // intensity 0 is normalised to nil by the setters that write it
    public static let neutral = FrameLook()
    public var isNeutral: Bool { preset == .original && adjustments.isNeutral && effect == nil }
}

// MP/Editing/FrameCrop.swift  (moved from Upload's MediaCrop, same semantics and doc)
public struct FrameCrop: Equatable, Sendable {
    public var rect: CGRect; public var angle: CGFloat; public var isMirrored: Bool
    public init(rect: CGRect = .init(x: 0, y: 0, width: 1, height: 1), angle: CGFloat = 0, isMirrored: Bool = false)
    public static let untouched = FrameCrop()
    public var isUntouched: Bool { self == .untouched }
}

// MP/Editing/FrameOverlay.swift
public struct OverlayPlacement: Equatable, Sendable {
    public var centre: CGPoint     // fractions of the FINISHED (cropped) frame, origin TOP-LEFT
    public var scale: Double       // 1 = the content's base size (a fraction of the frame width)
    public var rotation: Double    // radians, clockwise as the viewer sees it
}
public struct OverlayColour: Equatable, Sendable { public var r, g, b, a: Double }  // sRGB
public enum OverlayFont: String, CaseIterable, Sendable {
    case classic, rounded, serif, mono, condensed, marker, typewriter, script }
public enum TextBackground: String, CaseIterable, Sendable { case none, highlight, box }
public enum OverlayTextAlignment: String, CaseIterable, Sendable { case leading, centre, trailing }
public struct TextOverlay: Equatable, Sendable {
    public var text: String; public var font: OverlayFont; public var colour: OverlayColour
    public var background: TextBackground; public var alignment: OverlayTextAlignment }
public struct FrameOverlay: Equatable, Sendable, Identifiable {
    public enum Content: Equatable, Sendable { case text(TextOverlay), emoji(String), sticker(id: String) }
    public let id: String            // a UUID string made by the editor; the array order is the z-order
    public var content: Content
    public var placement: OverlayPlacement
}
/// Sticker pictures. MediaPlayback never imports Lottie: frames arrive already baked.
public protocol OverlayArtwork: Sendable {
    func sticker(_ id: String, atSeconds seconds: Double, side: Int) -> CGImage?
}
public struct FrameFinish: Equatable, Sendable {
    public var crop: FrameCrop = .untouched
    public var look: FrameLook = .neutral
    public var overlays: [FrameOverlay] = []
    public static let none = FrameFinish()
    public var isNone: Bool { self == .none }
}

// MP/Editing/VideoSoundtrack.swift
public struct VideoSoundtrack: Equatable, Sendable {
    public var fileURL: URL          // an app-owned temporary copy
    public var title: String
    public var startSeconds: Double  // where the excerpt starts, in seconds of the SONG
    public var musicVolume: Double = 1
    public var originalVolume: Double = 1
}

// MP/Editing/VideoLiveLook.swift  (preview only)
public final class VideoLiveLook: Sendable {   // backed by Mutex from the Synchronization module (iOS 18+)
    public init(_ look: FrameLook)
    public func set(_ look: FrameLook)
    public var look: FrameLook { get }
    // S2 adds: the last base image (after crop, before look) and its time, for re-finishing a paused frame
}
```

Additions to existing types, all with defaults so no current call site changes:
- `VideoExportSegment.look: LookPreset?`. `nil` means no filter; `.original` is never stored.
- `VideoExportPlan.finish: FrameFinish = .none`, `.soundtrack: VideoSoundtrack? = nil`, `.artwork: (any OverlayArtwork)? = nil`.
- `VideoExporter.needsComposition(for plan:)` is true when any of these holds: `segments.count > 1`, a segment is not as shot, a segment has a `look`, `!finish.isNone`, or `soundtrack != nil`.

`VideoExportPlan` is `Sendable` and not `Equatable`, so carrying `any OverlayArtwork` is fine.

### 3.2 Upload model (`UP/Data/…`)

```swift
typealias MediaFilter = LookPreset     // MediaFilter.swift keeps `name` in an extension; the renderer is re-pointed
typealias MediaCrop = FrameCrop        // MediaCrop.swift keeps MediaCropRenderer, which calls the shared CI graph

struct MediaEdits: Equatable, Sendable {
    var fit: ContentFit = .fill
    var filter: MediaFilter = .original
    var adjustments: LookAdjustments = .neutral
    var effect: LookEffect? = nil
    var crop: MediaCrop = .untouched
    var timeline: MediaTimeline = .whole
    var overlays: [FrameOverlay] = []
    var soundtrack: VideoSoundtrack? = nil

    var look: FrameLook { FrameLook(preset: filter, adjustments: adjustments, effect: effect) }
    func finish(includingOverlays: Bool) -> FrameFinish
    var signature: String {   // STILL WRITTEN BY HAND — every field, in declaration order
        "\(fit)/\(filter.rawValue)/\(adjustments)/\(effect.map { "\($0)" } ?? "-")/\(crop)/\(timeline)/\(overlays)/\(soundtrack.map { "\($0)" } ?? "-")"
    }
    /// Cut → look → overlays, as ONE CI graph and ONE render. nonisolated.
    func applied(to image: UIImage, artwork: (any OverlayArtwork)?, includingOverlays: Bool = true) -> UIImage
}
extension MediaEdits {   // new file UP/Data/MediaEdits+Plan.swift — the ONE mapping, used by preview and publish
    func exportPlan(sourceURL: URL, fileSeconds: Double,
                    artwork: (any OverlayArtwork)?, includingOverlays: Bool) -> VideoExportPlan
}

struct MediaSegment { …; var filter: MediaFilter? }   // nil = none; `.original` is normalised to nil
```

Rules that must hold:
- **"Absent means untouched" still holds.** All defaults are neutral, and the setters normalise:
  - an adjustment within ±0.005 becomes 0;
  - an effect with intensity 0 becomes `nil`;
  - a segment filter `.original` becomes `nil`.
- **Automated signature completeness test** (`UT/MediaEditsSignatureTests.swift`):
  1. Read the field labels with `Mirror(reflecting: MediaEdits())` and assert they equal the keys of a table of mutations. A new field with no entry in the table fails here.
  2. For each mutation, assert that `signature` changes.
  3. Break check: remove `/\(overlays)` from `signature` and the test must fail.
- The same Mirror-based completeness test applies to:
  - `MediaSegment`: every field, when changed, makes `playsTheSame` false;
  - `exportSegments`: every field reaches `VideoExportSegment`;
  - `FrameLook.isNeutral` and `FrameFinish.isNone`.

### 3.3 Timeline arithmetic (`MediaTimelining`)

- `settingFilter(_:atPiece:in:withinSource:)`, modelled on `settingTransition`.
- `split` copies the piece, so **both halves keep the filter**. Pin this with a test.
- `reordered` moves the filter with its piece; `setRate` and `moved` keep it; `settled` is unchanged.
- **`cuts(_:)` returns true if any resolved piece has a filter.** Otherwise a filter on an uncut, single-piece clip resolves to `exportSegments == []` and is silently dropped.
- `playsTheSame`: `Stretch` gains `filter`, and touching pieces are merged **only if their filters are equal**.
- `rehearsal(ofPiece:in:withinSource:cap:)`: the piece's played range, capped at 6s from its start.
- `exportSegments` maps `filter` to `look`.

### 3.4 Draft persistence

There is none today and none is added.
- Do **not** add `Codable`: it would be an unused slot.
- Temporary files (imported audio, copied movie audio) are owned by a new `TempFileBag` (a `Sendable` final class with a `Mutex`; its `deinit` deletes the files). `PostDraft` holds it, so the files live as long as the sheet and outlive publishing.
- Baked sticker strips are memory caches, not state.
- Written down for a future media-draft store: imported audio must be copied into Application Support; overlays and looks are plain values; sticker art can always be baked again.

---

## 4. Rendering

### 4.1 One pipeline

```
VIDEO (per output frame, in the compositor, composition time t):
  laneA = source(trackA) → upright(preferredTransform) → segmentLook(A)         // FrameLookRenderer(preset only)
  laneB = … (only inside a transition window)
  frame = transition(laneA, laneB, progress) ?? laneA                            // PR 1
  frame = FrameCrop.applied(frame)          → extent (0,0,renderW,renderH)
  frame = FrameLookRenderer.apply(whole look, to: frame, time: t)
  frame = OverlayRasterizer.composite(overlays, over: frame, time: t, artwork:)  // export only (editor: views)
  render → output buffer
PHOTO (MediaEdits.applied, nonisolated):
  upturned(UIImage) → CIImage → FrameCrop.applied → FrameLookRenderer.apply(time: 0)
  → OverlayRasterizer.composite(time: 0, artwork: stills) → ONE createCGImage
```

- One shared context, `EditingRenderContext.shared` = `CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])`. It replaces the static contexts in `MediaFilterRenderer`/`MediaCropRenderer`, and it is PR 1's context if PR 1 already exposes one.
- **Each CI function only builds a graph** (`CIImage → CIImage`). Rendering happens once, at the end. Today's photo path renders twice.

### 4.2 `FrameLookRenderer` (`MP/Editing/FrameLookRenderer.swift`)

- It is a `nonisolated` enum. It creates **new `CIFilter` instances on every call**, because `CIFilter` is not `Sendable` (`CIImage` and `CIContext` are: `NS_SWIFT_SENDABLE` in `CIImage.h:33` and `CIContext.h:56`).
- Each stage is skipped when neutral. A neutral look returns the **same** `CIImage` object.
- **Every stage crops back to the input extent.** `CIRandomGenerator` produces an infinite image, and blurs spread past the edges. A test covers this.

| Stage | Built-in filters |
|---|---|
| brightness, contrast, saturation | one `CIColorControls` (brightness ×0.2, contrast 1±0.5v, saturation 1+v) |
| warmth | `CITemperatureAndTint`, neutral 6500. The direction is **pinned by a test**, not assumed. |
| highlights, shadows | `CIHighlightShadowAdjust` |
| preset | `CIPhotoEffect*`, the mapping moved from `UP/Data/MediaFilter.swift:47-59` |
| effect | recipe below, then `CIMix(amount: intensity)` against the stage input |
| sharpness | `CISharpenLuminance` |
| vignette | `CIVignetteEffect`, centre and radius in **pixels relative to the extent**, so it does not depend on size (test at 1× and 2× size) |
| grain | `CIRandomGenerator`, translated by (t·997 mod 512, t·613 mod 512), turned to mono with small amplitude by `CIColorMatrix`, cropped, `CISoftLightBlendMode`, then mixed by v |

Effect recipes (all built in; **no custom Metal kernels**, which would need SwiftPM `-fcikernel` build flags):

| Effect | Recipe |
|---|---|
| blur | `CIGaussianBlur` on `clampedToExtent`. For radii above 8px: downsample to ¼, blur, then upsample. Radius = i·3% of the short side. |
| pixellate | `CIPixellate`, scale = max(2, i·5% of width), centred |
| rgbSplit | red channel (`CIColorMatrix`) shifted +d, blue shifted −d, green in place, joined with `CIAdditionCompositing`; d = i·1.2% of width |
| vhs | small rgbSplit + horizontal scanlines (`CIStripesGenerator`, rotated) multiplied + time-shifted noise in soft light + saturation 0.8 + `CIMotionBlur` of radius 2 |
| posterize | `CIColorPosterize`, levels 30−26i |
| comic | `CIComicEffect` |
| bloom | `CIBloom` |
| zoomBlur | `CIZoomBlur`, centred |
| crystallize | `CICrystallize` |
| halftone | `CIDotScreen` |
| thermal | `CIThermal` |
| xray | `CIXRay` |

### 4.3 Crop in Core Image

- `FrameCrop.applied(to: CIImage) -> CIImage?` does exactly what `MediaCropRenderer.apply` does (`UP/Data/MediaCrop.swift:99-152`): mirror, then straighten (negated angle), then cut in fractions of `straightened.extent` **with the y axis flipped**. Then **translate to the origin** so the video output extent starts at (0,0).
- `outputSize(forUpright:)` = turned size × rect size, rounded to an even number of pixels, at least 2.
- `MediaCropRenderer.apply(_:to UIImage)` keeps its upright turn (`upturned`, `:175`) and then calls the shared graph.
- `MediaCropTests`, `MediaCropBakeTests` and `MediaCropGeometryTests` are the regression net.

### 4.4 Overlay rasterisation (`MP/Editing/OverlayRasterizer.swift`, `OverlayRasterCache.swift`)

- **Text uses Core Text** (`CTFramesetter`/`CTLine`) drawn into a `CGContext`. This is thread-safe and needs no main actor. `UIFont` is `NS_SWIFT_SENDABLE` (`UIFont.h:19`), and `UIGraphicsImageRenderer` already runs off-main in this repo (`UP/Data/MediaCrop.swift:175-183`, reached from `Task.detached` at `MediaEditorViewController.swift:397`).
  - Point size in pixels = 0.06 × output width × scale.
  - `highlight` draws rounded rectangles behind each line and picks a contrasting ink.
  - `box` draws one rounded rectangle at 60% black behind the whole block.
  - Fonts are resolved by name, or by `UIFontDescriptor` design for the rounded, serif and mono families. **A test checks every `OverlayFont` resolves** (`UIFont(name:)` is not nil).
- **Emoji** are drawn with Core Text in `AppleColorEmoji`. Base size = 0.18 × width × scale.
- **Stickers**: `artwork.sticker(id, atSeconds: t mod stripDuration, side:)`, at the same base size.
- **Composite**: `CIImage(cgImage:)` is transformed by scale, then rotation, then translation to the centre **with the y axis flipped** (Core Image's origin is bottom-left), then `composited(over:)`. Tests use top-versus-bottom placements to catch a flip mistake.
- **Cache**: an LRU keyed by (content, pixel size) holding `CGImage`s, about 64 MP of pixels total, protected by a `Mutex`. Text and emoji are rasterised once per render size. Sticker frames are not cached here; the strip keeps its own one-frame decode cache.

### 4.5 Compositor hooks (slice S2, in PR 1's files)

- The instruction gains `laneLooks: (LookPreset?, LookPreset?)`, `finish: FrameFinish`, `artwork`, and `live: VideoLiveLook?` (preview only).
- **Instructions must be split at every piece boundary, not only at transition windows.** Today `plain(until:)` (`MP/VideoExporter.swift:463-467`) makes one instruction that spans several pieces, which cannot carry a per-piece look.
- Render size = `finish.crop.outputSize(forUpright: naturalUpright)`.
- **Preview**: `Configuration.renderScale` (present in the iOS 26/27 Swift interface) is set so the longer side is at most 1280px.
- Time-based stages use `request.compositionTime`.
- Export route:
  - With empty segments but a finish or soundtrack, build `[0…duration]` as a single piece.
  - The passthrough override also applies when `audioMix != nil` or a soundtrack exists (passthrough ignores both; `:567-574`).
  - `ExportedVideo` dimensions are read from the **output** file's track, with its transform applied.

### 4.6 Preview on the canvas

**Photo**
- A look change writes `edits`, then `redraw`, then the existing latest-wins `render` (`:395-412`) with `includingOverlays: false`.
- While a slider is being dragged, the spinner (`beginRender`, `:373`) is suppressed so it does not flash.

**Video**
- `loadPreview` builds the plan with `edits.exportPlan(…, artwork: nil, includingOverlays: false)`. The controller creates a `VideoLiveLook` for each load, starting from `plan.finish.look`.
- A whole-look change calls `preview.setLiveLook(look, in: surface)`:
  - while playing, the next composed frame picks up the new look;
  - **while paused**, the controller re-finishes the base image the compositor kept (after crop, before look) off the main thread, latest wins, and enqueues the result through the renderer.
  - Fallback if S2 finds the kept base unworkable: a coalesced "re-read the current time" through the reader, at most one in flight.
- **A new player item is built only when** `playsTheSame` fails (which now includes filters), the crop changes, or the soundtrack changes. `PreviewSubject` gains `crop` and `soundtrack`.
- The segment-filter row loops the focused piece, as transitions do.

**Overlays**
- Drawn as `MediaOverlayItemView`s in a `MediaOverlayLayerView` pinned to the page's `picture`.
- The image comes from the same `OverlayRasterizer` at screen scale. A pixel-parity test compares the view's image with the rasteriser output.
- Stickers: a still on photos; a looping `StickerLoopView` on videos (Core Animation engine, loop mode set **after** the load; memory `chat-sticker-strip`).

**Poster before the first composed frame**
- `applied(to:, includingOverlays: false)`, plus piece 0's filter first (added in S7), so the poster matches the first composed frame.

### 4.7 Thread safety

| Item | Isolation |
|---|---|
| `LookPreset`, `FrameLook`, `FrameCrop`, `FrameOverlay`, `FrameFinish`, `VideoSoundtrack` | Values, `Sendable` |
| `CIImage`, `CIContext`, `CGImage`, `UIFont`, `UIImage` | `Sendable` (SDK annotations) |
| `CIFilter` | **Not** `Sendable`: create per call, never store |
| `VideoLiveLook`, `OverlayRasterCache`, `StickerStrip` decode cache, `TempFileBag` | `final class: Sendable` with `Mutex` |
| Instruction objects | `@unchecked Sendable`, immutable |
| Lottie rendering | **Main actor only** (`CH/Views/FavoriteStickerCatalog.swift:92-111`): bake ahead of time, in chunks with `Task.yield()` |
| `PHPicker`/`NSItemProvider` callbacks | Arbitrary queue: callbacks must be `@Sendable`; **copy the file inside the callback** (it is deleted when the callback returns), then resume with a `URL` only (memory `photos-handler-isolation-trap`) |
| `AVMutableComposition`, `AVMutableAudioMix` | `@_nonSendable`: build them where they are used |
| Isolation probes | `swiftc -typecheck` skips region isolation; use `-emit-sil` or a full build |

### 4.8 Cost and memory budget (iPhone SE 2nd gen, A13, 3GB)

- **Compositor**: at most 25 ms per frame at preview scale (longer side ≤ 1280).
  - Add a DEBUG `-look-probe` flag that logs the worst and mean frame time per second.
  - Blur must use the downsample path. Only one stylised effect is allowed at a time.
- **Photo live render**: canvas size (about 1.4 MB), under 30 ms, latest wins.
- **Stickers**: raw 512px at 60fps would be about 176 MB per sticker.
  - Bake at **30fps**, side at most 256px for preview and at most 384px for export.
  - Store as **PNG `Data`**, a few MB per sticker. Decode on demand, keeping one decoded frame per strip.
  - Limit: 10 animated stickers per video; show a notice beyond that.
- **Overlay cache**: at most 64 MP. **`CIContext`**: `cacheIntermediates: false`.
- **Waveform**: at most 1 peak per 10 ms, as `[Float]`.

---

## 5. Soundtrack ("Add a song")

**Sources**
- A seam, `MediaSoundtrackSourcing`, is injected into the editor's `init` with a default value, so tests can skip the real pickers.
- **Files**: `UIDocumentPickerViewController(forOpeningContentTypes: [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .movie], asCopy: true)`, then copy to `tmp/UploadSoundtracks/<uuid>.<ext>` and register the file in the `TempFileBag`.
- **From another video**: `PHPickerViewController` (filter `.videos`, limit 1, no library permission needed), `loadFileRepresentation(forTypeIdentifier: UTType.movie)`, then copy inside the callback.

**Validation** (`AVURLAsset`): it has an audio track, `isPlayable`, `!hasProtectedContent`, and a duration of at least 1s. Otherwise show a notice in the band.

**Composition** (new file `MP/VideoExporter+Soundtrack.swift`, called from one hook line in `arrangement`)
1. **Insert the music track after every `scaleTimeRange`**, over `[0, composition.duration]` from `startSeconds`, clipped to the song's length (no looping in version 1). `scaleTimeRange` rescales every track inside the range (`:250-255`), so music inserted earlier would be sped up or slowed down with the rated pieces.
2. Audio mix: music uses one constant `setVolume(_, at: .zero)`. The original track uses a constant `originalVolume`, and the existing dips are scaled by it (from originalVolume down to 0 and back).
3. **No music ramps in version 1.** Memory `export-volume-ramp-hang`: new audio automation must be **stress-exported 12 or more times with a watchdog** (`exportAsynchronously` plus `cancelExport`).
4. A soundtrack forces composition and the passthrough override.

**Preview**
- The item contains the music track, so it plays in step with the item's clock.
- New protocol and controller API:
  - `setMuted(_:in:)`
  - `setMixLevels(music:original:in:)`: replaces `item.audioMix` live; the controller remembers the track IDs for each item.
- `MediaPreviewPlayer` switches the audio session to `.playback` while it is unmuted, and back on stop.

**Band tenant `MediaSoundtrackToolsView`**
- Row 1: [Files] [From a video] [Remove], plus the title.
- Row 2: `MediaWaveformExcerptView`: the waveform scrolls under a fixed window as wide as the film's played length. The start is stored **when the finger lifts**, and the item then reloads at the same played second.
- Row 3: two `UISlider`s (Song, Original), applied live through `setMixLevels` and stored when the finger lifts.
- Waveform data: `MP/AudioWaveform.swift`, a `nonisolated` async function using `AVAssetReader` with 16-bit mono PCM and the maximum per bucket.
- The pill shows "Song: <title>" once a song is set (`SoundPillView.setTitle`).

---

## 6. UI for each mode

### 6.1 Structure (slice S0)

- **Mode objects**, each a `@MainActor final class` in its own file under `UP/Views/Editor/`:
  - `MediaEditorEffectsMode`
  - `MediaEditorFiltersMode` (the existing filter-row code, moved as-is)
  - `MediaEditorSegmentFilterMode`
  - `MediaEditorOverlayMode` (shared by Text and Stickers)
  - `MediaEditorSoundtrackMode`
- Each conforms to:
  ```swift
  @MainActor protocol MediaEditorMode: AnyObject {
      var tenant: UIView? { get }
      func open(for id: String, item: MediaLibraryItem)
      func bandWillChange(to accessory: UIView?)   // closes rows or sheets
      func pageDidSettle(on id: String?)
      func screenWillDisappear()
      var canReset: Bool { get }
      func reset()
  }
  ```
- The editor offers them a `MediaEditorHosting` protocol, implemented in `UP/Views/MediaEditorViewController+Host.swift`:
  - `currentItemID`, `item(_:)`, `edits(for:)`, `change(_:_:)`, `editsDidChange(_:_ kind: EditKind)` (redraws a photo, sets the live look, or reloads the preview)
  - `library`, `heldPicture` (`lastSource`), `showInBand(_:)`, `canvasSize`
  - `lockCanvas(by:)` / `unlockCanvas(by:)`
  - `playingSurface`, `preview`, `timelineTools`, `actionBar`, `trackSeconds`, `fileSeconds(for:)`
  - `presentSheet(_:)`, `pageCell(for:)`
- **Access**: the members listed above change from `private` to internal. They stay in the main file.
- **Canvas lock generalised**: `canvasLocks: Set<CanvasLockOwner>` with owners `.crop` and `.overlays`.
  - The code at `:2386-2406` moves into `lockCanvas`/`unlockCanvas`.
  - `updateStackGestures` becomes `setStackGesturesEnabled(canvasLocks.isEmpty && !isTouchingStrip)`, keeping the single-slot guarantee from memory `media-crop-straighten`.
- `MediaEditorPageCell` moves as-is to `UP/Views/MediaEditorPageCell.swift`, with an empty `overlayHost: MediaOverlayLayerView` pinned to `picture`.

### 6.2 Effects (S5), photo and video

- **Tenant `MediaEffectsToolsView`** (about 76pt, like the filter row).
- **Browsing state**: a `ChipScrollView` row with an "Adjust" section, then a divider, then an "Effects" section.
  - Adjust cards (9): symbol plus word; a dot when the value is not neutral.
  - Effect cards: "None" plus 12 thumbnails rendered from `heldPicture`, cropped and with the current look.
- **Adjusting state**: [glass close button] [name and value] [`UISlider` with an iOS 26 `trackConfiguration` whose `neutralValue` is 0 for the two-sided tools; header `UISliderTrackConfiguration.h:32`].
  - Double-tapping the value label resets it. A selection haptic fires when crossing 0.
  - An effect card is exclusive; tapping it shows its intensity slider.
- **Where changes go**:
  - Photo: `change`, then `editsDidChange(.look)`, then `redraw`.
  - Video: `change`, then `setLiveLook` (no reload).
- **Undo arrow**: resets adjustments and effect only.

### 6.3 Filters (S6), whole media, photo and video

- Remove `filtersUnavailable` (`:2322`, `:1156`).
- Thumbnails come from `heldPicture` (for a video, its poster), with crop, adjustments and effect applied (`FrameLook(preset: p, …)`).
- Photo: redraw. Video: `setLiveLook`.
- Undo resets to Original.

### 6.4 Segment filters (S7)

- `TrackAction.filter` (symbol `camera.filters`, spoken "Filter this clip") is appended.
  - **Enabled only when** `timelineTrack.selectedPiece != nil`, no transition is focused, and the real length is known (`fileLengths[id] == trackSeconds`).
  - Split, speed and reset are disabled while the row is open (the `refreshTrackActions` rule, `:2239`).
- Tapping it:
  1. Record `SegmentFilterFocus(id, piece)` **before** collapsing: `setCompact(true)` calls `select(nil, notify: true)` (`MediaTimelineTrackView.swift:2250`).
  2. `timelineTools.openSegmentFilters(forPiece:chosen:rehearsal:)` collapses the track with the piece under the needle and lights the piece's range with `showRehearsal`.
  3. `MediaSegmentFilterRowView` opens (42pt tall: `MediaTransitionRowView.height`).
  4. The piece loops. The action bar shows `.filter` as active.
- **Extraction**: a shared `BandChoiceRowView` (fade mask on a non-scrolling host, `ChipScrollView`, glass close button, `setOpen` with the "no touches until landed" rule). `MediaTransitionRowView` becomes a thin client **with its debug hooks forwarded unchanged**. `MediaSegmentFilterRowView` is the second client.
  - Cards are 56×42: the filtered thumbnail fills the card (from the frame at the piece's midpoint via `preview.frames(…, height: 84)`, with the whole look on top), the word sits over a dark gradient, and the chosen card has a 2pt white ring. "None" comes first.
- **Choosing a card**: `settingFilter`, then `change`, then `timelineTrack.configure`, then `refreshPreview` (new item, loops the piece). Choosing the current value replays it.
- **Mutual exclusion**: opening one row closes the other. Every way off the clip closes the row (the same list as charter F30). `setEditingAccessory` closes it through `bandWillChange`.
- **Track**: a filtered piece shows a small `camera.filters` stamp next to its rate stamp, clamped into the viewport (charter F22 rule). The debug hook reads the symbol **from the image description**.
- **Charter** (`ROOT/dev/TIMELINE_CHARTER.md`): add F31 (action and enablement), F32 (collapse and row, cards, glass button), F33 (model: split, carry, `playsTheSame`, `cuts`, order relative to the whole filter), F34 (loop and every way off).

### 6.5 Crop on video (S8)

- `enterCrop` accepts video (remove `:2371-2382` and `cropUnavailable`).
- Picture: the frame under the needle when the timeline is open, otherwise under the playhead (played seconds mapped to source seconds), from `preview.frames(of:atSourceSeconds:[s], height: canvas pixel height, spacing: 0)`. Fall back to `heldPicture`.
- `dress` applies the full look (not only `filter`).
- The preview is already stopped while cropping (`playSettledPage`, `:2822`).
- `exitCrop` then `refreshPreview`: a new item with the new render size.
- Update the comment at `mediaTapped` (`:2271`): the crop surface covers the canvas, so no guard is needed.

### 6.6 Text (S9) and Stickers (S10): the overlay mode

**Opening the mode**
- Text or Stickers calls `lockCanvas(by: .overlays)`: no paging, `isModalInPresentation`, stack pans suspended.
- Overlay items become interactive; in every other mode they are drawn but inert (`isUserInteractionEnabled = false`).
- **Tenant `MediaOverlayToolsView`**: an "Add text" or "Add sticker" card, then one card per overlay of that kind (tap to edit or select; context menu: Delete, Bring to front).

**Gestures** (`MediaOverlayItemView`)
- Pan, pinch and rotation recognised together; tap selects; double tap edits text.
- An item's own tap **stops the canvas's play/pause tap** (memory `gesture-recognizer-prevention`), so tapping an overlay never toggles playback.
- Hit targets are at least 44pt.
- While dragging, `MediaOverlayTrashView` appears at the bottom centre; dropping on it deletes, with a haptic.

**Geometry** (`UP/Data/MediaOverlayGeometry.swift`, pure functions)
- `mediaRect(contentSize:bounds:fit:)` (aspect fit or fill).
- `placement ⇄ view transform`.
- Centres are clamped into the visible part of the media rect when an overlay is added.

**Text composer** (`MediaTextComposerView`, a full-screen dimmed overlay inside the editor, **not** a presented view controller)
- A centred `UITextView` pinned to `keyboardLayoutGuide`, with a **Done** button.
- `inputAccessoryView` style bar: font chips (8), colour swatches (8) plus a `UIColorWell`, a background toggle (none → highlight → box), an alignment toggle.
- While typing, highlight uses the attributed `.backgroundColor`. This is an accepted difference from the final look, and only during typing.
- Done with empty text removes the overlay.

**Sticker picker** (`MediaStickerPickerViewController`, a sheet with `.medium()`/`.large()` detents)
- A segmented control: Stickers (12 stills from `StickerCatalog`) or Emoji (compositional grid by section, plus `UISearchBar` matching `Unicode.Scalar.Properties.name`).
- A pick adds the overlay at the centre with default scale and dismisses the sheet.

**On the canvas**
- Photo stickers are stills. Video stickers use `StickerLoopView`; the loop is not frame-locked to playback (an accepted preview difference; export is exact).

**Settling on another page** rebuilds the overlay layer for that page.

### 6.7 The pill (S11)

- `soundPill` gets `.touchUpInside` → `soundtrackMode.toggle()`.
- On a photo, the band shows "Songs go on videos — this photo will be posted as it is."
- The pill is hidden while Trim is open (the action bar takes the slot, which is expected).
- Choosing a category closes the song tools.

### 6.8 Category bar

- `onReselect` (DesignSystem): if the selected mode's tenant is not showing, open it; otherwise do nothing.
- `-upload-category` still works (`:717-725`).

### 6.9 VoiceOver

| Control | Behaviour |
|---|---|
| Effect cards | Button, with a value ("plus 23"). Sliders are adjustable, with a "Reset" custom action. |
| Filter action | Hint "Select a clip first" while disabled. Row cards follow the transition-card pattern (`accessibilityUserInputLabels`); close is labelled "Close filters". |
| Overlay items | One element each: "Text, <content>", "Sticker, <label>", "Emoji, <name>". Custom actions: Edit, Delete, Bring to front, Bigger, Smaller, Rotate left/right, Move up/down/left/right (5%). `accessibilityActivate` selects or edits. |
| Composer style controls | Speak their state ("Font, Rounded"). |
| Picker cells | Sticker label, or the capitalised emoji name. |
| Waveform | Adjustable, "Song start, 0:12", ±1s. Sliders "Song volume" and "Original sound volume". |
| Pill | "Add a song" or "Song: <title>". |

Reduce Motion: skip the spring and scale entrances.

### 6.10 Symbols

Every new SF Symbol is checked in a runtime test (`UIImage(systemName:) != nil`), per the memory `upload-video-publishes`.

---

## 7. Export, publish, posters and thumbnails (S12)

- **`post()`** (`UP/Views/NewPostViewController.swift:643`)
  - **Video**: `edits.exportPlan(sourceURL:fileSeconds:artwork:includingOverlays: true)`. Artwork comes from `StickerArtBaker.strips(for: overlays, side: exportSide)`, baked on the main actor in chunks **before** the composer is called. It goes into `PickedVideo(plan:)`.
    - `PickedVideo` gains `finish`, `soundtrack` and `artwork`; `Equatable` compares artwork by identity (or is dropped; check `PostComposerTests`).
    - `PostComposer.uploadVideo` builds the plan from all the fields (`:256-258`).
  - **Photo**: stills are baked on the main actor (`StickerArtBaker.stills`), then `await Task.detached { edits.applied(to: image, artwork: stills) }.value`, off the main thread.
- **`NewPostCells`** (`:150-155`): bake stills first, then `applied(to:artwork:)`. The signature already covers overlays.
- **Posters**:
  - `VideoExporter.posterImage(for: exported)` reads the exported file, so crop, look, overlays and segment filters are included. `posterSeconds` still avoids transitions.
  - `ExportedVideo.pixelWidth/Height` come from the output (§4.5).
  - The optimistic feed entry uses the uploaded poster.
- **The new-post strip for a video** shows the whole finish on the library poster. Segment filters and the song are not shown there (it is a still), which is acceptable and documented.
- **The timeline filmstrip** keeps showing raw source frames (charter: a picture of the SOURCE), with filter stamps.

---

## 8. Slices

Size: S up to 300 changed lines, M 300–700, L over 700 (tests excluded).

"Break" means the deliberate code break used to prove the test can fail; apply **one break at a time** and run with `-collect-test-diagnostics never`. Pixel reads are required for anything visual.

### S0: contracts and scaffolding (serial, 1 agent, about 55 minutes, L)

Files:
- New `MP/Editing/{FrameLook,FrameCrop,FrameOverlay,FrameFinish,VideoSoundtrack,VideoLiveLook,FrameLookRenderer,OverlayRasterizer}.swift`. The renderer bodies are **identity stubs with final signatures**: `FrameLookRenderer.apply(_:to:time:) -> CIImage`, `FrameCrop.applied(to:) -> CIImage?`, `outputSize(forUpright:)`, `OverlayRasterizer.composite(_:over:time:artwork:) -> CIImage`, `OverlayRasterizer.image(for:outputWidth:scale:) -> CGImage?`.
- `MP/VideoExporter.swift`: plan and segment fields; `needsComposition(for plan:)`; a hook call `Self.applySoundtrack(plan.soundtrack, to:…) -> AVAudioMix?` (stub returns nil) in a new `MP/VideoExporter+Soundtrack.swift`.
- `MP/VideoPlaybackController.swift`: `setLiveLook`, `setMuted`, `setMixLevels` stubs.
- Upload:
  - `UP/Data/MediaFilter.swift` (typealias plus `name`; renderer calls `FrameLookRenderer`)
  - `UP/Data/MediaCrop.swift` (typealias; renderer calls the shared graph)
  - `UP/Data/MediaEdits.swift` (all fields, signature, `applied(to:artwork:includingOverlays:)` as a single graph)
  - new `UP/Data/MediaEdits+Plan.swift`
  - `UP/Data/MediaTimeline.swift` (`filter`)
  - `UP/Data/MediaTimeline+Export.swift` (map `filter` to `look` only)
- `UP/Views/MediaPreviewPlayer.swift` plus the **4 stubs** (new members).
- Editor:
  - `MediaEditorViewController.swift`: access changes; mode properties; shared touch points T1–T16 (§9.2); lock generalisation; `TrackAction.filter` with a stub handler, disabled.
  - new `MediaEditorViewController+Host.swift`, `UP/Views/Editor/MediaEditorMode.swift`, five mode files (the Filters mode holds the moved filter-row code **with unchanged behaviour**).
  - `MediaEditorPageCell.swift` (moved), `MediaOverlayLayerView.swift` (empty).
- DesignSystem: `IconSelectorBar.onReselect`, `SoundPillView.setTitle`.
- New package skeleton `ROOT/Packages/Core/StickerKit` (`Package.swift` with lottie `from: "4.5.0"`, one placeholder source, one test). Upload's and Chat's `Package.swift` gain the StickerKit dependency. Commit both `Package.resolved` files.

Tests:
- `MediaEditsSignatureTests` (Mirror completeness). Breaks: drop a field from `signature`; add a dummy field.
- `FrameLookNeutralityTests`: `isNeutral` for each field; setter normalisation. Break: remove the snap.
- `IconSelectorBarTests.aTapOnTheSelectedItemIsAReselect`. Break: remove the call.
- `SoundPillViewTests.setTitleChangesTheWordAndTheLabel`.
- `MediaEditorTrackToolsTests`: action-bar symbols are now three, and filter starts disabled.
- **Every existing Upload, MediaPlayback, DesignSystem and Chat test stays green**, and the Release app build compiles.

### S1: look pipeline (Wave 1, M)

Files: `MP/Editing/FrameLookRenderer.swift`, `MP/Editing/FrameCrop.swift` (graph body), `MP/Editing/EditingRenderContext.swift`; `UP/Data/MediaFilter.swift`, `UP/Data/MediaCrop.swift` (renderer bodies only).

Tests: new `MT/FrameLookRendererTests.swift`, pixel reads on generated CIImages.

| Test | Break |
|---|---|
| `brightnessRaisesTheCentre` | ignore brightness |
| `negativeSaturationDrains` | |
| `warmthRaisesRedAndLowersBlue` (checked at two values) | flip the sign |
| `highlightsAndShadowsMoveTheirRange` | |
| `vignetteDarkensCornersNotCentre` at 1× and 2× size | pixel units |
| `grainVariesWithTimeKeepsTheMean` | constant seed |
| `eachEffectChangesPixels` (parameterised) | |
| `zeroIntensityIsTheSource` | skip the mix |
| `rgbSplitShiftsRedAtAnEdge` | |
| `blurSoftensAnEdge` | |
| `everyStageKeepsTheExtent` | remove a crop |
| `aNeutralLookReturnsTheSameImage` | |
| `presetOrderIsAdjustmentsThenPreset` | swap the stages |

Existing `MediaFilterTests`, `MediaCropTests` and `MediaCropBakeTests` must stay green. New `MediaCropSharedGraphTests.upturnedRectMatchesThePhotoRendererAt10Degrees`.

### S2: compositor finish, live look, export route (Wave 1, needs PR 1; M/L)

Files: PR 1's compositor and instruction files; `MP/VideoExporter.swift` (tiling at every boundary, render size, whole-file finish, passthrough override, output dimensions); `MP/VideoPlaybackController.swift` (live look board, paused refresh, `renderScale`); `MP/VideoFrameRenderer.swift` only if needed to enqueue a still.

Tests: new `MT/CompositorFinishTests.swift`, reading pixels from exported or composed frames. First check that `ColourClipWriter.pixel` works with a custom compositor on **iOS 27**; if not, add a reader-based variant.

| Test | Break |
|---|---|
| `aSegmentLookDressesOnlyItsPiece` | |
| `aDissolveBlendsTwoDressedPieces` | apply the segment look after the blend |
| `theWholeLookFollowsTheSegmentLook` (pick presets where order visibly matters; measure first) | |
| `aCropChangesTheRenderSizeAndTheReportedDimensions` | source dimensions |
| `aTopCropKeepsTheYellowBand` | y-flip |
| `aRotatedSourceIsCroppedUpright` | |
| `aStraightenedCropMatchesThePhotoGraph` | |
| `aFinishOnAnUncutClipIsComposed` | |
| `aFinishOverridesPassthrough` | |
| `anUntouchedPlanNeedsNoComposition` | |
| `instructionsSplitAtEveryPieceBoundary` | |
| `aLiveLookRepaintsAPausedFrameWithoutANewItem` (renderer's centre luma; item identity unchanged) | |
| `aLiveLookReachesThePlayingFrames` | |
| `previewRenderScaleCapsTheLongSide` | |

### S3: overlay rasteriser and photo bake (Wave 1, M)

Files: `MP/Editing/OverlayRasterizer.swift`, `MP/Editing/OverlayRasterCache.swift`, the compositor's overlay stage call (already stubbed in S0; S3 fills the body only).

Tests: new `MT/OverlayRasterizerTests.swift`.

| Test | Break |
|---|---|
| `aBoxDrawsItsColourAtTheCentre` | |
| `highlightDrawsBehindEachLine` | |
| `leadingAlignmentMovesInkLeft` | |
| `placementPutsTheInkWhereItSays` (top vs bottom) | y-flip |
| `rotationTurnsTheInk` (bounding-box aspect flips) | |
| `scaleFollowsTheOutputWidth` (320 vs 640) | |
| `emojiDrawsColour` | |
| `aStickerFrameIsChosenByTime` (fake artwork: red, then green) | |
| `missingArtworkSkipsOnlyTheSticker` | |
| `theCacheRendersOnce` (counter) | |
| `everyOverlayFontResolves` | |

Upload: `UT/MediaEditsBakeTests.aPhotoCarriesItsTextAndItsSticker` (pixel read).

### S4: StickerKit (Wave 1, M)

Files:
- `ROOT/Packages/Core/StickerKit/**`: `Sticker`, `StickerCatalog`, `StickerLoopView`, `StickerFrameBaker`, `StickerStrip`, `EmojiCatalog`.
- Move `CH/Resources/Stickers/*` there (`git mv`).
- `CH/Views/FavoriteStickerCatalog.swift` becomes a shim (`typealias FavoriteSticker = Sticker`, forwarding functions); `CH/Views/FavoriteStickerStripView.swift` imports it.
- Chat `Package.swift`: remove `resources:`.

Tests: `StickerKitTests`:
- `everyStickerLoads`
- `aStripHas90FramesAt30fps` and `framesDiffer`
- `stripsAreCompressed` (bytes under a bound)
- `theBakerCaches`
- `emojiOnlyRenderable` (single glyph; more than 1,000 entries; includes GRINNING FACE and the flag of France)
- `searchFindsByName`

All `ChatTests` stay green.

### S5: Effects UI (Wave 2, M/L)

Files: `UP/Views/MediaEffectsToolsView.swift`, `UP/Views/MediaValueSliderRow.swift`, `UP/Views/Editor/MediaEditorEffectsMode.swift`.

Tests: `UT/MediaEditorEffectsTests.swift`, `UT/MediaEffectsToolsTests.swift`.

| Test | Break |
|---|---|
| `reselectOpensEffectsOnFirstEntry` | |
| `aSliderStoresAndZeroRemovesTheEntry` | |
| `aPhotoPageRedrawsWithTheAdjustment` (pixel) | |
| `aVideoGetsALiveLookAndNoNewItem` (stub records; plan count unchanged) | reload instead |
| `effectsAreExclusive` | |
| `undoResetsOnlyEffects` | |
| `sliderSpeaksItsValue` | |
| `everyEffectsGlyphExists` | |
| `spinnerStaysHiddenWhileDragging` | |

### S6: video Filters (Wave 2, same agent as S5, S)

Files: `UP/Views/Editor/MediaEditorFiltersMode.swift` only.

Tests: **flip** `UT/MediaEditorCropTests.swift:538` `aVideoSaysWhyItCannotBeFiltered` into `aVideoIsOfferedTheLooks`. Add `aVideoLookReachesTheLiveLook` and `thumbnailsWearTheCurrentLook` (pixel read of a chip).

### S7: segment filters (Wave 2, L)

Files:
- `UP/Data/MediaTimelining+Filters.swift` (new); `UP/Data/MediaTimelining.swift` (`cuts` only); `UP/Data/MediaTimeline+Export.swift` (`playsTheSame`, `film`).
- `UP/Views/BandChoiceRowView.swift` (new), `UP/Views/MediaTransitionRowView.swift` (refactor onto it), `UP/Views/MediaSegmentFilterRowView.swift` (new).
- `UP/Views/MediaTimelineToolsView.swift`, `UP/Views/MediaTimelineTrackView.swift` (filter stamp only).
- `UP/Views/Editor/MediaEditorSegmentFilterMode.swift`.
- `ROOT/dev/TIMELINE_CHARTER.md` (F31–F34).

Tests:
- Model (`UT/MediaSegmentFilterModelTests.swift`): `settingTouchesOnlyThatPiece`, `originalIsNil`, `splitGivesBothHalves`, `carryKeepsIt`, `playsTheSameTellsFiltersApart` (break: remove from `Stretch`), `anUncutClipWithAFilterStillExports` (break: `cuts` unchanged), `exportSegmentsCarryIt`, `MediaSegment` Mirror completeness.
- Screen (`UT/MediaEditorSegmentFiltersTests.swift`, harness copied from the transitions tests): `disabledUntilAPieceIsHeld`, `opensWithoutMovingThePicture`, `choosingStoresOnTheFocusedPieceAndReloads`, `theRowLoopsThePiece`, `splitSpeedResetDisabledWhileOpen`, `closeRestoresTheTrackAndPause`, `everyWayOffTheClipCloses`, `transitionsAndFiltersNeverOpenTogether`, `thePosterWearsPiece0Filter`.
- Row (`UT/MediaSegmentFilterRowTests.swift`): the chosen ring is read from the layer.
- Existing `MediaTransitionRowTests` stay green through the forwarded hooks.
- Track: `aFilteredPieceWearsAStamp` (symbol read from the image).

### S8: video crop (Wave 3, S/M)

Files: `MediaEditorViewController.swift` (`enterCrop`/`showCropPicture`/`dress`/`exitCrop` region only), `+Host` if needed.

Tests: **flip** `MediaEditorCropTests.swift:517` `aVideoSaysWhyItCannotBeCropped`, `:656` `swipingFromAVideoToAPhotograph…`, `MediaEditorPlaybackTests.swift:257`, `MediaEditorTimelineTests.swift:1314`. Add:
- `cropOpensOnAVideoWithTheFrameUnderTheNeedle` (the stub frame is a distinct colour; read the surface image)
- `previewStopsWhileCropping`
- `leavingReloadsThePlanWithTheCrop`
- `tapWhileCroppingAVideoDoesNotToggle`

### S9: overlay canvas and Text (Wave 2, L)

Files: `UP/Views/MediaOverlayLayerView.swift`, `UP/Views/MediaOverlayItemView.swift`, `UP/Views/MediaOverlayTrashView.swift`, `UP/Views/MediaTextComposerView.swift`, `UP/Views/MediaTextStyleBar.swift`, `UP/Views/MediaOverlayToolsView.swift`, `UP/Data/MediaOverlayGeometry.swift`, `UP/Views/Editor/MediaEditorOverlayMode.swift`, `UP/Views/MediaEditorPageCell.swift` (host body only).

Tests: `UT/MediaEditorTextTests.swift`, `UT/MediaOverlayGeometryTests.swift`, `UT/MediaOverlayItemTests.swift`.

| Test | Break |
|---|---|
| `textModeLocksAndUnlocks` (scroll, modal, pans) | |
| `addingTextStoresAnOverlay` | |
| `emptyTextRemovesIt` | |
| `panMovesThePlacementInMediaSpace` (fit and fill) | |
| `pinchScales`, `rotateRotates` | |
| `trashDeletes` | |
| `canvasPageIsNotBakedButTheViewIsDrawn` (pixel) | |
| `itemViewMatchesTheRasterizer` (pixel parity) | |
| `overlaysFollowTheSettledPage` | |
| `inertOutsideTheMode` | |
| `voiceOverActionsMoveScaleDelete` | |
| `styleControlsStoreTheStyle` | |
| `tappingAnOverlayDoesNotTogglePlayback` | |

### S10: Stickers UI (Wave 3, M)

Files: `UP/Views/MediaStickerPickerViewController.swift`, `UP/Views/EmojiGridView.swift`, the overlay mode's sticker path (S9's file; hand over after S9 merges).

Tests: `pickingAStickerAddsItAtTheCentre`, `pickingAnEmojiAddsIt`, `aVideoStickerLoops` (the item hosts a `StickerLoopView`), `aPhotoStickerIsAStill` (pixel), `searchFilters`, `sheetDismissesOnPick`.

### S11: soundtrack (Wave 2, L)

Files:
- MediaPlayback: `MP/VideoExporter+Soundtrack.swift`, `MP/AudioWaveform.swift`, `MP/VideoPlaybackController+Sound.swift`.
- Upload: `UP/Library/MediaSoundtrackSourcing.swift`, `UP/Data/TempFileBag.swift`, `UP/Views/MediaSoundtrackToolsView.swift`, `UP/Views/MediaWaveformExcerptView.swift`, `UP/Views/Editor/MediaEditorSoundtrackMode.swift`, `UP/Views/PostDraft.swift` (bag), `UP/Views/MediaPreviewPlayer.swift` (bodies).

Test support: `MT/Support/ToneWriter.swift` writes a sine tone with `AVAudioFile`. No download.

MediaPlayback tests (`MT/SoundtrackCompositionTests.swift`, `.serialized`):

| Test | Break |
|---|---|
| `musicFillsTheSilentSecond` | |
| `musicIsNotRescaledByARatedPiece` (zero-crossing rate unchanged) | insert before scaling |
| `originalZeroSilencesTheFilm` | |
| `theExcerptStartsWhereAsked` | |
| `aSoundtrackOverridesPassthrough` | |
| `refusesProtectedOrSilentFiles` | |
| `stressExportWithMusicAndRatedPieces` (12 runs, watchdog) | |
| `waveformPeaksFollowLoudness` | |
| `setMixLevelsReplacesTheItemMix` | |

Upload tests: `pillOpensToolsOnAVideo`, `noticeOnAPhoto`, `importStoresTheSoundtrack` (stub sourcing), `excerptStoresOnRelease`, `volumesAreLive`, `previewUnmutesWithASong`, `removeMutesAgain`, `tempFilesDieWithTheDraft`.

### S12: publish path (Wave 3, M)

Files: `UP/Views/NewPostViewController.swift` (`post()`), `UP/Views/NewPostCells.swift`, `UP/Data/PostComposer.swift` (`PickedVideo`, `uploadVideo`), `UP/Data/StickerArtBaker.swift`.

Tests:
- `NewPostTests.postBakesTextAndStickerIntoAPhoto` (pixel)
- `postHandsTheVideoItsFinishSoundtrackAndArtwork`
- `photoBakeRunsOffMain`
- **E2E** `VideoPublishEndToEndTests.anEditedVideoPublishesAsEdited`: real exporter; checks dimensions equal the crop, colour matches the filter, the text box pixel is present, and the poster wears the edits.
- `PostComposerTests` updated for the `PickedVideo` shape.

### S13: integration and verification (Wave 4, 1 agent, about 45 minutes)

- Full `xcodebuild test` for Upload, MediaPlayback, StickerKit, Chat and DesignSystem on the iPhone 18 Pro (iOS 27) **and** the 17 Pro Max (iOS 26.5, the CI family).
- Debug and Release app builds.
- Simulator check with the `verify` skill:
  - `-mock-auto-login -open-create upload -upload-pick N -upload-edit -upload-category <i>` on each mode, on the 18 Pro and on the SE (narrow toolbar: 3-item action bar plus scrolling category bar);
  - `-upload-seed-cuts 3 -upload-seed-transition dipToBlack` together with a segment filter;
  - `-look-probe` on the SE: log the compositor time.
- Verify the **pictures**, not the labels (memory `upload-timeline-and-actions`).
- Update stale comments (§12) and docs.
- Open the PR (English, repo title style, required attribution).

---

## 9. Parallelisation map

### 9.1 Waves (about 4h40 total)

| Wave | Agents | Slices | Must merge before the next wave |
|---|---|---|---|
| 0 (about 55 min) | 1 | S0 | yes: the contracts are frozen |
| 1 (about 60 min) | 4 | A: S1, B: S2, C: S3, D: S4 | merge order D → A → C → B |
| 2 (about 75 min) | 4 | A: S5 + S6, B: S7, C: S9, D: S11 | merge order A → D → B → C |
| 3 (about 45 min) | 3 | A: S8, B: S10 (after S9), C: S12 | merge order C → A → B |
| 4 (about 45 min) | 1 | S13 | |

- Each agent works in its own worktree, branched from the integration branch (`feature/upload-editor-complete`) at the start of the wave, with its own `-derivedDataPath <scratch>/dd-<slice>`.
- The integrator rebases each slice onto the integration branch and runs that slice's tests after every merge.

### 9.2 Shared touch points: written once in S0, then frozen

| # | Touch point | Location | Afterwards, only |
|---|---|---|---|
| T1 | `categories` order | `:105` | nobody |
| T2 | `showAccessory` switch: every case delegates | `:1142` | nobody |
| T3 | `setEditingAccessory` calls `bandWillChange` on every mode | `:2944` | nobody |
| T4 | `refreshToolbarItems`, pill action and title | `:1062` | nobody |
| T5 | `TrackAction` plus handler | `:167-201` | nobody |
| T6 | `refreshTrackActions` enablement (filter and exclusion) | `:2239` | S7 via the mode's `actionEnabled` |
| T7 | `resetTheCurrentMode` / `refreshResetItem` route to the active mode | `:245`, `:272` | nobody |
| T8 | lock owners and `updateStackGestures` | `:2386`, `:2603` | nobody |
| T9 | the three settle hooks call `pageDidSettle` | `:2885-2920` | nobody |
| T10 | `loadPreview` plan from `exportPlan`; loop from `activeLoop` (transition or segment focus) | `:1501` | S2 only for the controller API |
| T11 | `refreshPreview` "needs a new item" predicate (crop, soundtrack) | `:1559` | nobody |
| T12 | cell registration calls `overlayMode.dress(cell,id)`; `includingOverlays: false` | `:855-886` | nobody |
| T13 | `render`/`redraw` with overlays excluded | `:395`, `:1778` | nobody |
| T14 | `viewWillDisappear` calls `screenWillDisappear` on every mode | `:673` | nobody |
| T15 | `MediaVideoPreviewing` plus 4 stubs plus real (stub bodies) | preview file | S2 and S11 fill **real** bodies only |
| T16 | `MediaEdits.swift`, `MediaTimeline.swift`, all `Package.swift`/`Package.resolved` | | nobody |

### 9.3 File ownership after S0

| Slice | Owns |
|---|---|
| S1 | `MP/Editing/FrameLookRenderer.swift`, `FrameCrop.swift` (body), `EditingRenderContext.swift`; `UP/Data/MediaFilter.swift`, `MediaCrop.swift` |
| S2 | PR 1 compositor files, `MP/VideoExporter.swift`, `MP/VideoPlaybackController.swift`, `MP/VideoFrameRenderer.swift` |
| S3 | `MP/Editing/OverlayRasterizer.swift`, `OverlayRasterCache.swift` |
| S4 | `ROOT/Packages/Core/StickerKit/**`, `CH/Views/FavoriteSticker*.swift` |
| S5/S6 | `MediaEffectsToolsView`, `MediaValueSliderRow`, Effects mode, Filters mode |
| S7 | timelining and export helpers, `BandChoiceRowView`, both row views, `MediaTimelineToolsView`, `MediaTimelineTrackView`, segment-filter mode, charter |
| S8 | the crop region of the main editor file |
| S9 | overlay views and geometry, text composer, overlay mode, page cell body |
| S10 | picker and emoji grid; sticker path in the overlay mode (after S9) |
| S11 | `MP/VideoExporter+Soundtrack.swift`, `MP/AudioWaveform.swift`, `MP/VideoPlaybackController+Sound.swift`, sourcing, soundtrack views and mode, `TempFileBag`, `PostDraft`, preview player bodies |
| S12 | `NewPostViewController.swift`, `NewPostCells.swift`, `PostComposer.swift`, `StickerArtBaker.swift` |

Known overlap: S2 (wave 1) and S11 (wave 2) are in different waves. S11 touches only its own new files plus the `MediaPreviewPlayer` bodies.

### 9.4 Simulators

- One agent per device: Wave 1/2 agents A → 18 Pro, B → SE, C → 17 Pro Max.
- Agent D uses `-parallel-testing-enabled YES -parallel-testing-worker-count 1` on the 18 Pro, which makes xcodebuild use a temporary clone. At the end, confirm with `xcrun simctl list | grep Clone` that no clone is left over; the user keeps exactly three simulators.
- **Never launch the app on a device another agent is testing on.**

---

## 10. Risks and traps

1. **iOS 27 simulator**: never set `item.videoComposition` on a player item. Check early in S2 that `AVAssetImageGenerator` and `AVAssetExportSession` honour a custom compositor on iOS 27; if the generator does not, switch the pixel tests to reads through `AVAssetReaderVideoCompositionOutput`. Run every AV test on both iOS 27 and iOS 26.5, because CI runs iOS 26.
2. **`MediaEdits.signature`**: written by hand; the Mirror completeness test turns a missing field into a red build.
3. **Filters dropped silently**: `cuts` and `playsTheSame` ignore new segment fields unless changed (§3.3). The Mirror tests cover both.
4. **`scaleTimeRange` rescales music** inserted before it, so insert music last.
5. **AVAudioMix ramp hang**: constant volumes only; stress-export 12 times with a watchdog.
6. **Passthrough** ignores the audio mix and video composition: widen the override.
7. **Dimensions from the source track** are wrong once a crop exists.
8. **Instructions span pieces** today: split at every boundary.
9. **Swift 6 isolation**: `CIFilter` is not `Sendable`; Lottie is main-actor only; PhotoKit and `NSItemProvider` callbacks arrive on arbitrary queues (copy inside, then resume with a URL); `-typecheck` misses region errors; instruction classes need immutable `let`s.
10. **`private` members** cannot be reached from new files: relax them in S0 only.
11. **`setEditingAccessory` and every production call site must stay outside `#if DEBUG`**: build Release before pushing (`:2933-2943`).
12. **`IconSelectorBar` is silent on a repeat tap**: `onReselect` (S0).
13. **`setCompact(true)` deselects**: record the focus first.
14. **Test category indices are hard-coded**: never reorder categories.
15. **SF Symbols**: check existence at runtime. **Font names**: check at runtime.
16. **Core Image extents**: infinite generators and spreading blurs; crop every stage.
17. **Y-axis flip** in crop and overlays: use asymmetric test placements.
18. **The "constant equals threshold" trap**: test warmth, vignette and scale at two values or two sizes.
19. **The "laundered assertion" trap**: assert on `FrameLookRenderer` output directly, not through `applied(to:)`, which repeats work.
20. **Break runs**: one break at a time, `-collect-test-diagnostics never`, and `settle(until:)` returns silently, so use `#require` on landing.
21. **Performance on the SE**: blur downsampling, `renderScale`, one effect, overlay caching, PNG sticker strips, `cacheIntermediates: false`, `-look-probe`. The simulator counts **zero** Metal texture memory (memory `animated-map-icons`), so measure CGImage and PNG sizes, not the process footprint.
22. **Colour-space parity** between photo (sRGB) and video (BT.709): allow tolerance in parity tests.
23. **Sheet dismissal is driven by velocity**: an overlay drag must happen under `isModalInPresentation` (the lock).
24. **`UIView.animate` from-value trap**: stage alpha before animating and call `layoutIfNeeded` on new views first.
25. **Keyboard on the main simulator is hidden**: drive the text view directly in tests; see memory `sim-keyboard-qa` for manual checks.
26. **Audio session**: `.ambient` plus a muted player means the song is never heard. Restore `.ambient` on stop, because `VideoPlaybackController` resets it app-wide at `:218`.
27. **The "downloading a file requires the user's permission" rule**: no `emoji-test.txt`; document ZWJ sequences as a follow-up.
28. **Moving Chat resources**: `Bundle.module` changes to StickerKit's. Chat tests are the safety net.
29. **Temporary files**: imported audio must outlive the editor until publishing finishes (`TempFileBag` in `PostDraft`).

---

## 11. Fallbacks if time runs short

| Area | Fallback |
|---|---|
| Waveform | Use a plain "Start" slider. |
| Stickers on the video canvas | Show a still (export still animates). |
| Emoji search | Sections only. |
| `BandChoiceRowView` extraction | Duplicate the row and add a follow-up chip. |
| Paused live-look refresh | Coalesced reader refresh. |
| Effects list | Ship 6 effects (blur, pixellate, rgbSplit, vhs, posterize, bloom). |
| Minimum per category | Effects adjustments; whole and segment filters; video crop; text with box style; emoji stickers; Files import with constant volumes. |

---

## 12. Stale comments and docs to update

- **Editor type doc** (`:55-68`): "NOTHING HERE EDITS ANYTHING YET" and "A VIDEO DRAWS ITS POSTER FRAME".
- **Editor inline comments**:
  - `soundPill` (`:544-547`)
  - `configureCategoryStrip` (`:1020-1021`)
  - `refreshToolbarItems` (`:1056-1061`)
  - `enterCrop` (`:2372-2379`)
  - `mediaTapped` (`:2271-2278`)
  - `filtersUnavailable` and `cropUnavailable` notes
- **Other source files**:
  - `DS/SoundPillView.swift:12-15` ("NO ACTION, ON EITHER SCREEN")
  - `UP/Views/MediaEditorBandView.swift:85-91`
  - `UP/Views/NewPostViewController.swift:53-55`, `:634-639`
  - `MP/VideoExporter.swift:28-37` ("not here yet")
  - `UP/Data/MediaEdits.swift:13-18` (what reaches the server's pixels)
- **Docs**:
  - `ROOT/dev/IOS_VIDEO_CAPTURE_UPLOAD.md` §5 P4: crop and filters for video are done.
  - `ROOT/dev/TIMELINE_CHARTER.md`: F31–F34, plus "not yet met": overlay time ranges, ZWJ emoji, song loop and fades.
- **Memory**, after the run: add notes on the soundtrack scaling trap, the reselect trap, and the paused live look.

---

### Critical Files for Implementation
- <repo root>/Packages/Features/Upload/Sources/Upload/Views/MediaEditorViewController.swift
- <repo root>/Packages/Core/MediaPlayback/Sources/MediaPlayback/VideoExporter.swift
- <repo root>/Packages/Features/Upload/Sources/Upload/Data/MediaEdits.swift
- <repo root>/Packages/Features/Upload/Sources/Upload/Data/MediaTimeline+Export.swift
- <repo root>/Packages/Features/Upload/Sources/Upload/Views/MediaTimelineToolsView.swift