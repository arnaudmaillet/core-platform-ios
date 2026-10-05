# Working in this repository (agent sessions)

Several Claude sessions work on this repository at once. These rules keep them
from fighting over `develop` and over CI.

## Merging into `develop`

- One **coordinator session** merges, one pull request at a time, in queue
  order, once CI is green. Every other session opens its pull request and stops
  there: no `gh pr merge`, no auto-merge, no `update-branch`.
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
  request's CI, and macOS runners are capped at 5 concurrent jobs for the whole
  account. One run (app build + test lanes) takes all of them.
- Batch a round of iterations into a single push.
- Stacked pull requests (base other than `develop`) run no CI, so pushing
  those is cheap.

## CI shape (`.github/workflows/ci.yml`)

- A pull request runs only the test lanes `.github/scripts/select_packages.py`
  selects from its diff. A pull request can therefore be green and still break
  a test in a package it never touched. Repo-wide guards live in single
  packages, e.g. DesignSystem's `ScaledFontTests` and the haptics guard.
- The run on `push: develop` is the full-suite backstop. A red `develop` run
  blocks the queue until a fix lands.
