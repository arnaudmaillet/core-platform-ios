---
paths:
  - ".github/**"
  - "Scripts/**"
---
# Changing CI or scripts

- **Read `CLAUDE.md`'s CI shape first.** Every pull request runs only the lanes `.github/scripts/select_packages.py` selects, plus RepoGuards. `develop` runs everything.
- **Extend the existing script or job** rather than adding a second one that does part of the same thing.
- **A rerun keeps the original run's variables.** To test a changed variable, push a new commit.
- **A change to `ci.yml` updates `CLAUDE.md`'s CI shape** in the same pull request.
