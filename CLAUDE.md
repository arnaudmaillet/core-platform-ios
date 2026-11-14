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
  - run the touched packages' tests **and a Release build** locally. CI builds
    the app with Xcode 26, which can reject Swift that a local Xcode 27
    accepts, and it builds Debug and Release.
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
  request's CI. Most test lanes queue on **one self-hosted Mac that runs one
  job at a time**, the rest on GitHub's five hosted macOS slots shared by the
  whole account (see CI shape). A stale push makes every other session's
  lanes wait behind it.
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
  - `build app` (Debug + Release) and `compile tests (Xcode 26)` on GitHub's
    `macos-latest`, **Xcode 26**: the guard against Swift only Xcode 27
    accepts, for the app and for the Mac lanes' tests.
  - the data-and-logic lanes (`HOSTED_LANES` in `select_packages.py`: models,
    storage, networking, Chat, Search, Auth…) on GitHub's `macos-latest`,
    **Xcode 26**, as `test … (hosted)`, three at a time for a pull request
    (#2370).
  - every other lane (and `hero-uitests.yml`) on a **self-hosted Mac, Xcode
    27**, one job at a time: the suites that measure time, play media or
    animate. Every package builds from scratch there: DerivedData lives in the
    job's temporary directory and is deleted after the package's tests, so no
    lane is green on a stale module.
  - If that Mac is off, its lanes wait in the queue and the required
    `build-test` check never arrives. Setting the repository variable
    `MACOS_RUNNER=github` sends every lane to `macos-latest` with Xcode 26.
