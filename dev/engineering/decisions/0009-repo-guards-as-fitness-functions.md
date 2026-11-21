# 0009. Repository rules run as tests on every pull request

Date: 2026-11-18 · Status: Accepted · Issues: #2371

## Context
Repository-wide rules (the layers, the shared components, the debug tools out of Release) were checked by scans scattered across packages' test suites. A pull request runs only the lanes its diff selects, so a change could break a rule in a package it never touched and still be green. Evolutionary architecture calls such checks fitness functions: automated tests of the architecture itself.

## Decision
- **Repository-wide scans live in one package, `Packages/Tools/RepoGuards`**, whose lane every pull request runs.
- **One guard per rule**, with a doc comment that states the rule and the issue behind it.
- **A guard that tracks a migration keeps a baseline**: a file's count of the old shape may only go down.
- **When a review comment repeats, it becomes a guard.**

## Consequences
- A rule holds across the repository whatever a pull request touches.
- A scan judges text, not meaning; rules with many legitimate exceptions (concurrency, errors) stay in review.
