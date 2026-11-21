# Test traps

Ways a test in this repository went red for a reason outside the code under test, or stayed green while the code was broken. Read the first two sections before writing a test; the rest when a run fails strangely. The rules they lead to are in [Testing](TESTING.md). Platform behaviour the tests ran into is in [Platform traps](PLATFORM_TRAPS.md).

## Suites run side by side

Swift Testing runs suites in parallel in one process. On a starved CI runner they overlap completely; locally they rarely do. **A red that repeats with identical values across runs is a leak between suites, not a flake** (#2392).

- **Process-wide state set by one test is seen by another.** A forced policy, a `static var`, a preference store, `ConnectivityMonitor.shared`, `UIPasteboard.general`. Inject the state into the object under test (`ConnectivityMonitor(offlineGrace: 0)`), or keep set → assert → reset synchronous: every `await` hands the main thread to the other suites while the value is forced.
- **`.serialized` on a suite does not protect a global from other suites.** Use a cross-suite lock trait: `.ownsToastClock` (DesignSystem) for the toast clock, `.exclusiveMediaWork` (MediaPlayback) for suites that export, compose or measure real time. The media lock is not re-entrant: never on a suite nested in another that has it.
- **Fake keyboard notifications move every screen in the process.** Post them with `object:` set to the test's window and pair each show with a hide in a `defer`; screens filter through `KeyboardNotificationScope`.
- **A real keyboard rises in every window.** A focused field brings up the system keyboard on CI (about 290 pt), never locally, where the hardware keyboard reduces it to a bar. Call the test helper `raisesNoKeyboard()` before focusing any real field (PR #2406).
- **A heavy suite starves real-time suites.** Decoding, exporting or pixel work on the main actor made MediaPlayback's timing tests miss deadlines while each passed alone. Do heavy work off the main actor, keep it to seconds, and carry `.exclusiveMediaWork`.
- **Real audio on the main actor stalls every suite** when the runner's audio device drops (each `play()` waits 2.5 s). Test processes never start real audio (`UISound.silencedInTests`). The tell: many tests "passed after" hundreds of seconds and `AQME` lines in the log (PR #1845).

## Waiting

- **Never bound a wait by the clock.** A starved runner freezes the process past any deadline, then the wait gives up before the work ran. Wait with a budget of looks (`settle(looks:isolation:until:)`, TestSupport), returning early, and `#require` or `#expect` its result.
- **Never poll a state that ends on its own** (a 0.2 s play loop). A starved test resumes after it has come and gone. Assert an event counter or a recorded fact, and give the expectation a message that names which guard refused.
- **Never poll a utility-priority fill** (cache lookahead, speculative prefetch) against any budget: the waiting test outranks the work. Await its landing: `ImagePipeline.prefetchLanded`, `VideoByteCache.headPreloadLanded`, `FillProbe`.
- **A loading gate holds content on purpose.** Behind `SkeletonGate` / `ScreenLoadingHost`, a first page that lands after the 0.15 s delay is held for the 0.3 s minimum, and past 10 s the gate swaps bones for "Taking longer". Wait on the data having answered, not on the bones' absence, and inject a manual `LoadingClock` in new tests.
- **Reading the clock twice.** Passing `now: CACurrentMediaTime() + 0.001` to time-stepped code measures whatever the machine spent between the two lines. Derive `now` from the timestamp the code recorded.
- **A discarded view model drops its answers.** `let (_, shown) = await load(…)` releases the view model; its `[weak self]` tasks then drop late answers. Bind it and keep it alive to the end (`withExtendedLifetime`).
- **Wait for every read the action needs.** A view model that loads two things in parallel can answer one first: its actions then guard on the other and silently do nothing.

## UIKit in the test host

- **A modal presentation never completes in a package test host**, even unanimated: `isBeingPresented` stays true. Assert the synchronous state only, and verify the rest in the app. Pushes do complete.
- **A view off a window ignores `overrideUserInterfaceStyle`.** Host it in a hidden window whose style is the one you want. Keep the simulator itself in light mode for appearance tests.
- **A hidden window never installs its root view controller's view.** Add the views under test to the window itself.
- **A visible window stored on a suite crashes the run.** Swift Testing makes a suite instance per test and frees the window while it is still visible (EXC_BAD_ACCESS in `_updateSafeAreaInsets`). Make the window per test inside a `hosting { … }` helper that takes it down at the end (remove its subviews, hide it, lay out), as the CoreNavigation suites do.
- **Pixel reads lie.** `CALayer.render(in:)` ignores `maskedCorners` and rounds all four corners; `drawHierarchy(in:afterScreenUpdates:)` draws nothing in the test host.
- **Two `CGFloat`s that arrive by different arithmetic differ by an ulp,** and a `[Double]` literal passed to a `CGFloat` API compares unequal while printing the same. Type the literals and compare layout with a tolerance.
- **Layout tests fail on a simulator left at a large text size.** Reset content size to `large` before running suites.

## Assertions that cannot fail

- **A laundered assertion.** Asserting on `outer(inner(x))` when `outer` repeats `inner`'s job lets `inner`'s guards be deleted with every test green. Assert on the value that is stored or sent, then delete the guard and watch the test go red.
- **An identity cannot catch an arithmetic defect.** Give fixtures different values wherever "against which one" is the question.
- **Break one rule at a time** when proving a test can fail; breaking two can make it pass for the wrong reason.
- **A measurement that equals a constant in the code is a coincidence until you vary the input.** Repeating one input measures stability, not generality.
- **Rewriting a test file drops its other suites.** A file often holds several suites. Edit it; before and after, compare the `@Test` lines against `origin/develop`.

## CI and the toolchain

- **CI compiles with Xcode 26; locally only Xcode 27 is installed.** Xcode 26 rejects:
  - a local named like the function or property its own initializer calls: `let page = page()`, `let x = lock.withLock { x }`. Write `self.page()` or rename;
  - a `let pool = pool` copy placed after a closure that uses `pool`;
  - long `+` chains of strings and untyped literals mixing enums and arithmetic (type-check timeout). Build strings from typed locals;
  - a framework type used without its `import`, even when Xcode 27 resolves it transitively;
  - `try #require(x)(y)`, which crashes the type checker: bind first.
- **CI also builds Release.** An import under `#if DEBUG` hides a missing import in Release.
- **CI is the only iOS 26 runtime.** API restrictions that iOS 27 dropped show up there first.
- **CI never compiles `UITests/`.** The app build and the package lanes skip the UI test target; only the UI smoke workflow (`hero-uitests.yml`, nightly or dispatched) builds it. After editing a UI test, build that target (`build-for-testing`), and re-read every hunk of a mechanical search-and-replace (#2494, #2498).
- **A contracts pin bump breaks test stubs in lanes the diff does not select.** Generated `*ServiceClientInterface` protocols gain requirements with no default. Add the new RPCs to every conforming stub (`git grep ServiceClientInterface -- 'Packages/**/Tests/**'`), and check exhaustive `switch`es over generated enums.
- **Compilation caching** is CI-only; see [ADR 0010](decisions/0010-compilation-cache-in-ci-only.md).

## Running suites locally

`CLAUDE.md` says what runs locally before a pull request. When you do run a suite, to debug:

- **`-only-testing` down to a test name runs zero Swift Testing tests** and still prints `TEST SUCCEEDED`. Filter by suite, and check the count of tests that ran.
- **A failing run seems to hang for ten minutes** after its results: xcodebuild runs `simctl diagnose`.
- **A run that stops with `xctest` at 0% CPU** is usually the simulator stuck in UIKit's first `UIScreen` initialization, not a deadlock in the change. Sample the main thread before touching code; shut that simulator down and rerun.
- **A UI query that times out with every process idle** can be the app's cooperative pool exhausted (see [Platform traps § Swift concurrency](PLATFORM_TRAPS.md#swift-concurrency)). Sample the app and count blocked pool threads.
- **One test run per simulator at a time.** Two runs on one simulator kill a runner.
- **Share one DerivedData between suites, run one after another.** A folder per suite recompiles every shared dependency. Two `xcodebuild` processes never share a folder at the same time.
- **A new package resource is "not found".** The resource bundle copied inside an existing `.xctest` in a shared DerivedData does not refresh. Delete the stale `<Pkg>_<Pkg>.bundle` copies. CI builds clean.

## Verifying in the simulator

- **Slow Animations multiplies every duration about ten times** and is invisible from inside the process. Anything about duration needs a headless boot.
- **An empty log reads like a passing one.** Check the instrument ran before reading its silence: a DEBUG QA hook prints `[qa] GAVE UP <label>` when its state never came (`QAWait`); grep for it first.
- **Launch arguments built in a zsh variable arrive as one argument**, and every flag is silently absent. Pass them literally, or as a zsh array.
- **`-select-tab` and `-switch-tab` take an index.** A name is ignored without a word.
- **`-auto-pop` is not the back button.** It pops the stack without running the screen's own close; `-snap-auto-dismiss` takes the chevron's path.
- **Decorative animation rests after 30 s without a touch** (`IdleCalm`). Pass `-idle-calm-off` when filming it.
- **A simulator's photo library holds no video.** Run `Scripts/seed-simulator-videos.sh`, then relaunch: the media library snapshots once. `-upload-fake-library` swaps in a different library and tests a different path.
- **The iOS 27 simulator's Photos picker selects and never calls `didFinishPicking`.** The app is healthy; check on a device.
