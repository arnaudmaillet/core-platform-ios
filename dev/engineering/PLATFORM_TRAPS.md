# Platform traps

Behaviour of UIKit, Core Animation, AVFoundation, PhotoKit, MapKit and Swift concurrency that cost this repository a bug, measured on iOS 26 and 27. Each entry gives the symptom, the cause and what to do. Read the sections for the frameworks your change touches before you write the code. Test and CI traps are in [Test traps](TEST_TRAPS.md).

Three rules come out of all of them:

- **Public API only.** Find a UIKit view by its role or identity (the toolbar item's `customView`, "the pan on the stack's view that is not the vended one"), never by a private class name. Never ship a private key or selector.
- **The simulator is not the device.** The simulator's iOS is often older (27.0 against a device's 27.2), it has no audio route of its own, and it lands content early in a push. A change to what a bar draws, to audio, or to anything timed inside a transition is checked on a device.
- **When a framework seems to ignore you, measure before you theorise.** Sample the presentation layer, log which recognizer UIKit consults, sample the stuck process. Most entries below were found that way, after several wrong fixes.

## Navigation and transitions

- **Two back chevrons on iOS 27.2.** Setting `navigationItem.backAction` makes the bar draw a back button of its own, on a tab's root and beside a custom leading chevron. The 27.0 simulator does not show it. Never use `backAction` to intercept the back button: `ArbitratedNavigationController` overrides `popViewController(animated:)` and hands it to `StackArbiter` (#1971, PR #1981).
- **A guard refuses a push right after a modal presentation.** `transitionCoordinator` is non-nil while the navigation controller itself is being presented, including inside `present(_:animated:completion:)`'s completion. To ask "is a push or pop of this stack running?", use `isTransitioningItsStack` (CoreNavigation). `transitionCoordinator == nil` means only "the stack is completely at rest".
- **The full-surface back swipe does nothing after a custom transition.** With any navigation controller delegate in the slot, UIKit refuses its iOS 26 full-surface pop (`interactiveContentPopGestureRecognizer`) on a screen whose pop brings the tab bar back, through a private check no public delegate method sees. `NavigationDelegateHub` vacates the slot when idle (`vacateIfIdle`). A zero-duration recognizer left on the transition container after a transition died also kills it (#670, PR #672).
- **`interactivePopGestureRecognizer` is not the recognizer that pops.** The stack has two back-swipe pans; the vended one is enabled and inert, and the one that pops is full-width. Gating the vended one governs a gesture that never arrives. Log which recognizer UIKit consults before changing either. A horizontal scroller covering the screen beats the pop: make the scroller decline a rightward drag at its leading edge.
- **An edge-strip rule refuses legitimate edge drags.** In `gestureRecognizerShouldBegin`, a pan has already travelled past its slop, and for UIKit's own pop pan the translation reads zero, so `location` is not where the drag began and the error varies with speed. Record the touch's location in `gestureRecognizer(_:shouldReceive:)` (return true there) and test that stored value in `shouldBegin`.
- **A screen unfolds from the top-left corner.** Its first layout pass ran inside someone else's animation block, so every subview animated from a zero frame. It needs a view not yet laid out (an unanimated push, a tab switch, `addChild`) and an animation that flushes layout up the hierarchy in the same turn: `setBottomAccessory(_:animated:)`, `setTabBarHidden(_:animated:)`, a keyboard animation. iOS 26/27 also run a custom transition's setup inside an implicit animation of its duration. **Do:** lay the view out inside `UIView.performWithoutAnimation` before such a call (`SelectorAccessory.settlePendingLayout`, `UINavigationController.cut`), and run every animator's setup with view animations off (`ZoomAnimator`, `RevealTransition`, `InteractiveSlideDismissal`). DEBUG `-first-layout-trace` names the block (PR #189).
- **Content moves with an incoming push.** A push lays the incoming screen out inside its animation: offsets set in `viewDidLayoutSubviews`, a bar item's first layout and self-sizing rows all ride it. The simulator often hides it. Apply what is set while a screen comes in without animation, and lay bar items out before the push (`SnapAuthorIdentityView.settleLayout()`) (#2049, PR #2055).
- **A cancelled pop reads as an arrival.** After a cancelled interactive pop, UIKit calls `viewWillAppear` again with `isMovingToParent == true` on a cancelled coordinator. Check `transitionCoordinator?.isCancelled` before treating it as an arrival (`ViewportShare.screenWillAppear` does).
- **A custom `titleView` already gets the native push transition**, on a snapshot, so sampling its layer opacity reads a flat 1.0. The bar owns the title view's alpha and resets it to 1 on the way out: park it with `isHidden`, not `alpha`.

## Bars, tab bar and glass (iOS 26/27)

Native chrome is shown, hidden and animated by UIKit only ([ADR 0005](decisions/0005-native-chrome-belongs-to-uikit.md)). Bar items follow the [bar contract](../BAR_CONTRACT.md): every item has an identifier, an item that stays keeps its instance, and no bar collapses into "•••".

- **Bar items set during a push land unanimated at its end.** `setRightBarButtonItems(_:animated: true)` while `transitionCoordinator != nil` is folded into the push: a one-frame pop on a device. Place them from `coordinator.animate(alongsideTransition: nil, completion:)` plus one main-queue turn, and place them at once if `animate` returns false. Coalesce two animated placements in one turn (#756, PR #754).
- **A bar item's width drifts or freezes.** A reused `UIBarButtonItem(customView:)` keeps UIKit's wrapper, whose width stops following the view, and the bar freezes an item's width when the item is made. Re-mint the item around the same view, under the same identifier, when its intrinsic width changes. Apply widths before `setToolbarItems`, never after.
- **A custom view built from a `UIButton.Configuration` button is measured stale** (a 44 pt circle showing "4" of "New 4"): the configuration renders on a deferred pass. Build a bar item's custom view as a `UIControl` with an exact `intrinsicContentSize` (`WalletBadgeButton`). A custom view in a bar must state an intrinsic width; `noIntrinsicMetric` gets its unlaid frame.
- **iOS 27 ignores `width` on a native title item**, prominent or plain. A control that takes the free width is a plain view in an item whose bubble the bar draws (`BarItems.stretched`, `StretchedBarLabel`).
- **A toggled bar icon resets when tapped.** A `UIAction` that carries an image re-applies it to its item when it fires. Keep the action image-less and set the icon on the item.
- **The app crashes on iOS 26 only.** `navigationItem.searchBarPlacementBarButtonItem` in a navigation bar throws "only supported in UIToolbar" on iOS 26; iOS 27 accepts it. For a search button in a navigation bar, set `searchController` with `preferredSearchBarPlacement = .integratedButton`. Treat any API newer than iOS 26 with suspicion: CI is the only iOS 26 check (#1689).
- **A `UITab` whose only change is `isEnabled` keeps its old look** on iOS 27. Set `tab.image` to nil and back when availability flips (#547).
- **`setTabBarHidden(_:animated: true)` is a fade on iOS 27**, not a slide: the model alpha goes to 0 while `isHidden` is set. A hidden bar's alpha proves nothing about hand-written alpha.
- **A bottom toolbar's glass ignores the toolbar's `overrideUserInterfaceStyle`.** Since iOS 26 the glass sits in a floating-bar container beside `UIToolbar`, under the navigation controller's view. Style that container too.
- **The tab bar accessory (`UITabAccessory`).**
  - The minimize does not find a scroll view nested in a horizontal pager: call `setContentScrollView(_:for: .bottom)` with the visible page's scroller, which the pager publishes. Picking "the biggest scroll view" picks page 0.
  - `hidesBottomBarWhenPushed` hides the bar but not the accessory. Install it in `viewDidAppear` and remove it in `viewWillDisappear`.
  - A programmatic `setContentOffset` never minimizes the bar; only a drag does. The signal is the accessory's `tabAccessoryEnvironment` trait, not `tabBar.frame`.
  - Its width is UIKit's; constraints on the content are inert. Adapt the content to the environment trait (`PagedTabBar.segmentSizing`).
- **Glass repaints a subview's `backgroundColor`** with its own rounded corner at the item's first appearance, so `cornerRadius` and masks cannot shape it. Paint fills that must keep their shape as a `CAShapeLayer` (`MonogramAvatarView`) (PR #277).
- **Glass draws labels as vibrant content.**
  - Inside a bar platter, a leaf label's partial `alpha` renders opaque. Fade a colour or a container, never a label's alpha (`SegmentView`).
  - A `UILabel`'s colour is overridden in a glass bar item: avatar initials are drawn into a layer's contents (`MonogramAvatarView`) (#2051).
  - Text attachments go vibrant: a red heart turned black. Put coloured glyphs in a `UIImageView` beside the label.
  - Semantic colours resolve differently inside a glass content view or a glass sheet: an inverted-ink badge (`.label` ground, `.systemBackground` text) vanished in dark mode, and a tinted template heart turned pink. Use fixed inks or `.alwaysOriginal` images, and check both appearances.
- **Inset-grouped rows clip through `cornerConfiguration` on iOS 27.2 devices**, not `layer.cornerRadius`, and the table turns clipping back on after every layout. A reset in `willDisplay` fixed the simulator only. `AuthButtonCell` forces `masksToBounds` off in its layer class.
- **Fading `tabBarController.tabBar` does not fade the search capsule.** With a `UISearchTab`, the capsule is a sibling of `UITabBar`, and `searchController.searchBar.window` stays nil because UIKit draws its own copy. Fade `tabBar.superview`.
- **`updateSearchResults(for:)` is not "the viewer typed".** UIKit also calls it on first-responder changes. Compare with the last query you reported (`SearchViewController.lastReportedQuery`).

## Lists and collection views

- **An accessory button draws but does not take taps.** A bare `UIButton` in a `UICellAccessory.customView` reports no intrinsic size when the accessory reserves its width, so its slot is zero wide and taps fall through to the row. Wrap it in a frame-based host that overrides `intrinsicContentSize` (`MonogramAccessoryHost`).
- **An entrance animation from a cell registration handler does nothing.** During a diffable `apply`, UIKit runs the handler inside a no-animation scope. Stage the start state in the handler, then play the animation after the apply returns and `layoutIfNeeded()` runs. A flag cleared by `DispatchQueue.main.async` is cleared before the layout pass that dequeues the cells.
- **`reloadData()` followed by `performBatchUpdates` with no layout between crashes** with "Invalid batch updates". Lay out before the next batch.
- **"Attempted to apply a snapshot while it was already applying a snapshot."** `willDisplay` runs inside an apply. Never publish synchronously from it: set the in-flight flag at once, emit from a `Task` on the next turn.
- **A row whose content changed in place never re-renders.** A diffable list keyed by ids sees an empty diff when a row is read or its avatar resolves. Name the changed rows with `reconfigureItems` (`InboxRowDiff.changedRows`).
- **A list stops under its spinner.** A page that lands wholly on screen asks for the next one from `willDisplay` inside that render. Free the in-flight slot before emitting the appended rows, and test by calling `loadMore` from the observer while it renders.
- **Rows reshuffle on every return.** Swift's `sort` is not stable. Sort on a total order, with ties broken on the id (`Conversation.isOrderedBefore`).
- **A list cell traps at its first dequeue.** Declaring `required init?(coder:)` stops inheritance of the superclass's initializers, so removing `override init(frame:)` from a `UICollectionViewListCell` compiles and traps with "unimplemented initializer".
- **A label's text measures as one line.** Reading back `label.attributedText` returns paragraphs carrying the label's `lineBreakMode` (`.byTruncatingTail`). Measure text you built, or reset the paragraph style to word wrapping.
- **A measuring pass reads zero or stale widths.** In a sizing cell's `layoutSubviews` or `preferredLayoutAttributesFitting`, nested stack views have not laid out yet. Compute text layout from the width the cell is handed, never from a subview's frame (#2042).
- **A pull-to-refresh never fires.** A `UIRefreshControl` on a page inset under a floating header did not trip from a real drag. Use `HeroPullToRefreshView` with `onPullReleased` (PR #349).
- **A context-menu preview reads as invisible, with a garbage frame.** UIKit keeps the preview controller's view at alpha 0 and draws it through a portal in another window; `snapshotView` of the platter is blank, and `.pop`/`.dismiss` completions run before the next turn. Mark the preview visible (`EmoteVisibility.treatAsOnShow`), snapshot the lift's own view, and capture state at commit time (`PreviewLaunch`) (#1564).

## Core Animation and view animation

- **An animation is attached but invisible.** `.beginFromCurrentState` takes its from-value from the presentation layer, so a from-value staged in the same turn never rendered and the animation runs end to end. Springs carry an explicit from-value and escape it, which is the tell: scale animates, fade does not. Drop the option or give an explicit `fromValue`.
- **`view.alpha` cannot say whether a view is animating.** It is the model value, set to the end at commit. Sample `layer.presentation()`.
- **A presentation read right after `CATransaction.flush()` returns the model.** Without a `beginTime`, an animation begins a little after the commit. A test that reads it at once needs `fillMode = .backwards` (or `.both`).
- **Animations added before `CATransaction.begin()`** do not belong to it, so its completion fires at once.
- **An off-main crash in Auto Layout from a background `CATransaction.commit()`.** Any thread's commit lays out every context's pending layers, windowed UIKit views included, and iOS 26/27's floating bar container is dirtied after UIKit's own commit. Off-main baking flushes on main before main sleeps (`EmoteMainPark`). `EMOTE_OFFMAIN_PROBE=1` prints any off-main layout (PR #1968).
- **A layer's frame is wrong after a re-configure.** Setting `frame` on a view that wears a transform erases the transform's translation. Place it by `bounds` and `center`.
- **An endless animation costs the whole frame.** Any perpetual animation on screen makes the render server recomposite the full frame (glass and blurs included) every frame, whatever its size. Hidden or paused layers cost nothing. A decorative perpetual animation stops while `MotionPreference.stillsDecoration` holds (Reduce Motion, Low Power Mode, or the app at rest through `IdleCalm`) and re-reads it on `.decorativeMotionDidChange`. DEBUG `-animation-audit` lists what runs (#580).
- **A view below alpha 0.01 drops its taps**, and a plain `UIView` subview of a `UIControl` swallows them unless `isUserInteractionEnabled = false`.
- **A colour does not follow the appearance.** A bare `.cgColor` resolves with no traits. Resolve with `resolvedColor(with: traitCollection)` and re-resolve on trait changes; a baked bitmap freezes the traits it was drawn with and must be baked again.
- **No corner curve draws a squircle between an app icon and a disc.** `.continuous` jumps from the icon's shape to a circle. A super-ellipse is a path (`AvatarShape.roundedTile`); views that can only wear a corner use `cornerRadius(side:)`.

## Gestures

- **A recognizer with no action still prevents others.** `cancelsTouchesInView = false` governs delivery to views, not recognition: a recognizer that recognizes blocks every other one it does not recognize with, ancestors included. Return false from `gestureRecognizerShouldBegin` when nothing listens (`MediaCarouselView`). The override must be in the class body. The tell: `shouldReceive` fires and the action never runs.
- **A control "does nothing" with no error.** Separate the three failure points before theorising: did the touch arrive, did the gesture recognize, did the model take the instruction. A joined playback surface holds no player loan, so controls keyed by the view answered "nothing plays here"; resolve the surface's own binding (`VideoPlaybackController.watchedPlayer(in:)`).
- **`UIScreenEdgePanGestureRecognizer` never began for injected simulator touches.** The notifications drawer uses a position-gated `UIPanGestureRecognizer` instead.

## Swift concurrency

- **An actor's synchronous method called without `await` from a UIKit subclass** is only a warning (`#ActorIsolatedCall`) when the class is main-actor by inference, and it runs off the actor: a data race that crashed `ImagePipeline`. Treat that warning as an error. Shared state reached from both sides goes behind one `Mutex` in a `Sendable` class (PR #324).
- **A handler handed to PhotoKit, MediaPlayer or KVO traps at runtime.** A closure written inside a `@MainActor` type inherits its isolation, the block is imported without `@Sendable`, so the compiler accepts it and a dynamic check fires when the framework calls it on its own queue. Mark such closures `@Sendable` or build them in a `nonisolated` function (`PhotosMediaLibrary`, `MPMediaItemArtwork`, remote commands).
- **`swiftc -typecheck` does not run region-isolation checking.** A Sendability probe compiled that way proves nothing; use `-emit-sil -o /dev/null`.
- **A cancelled load still publishes.** Cancelled Connect calls fail with a transport error rather than throw `CancellationError`, so a superseded load returns truncated data that looks genuine. Check `Task.checkCancellation()` in loops and a load generation after every `await`, the failure branch included.
- **`async let` breaks request order.** Child tasks run on the concurrent executor, so two reloads ask in either order. Make the order-sensitive call from the task itself; only side calls go in `async let`.
- **A protocol extension method shadows its conformers.** Called through `any P`, a method declared only in an extension dispatches statically, so every conformer's override is invisible. A method conformers override must be a requirement (`ZoomTransitionSource.zoomLiveMediaSurfaceIfReady`).
- **Lazily decoded images in `Task.detached` exhaust the cooperative pool.** HEIC decodes in the simulator's software decoder parked every pool thread, so nothing async ran and UI tests timed out on idle processes. Decode once with `preparingForDisplay()` on a serial GCD queue (#1466, PR #1469).
- **Heavy drawing on a dispatch queue overflows its 512 KB stack** (Core Image renders). Give such work its own `Thread` with a larger stack.
- **`Hasher` is seeded randomly per process.** Never key anything that outlives the process (a file cache) on `hashValue`.
- **Code moved from the app into a package changes meaning.** See [Architecture § Packages and layers](ARCHITECTURE.md#packages-and-layers): the app target isolates to the main actor by default, packages do not.

## AVFoundation and media

- **A clip a phone recorded upright plays on its side.** `AVPlayerItemVideoOutput` hands out untransformed buffers and `AVSampleBufferDisplayLayer` does not apply the track's `preferredTransform`; `AVPlayerLayer` does. The sample-buffer path (`VideoRenderView`) does not honour it today. Synthesized fixtures all have an identity transform, so test with `Scripts/seed-simulator-videos.sh`'s rotated clip and compare with `-avplayer-render`.
- **On the iOS 27 simulator, an `AVPlayerItem` carrying any video composition fails** (-11800 / -12784) once something renders it. The same composition works in `AVAssetReader`, `AVAssetImageGenerator` and `AVAssetExportSession`; the editor preview reads composed frames through a reader (`ComposedFrameReader`). A reader's first frame waits for a decode from the previous keyframe: restart it only on a jump, and start a catch-up ahead of the clock.
- **An `AVAssetWriter` stalls forever on `isReadyForMoreMediaData`.** It interleaves and holds back whichever input runs ahead, so one loop that feeds audio and video in its own order waits on an input the writer is holding. Feed each input from its own task.
- **An export never completes, with no error.** An `AVAudioMix` volume ramp starting where a piece scaled to 3x or 4x begins froze `AVAssetExportSession` about one time in twelve. Avoid automation over a rate change, and stress-export any new audio automation in a loop with a watchdog before it ships (`SoundtrackCompositionTests`).
- **A volume ramp on a track's very first sample plays its first ~25 ms at full volume.** Set the level earlier, in the silence before the piece.
- **`CMTime(seconds:preferredTimescale:)` truncates** (55/600 becomes 54/600). Never round-trip ticks through seconds.
- **A category change under a playing clip cuts the sound and hitches the picture.** Never call `setCategory` on an active session while something is heard (#2185).
- **`AVAudioSession.setActive(false, options: .notifyOthersOnDeactivation)` blocks the main thread for about 0.6 s on a device** (under 1 ms on the simulator). Release the session off main (`VoiceSessionLine`).
- **`AVAsset` is not `Sendable`; `AVURLAsset` and `URL` are.** Inspect the asset inside the PhotoKit handler and resume only a `URL`. `AVMutableVideoComposition` is deprecated in iOS 26 (`AVVideoComposition.Configuration`).
- **A video URL as a post's thumbnail is a black tile.** The fetch succeeds and the decode fails. A thumbnail is a still.
- **Camera capture.** `AVCaptureDevice.RotationCoordinator(device:previewLayer: nil)` answers 0° for the preview; `movieOutput.isRecording` stays false until the first sample, so a stop guarded on it is dropped. Neither shows on the simulator.
- **Closing Picture in Picture back into the app shows 2–3 black frames.** It is the system's hand-back of a sample-buffer window; the app's window is not involved. Closed without a fix (#2156).
- **Lottie.** `loadAnimation(from:)` resets `loopMode` and `animationSpeed` to the file's manifest: set them after loading. A `LottieAnimationLayer` schedules a redraw on main when created; an off-main bake waits for that redraw and its commit before drawing. Snapshotting a frame with `layer.render(in:)` needs the main-thread engine; the Core Animation engine renders empty.

## MapKit

- **A custom `MKMultiPolygonRenderer` crashes on its first draw** with "unimplemented initializer 'init(overlay:)'": MapKit's initializer calls `init(overlay:)` on self. Override it, and test by building a renderer, since unit tests never draw.
- **`setVisibleMapRect(_:edgePadding:)` with large insets zooms out far too much.** Compute the rect for the visible band yourself.
- **Annotations with one flat `displayPriority` collide arbitrarily.** Rank them, under `.defaultLow`, so required markers always win.
- **MapKit's built-in clustering degrades across pan and zoom.** The app clusters with `MapClusterEngine`; no annotation sets `clusteringIdentifier` ([ADR 0015](decisions/0015-map-clustering-computed-by-the-app.md)).
- **The standard map stays flat with `.realistic` elevation.** Only hybrid or imagery configurations curve into a globe, and there is no public API for a standard globe. Reassigning `preferredConfiguration` rebuilds MapKit's internal view: set it once (`MapBaseConfiguration`).
- **The map ignores touches after a custom interactive pop.** UIKit ran the coordinated changes in a paused context, MapKit's edge-insets animation stayed at speed 0, and a view with an animation in flight is not hit-tested into. `MapsViewController.releaseFrozenAnimations(in:)` removes speed-0 animations in `viewDidAppear`. To diagnose, dump `animationKeys()` and each animation's `speed` up the hit view's ancestors.

## Text

- **`window.maximumContentSizeCategory` changes nothing on screen.** A `traitOverrides.preferredContentSizeCategory` on the window works (`TextSizeCeiling`).
- **`UIFont.preferredFont(forTextStyle:)` without traits reads the iPhone's text size** and ignores window traits. Use `UIFont.appFont(forTextStyle:)` or `scaledFont(forTextStyle:weight:)` (`ScaledFontGuardTests`). Offscreen measurement keys on the app's size, not the iPhone's.
