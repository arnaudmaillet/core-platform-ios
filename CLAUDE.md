# Working in this repository (agent sessions)

Several Claude sessions work on this repository at once. These rules keep them
from fighting over `develop` and over CI.

## Merging into `develop`

- One **coordinator session** merges, one pull request at a time, in queue
  order. Every other session opens its pull request and stops there: no
  `gh pr merge`, no auto-merge, no `update-branch`.
- `develop` does **not** require a pull request to be up to date before it
  merges. The coordinator merges a pull request as soon as **its own CI run**
  on its current head is green and it has no conflict: there is no second
  run. **The run you get when you open or push is the one that decides.**
- So open (or push to) a pull request only when the work is finished:
  - **rebase on a fresh `origin/develop` first**, so the run tests something
    close to what will land;
  - locally, **build the app in Debug, and run no test suite** (owner,
    2026-11-18). The Debug build, `#if DEBUG` code included, keeps a CI run
    from being spent on a compile error. The rest is CI's job: `build app`
    builds Debug and Release, and the lanes run every suite the change
    reaches. Running those locally as well did the work twice and made every
    change wait for a free Mac. A test-only change needs no app build: build
    its package's tests (`build-for-testing`) and push.
  - CI compiles with Xcode 26, which can reject Swift that a local Xcode 27
    accepts.
  - An **app build** and simulator captures wait until the self-hosted
    runner is idle **and** no workflow run is in progress. The background
    QoS (`taskpolicy -b xcodebuild …`) limits CPU and disk, not memory: a
    Debug app build beside a Mac job turned #2449's Upload lane red (a video
    poster that failed to decode, 2026-11-14).
- **Group a large piece of work into a few pull requests by area**, one
  commit per issue (owner, 2026-11-18, for audit #2366). Every pull request
  costs a local pass, its CI run and a full `develop` run on the one Mac, and
  every merge sends the next branch back to a rebase. One pull request per
  small issue multiplies all three. Keep the riskiest piece in a pull request
  of its own.
- Prefer independent pull requests based on `develop`. **Stack only for a real
  dependency.** A stacked pull request has to be replayed and tested again once
  its predecessor lands. When two sessions touch the same files, coordinate:
  one waits for the other to merge, or they stack.
- After opening a pull request, message the coordinator with its number, what
  it touches, and whether it is stacked.
- **Stacked pull requests**: base each one on the previous branch and tell the
  coordinator each pull request's *own* commit(s). The coordinator retargets it
  to `develop` and replays only those commits once its predecessor has landed.
- A conflict, or a red CI on your pull request, comes back to you. The
  coordinator never resolves it for you.
- Never delete a branch that another open pull request uses as its base:
  GitHub closes that pull request, and it cannot be reopened.

## Pushing to an open pull request

- **Commit locally; push only when the pull request's current CI run has
  finished, or when the work is ready for review.** Each push restarts that pull
  request's CI. Its lanes share a few macOS runners, four GitHub slots or
  one self-hosted Mac (see CI shape). A stale push makes every other
  session's lanes wait behind it.
- Batch a round of iterations into a single push.
- Stacked pull requests (base other than `develop`) run no CI, so pushing
  those is cheap.

## CI shape (`.github/workflows/ci.yml`)

- A pull request runs only the test lanes `.github/scripts/select_packages.py`
  selects from its diff. A pull request can therefore be green and still break
  a test in a package it never touched. The repo-wide source-scan guards and
  the package-layering guard live in `Packages/Tools/RepoGuards`, whose lane
  every pull request runs (#2371).
- The run on `push: develop` is the full-suite backstop and never cancels
  itself: one runs at a time, and the newest develop waits its turn. It is the
  only check on two pull requests that are green apart but break together. **A
  red `develop` run blocks the queue**: the session whose change broke it pushes
  a fix first, ahead of everything else.
- Where each job runs:
  - `build app` (Debug + Release) always runs on GitHub's `macos-latest`,
    **Xcode 26**: the guard against Swift only Xcode 27 accepts.
    `compile tests (Xcode 26)` does the same for the Mac lanes' tests, so it
    runs only while lanes run on the Mac: `MACOS_RUNNER=github` skips it.
    `build app` builds Release twice (#2391): `core-platform-ios-production`, the real
    backend only, checked for mock symbols; and Demo, the mock target in Release.
  - `swiftlint (report-only)` runs on `ubuntu-latest`, in SwiftLint's container
    (#2519): a pull request lints the Swift files it changes, a push to develop
    lints them all and writes the count per rule to the job summary. It is not
    part of `build-test` yet: findings are annotations, not a red check.
  - **The test lanes, by repository variable:**
    - `MACOS_RUNNER=github` (set since 2026-11-18, the owner: one session
      works on the repository during audit #2366): **every lane runs on
      GitHub's `macos-latest`, Xcode 26**, four at a time for a pull request
      and three for `develop`. `compile tests (Xcode 26)` is skipped, since the
      lanes are Xcode 26 themselves. The self-hosted Mac stays free for local
      builds.
    - Unset: the data-and-logic lanes (`HOSTED_LANES` in
      `select_packages.py`) run on `macos-latest`. Every other lane runs on
      the **self-hosted Mac, Xcode 27**, one job at a time: the suites that
      measure time, play media or animate. `HOSTED_LANES_ON_MAC=1` sends the
      hosted lanes to the Mac too, for when GitHub has no macOS capacity
      (#2486).
    - On the Mac, every package builds from scratch: DerivedData lives in the
      job's temporary directory and is deleted after the package's tests, so
      no lane is green on a stale module. If the Mac is off, its lanes wait
      in the queue and the required `build-test` check never arrives.
  - A rerun keeps the original run's variables. To pick up a changed
    variable, push a new commit (an empty one will do).
