# Hero QA — the transition suite's simulator layers

The hero/zoom system's tests live in four layers; this directory holds the two
that need a simulator. The other two run in CI on every PR with no setup:
unit/logic suites in `Packages/*/Tests` (auto-discovered by `ci.yml`'s loop)
and the DEBUG in-app audit they all read (`App/Shell/HeroTransitionAudit.swift`,
armed by `-hero-audit`).

## The two commands

```sh
Scripts/hero-qa/run-uitests.sh [SuiteName]   # XCUITest: real fingers
Scripts/hero-qa/run.sh --all                 # visual: recorded frames, judged
```

Both write into `hero-qa-out/<timestamp>/` (gitignored).

**`run-uitests.sh`** drives the `UITests/Hero*` suites — real taps, real
grabs on both axes, the Case-B cluster loop, soak cycles, an
`XCTMemoryMetric` curve. Screenshots for every step are in the result bundle
(`.keepAlways` attachments). It flips Simulator's *Slow Animations* off for
the run and restores your setting on exit — that toggle silently ×10s every
animation and is undetectable in-process.

**`run.sh`** runs deterministic scripted flights (`cases.d/*.case`) on a
headless simulator, records at 30fps, and judges frames: did something
visibly fly (`motion`), was there a single-frame black dip (`no-black`, the
frame-0 flash family), did the screen come back to its pre-flight self
(`settle-baseline`, the stranded-card catcher), and does the audit log agree
(`audit` — liveness first: an empty log fails, a log without heartbeats
fails, a final census with residue fails). `summary.md` collects verdicts
plus an 8-frame evidence strip per case.

## The channel doctrine

- **The probe** (`hero;seq=…` accessibility identifier) is the UI suites'
  channel. `seq` is monotonic; every wait is "the audit sampled again after
  my gesture and read settled" — never a sleep.
- **The file sink** (`Documents/hero-audit.log`, recreated each launch) is
  the shell harness's channel. Trust it only with its liveness: heartbeat
  count, mtime vs build, and the census fields themselves.
- **Frames** are the only witness for compositing. Logs can read green over
  a broken screen; a screenshot cannot.

## Reading a failure

- `FAIL audit: <field>=N at final settle` — a transition object outlived its
  flight. The census keys map to `ZoomDebugCensus` (animators, interruptors,
  retries, cards) plus the window sweep (`stranded`) and the pool
  (`dupes` = one asset, two players).
- `FAIL settle-baseline` — the screen did not come back to its pre-flight
  self: a stranded card/replica, a missing tile, a tab bar that never
  repainted. Open `strip.png` and `settled.png` next to `baseline.png`.
- `FAIL no-black` — a frame composited with neither cover nor content
  mid-sequence; see the frame index in the output and step `run.mp4`.
- UI suite failure messages carry the census they last saw, with the cycle
  number for soak tests.

## Flake policy

Zero retries, with one exception: the real mid-air catch
(`HeroInterruptionUITests.testARealFingerCanCatchAndThrowBackAFlight`)
retries ×4 and `XCTSkip`s honestly if injection latency never landed a
finger on the 0.42s flight — the scripted `-zoom-interrupt` tests remain the
deterministic gate for both outcomes.

## Simulator traps this setup already dodges

- *Slow Animations* (see above) — `run.sh` goes headless, `run-uitests.sh`
  flips-and-restores the default.
- An orphaned `recordVideo` writes until the disk is full — the recorder is
  stopped with `kill -INT` on every path, trap included.
- `--console-pty` dies with its reader and stdout is block-buffered to files
  — the audit writes its own sink, and `AppDelegate` unbuffers stdout when
  any `*-log` argument is present.
- Video posts render black through `AVPlayerLayer` captures — the
  `-avplayer-render` legs assert through the audit only; pixel judges run on
  the default sample-buffer backing.
