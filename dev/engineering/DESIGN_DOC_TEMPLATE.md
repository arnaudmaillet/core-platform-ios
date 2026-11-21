# Design doc template

A core or large change ([Before you code § 4](BEFORE_YOU_CODE.md#4-size-the-change)) starts from a design doc, approved by the owner before any code.

- **Where:** `dev/design/<issue>-<short-name>.md`, opened as a pull request of its own, or linked from the issue while it is reviewed.
- **Length:** as short as the decision allows. Two pages are usually enough. Trade-offs matter more than detail.
- **After approval:** the decision it takes becomes a [decision record](decisions/README.md), and the plan becomes the pull requests.

Copy from here:

---

```markdown
# <Title>

Issue: #<n> · Author: <who> · Status: draft | in review | approved | superseded

## Problem
What is wrong or missing today, measured where possible. Who feels it.

## Goals and non-goals
- Goals: what this design must achieve, as checks a reviewer can verify.
- Non-goals: what it deliberately leaves out.

## Prior art
How others solve this problem, with links:
- the large apps (engineering blogs, talks, open source);
- the platform (Apple's frameworks, WWDC sessions);
- the literature, when the problem has one.
At least two approaches, and what each costs.

## Similar and neighbouring components
What already exists in this repository that does part of the job, and what this design reuses, extracts or leaves apart.

## Design
The chosen approach: the types and protocols, which package each lives in, how data flows, who owns which state. A diagram when it helps.

## Alternatives considered
Each serious alternative, and why it was not chosen. "Do nothing" is one.

## Risks and measurements
What could go wrong, and how it will be seen: a spike's figures, a measurement before and after, a guard that will hold the new rule.

## Plan
The pull requests, in order, with the packages each touches and how each is verified.

## Decisions needed
The questions only the owner can answer.
```
