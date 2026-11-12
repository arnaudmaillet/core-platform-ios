#!/usr/bin/env python3
"""Choose which package test lanes a run needs.

Every lane is a cold build of the shared dependency graph, so testing all
eighteen for a change that touches one of them is most of what a run costs. A
pull request only needs the packages it changed and the packages that depend on
them, transitively.

The closure is the whole safety argument, so it is computed from the manifests
rather than from a hand-written table: `Package.swift` declares its local
dependencies as `.package(path: "../../Kit/CoreModels")`, and a package is
affected when anything it depends on, at any depth, was touched.

Two backstops for the case where that reasoning is wrong. Pushes to develop
always run the full set, so an incomplete closure surfaces on the branch rather
than staying hidden. And anything the mapping does not recognise selects
everything, so a new top-level directory fails safe rather than silently
testing nothing.
"""

import json
import os
import re
import subprocess
import sys

ROOT = subprocess.run(
    ["git", "rev-parse", "--show-toplevel"],
    capture_output=True, text=True, check=True,
).stdout.strip()

# Paths that cannot affect a package test, because no package depends on them.
APP_ONLY = ("App/", "UITests/", "core-platform-ios.xcodeproj/", "dev/")
# Paths that select everything: the CI definition itself, and the tooling that
# generates sources into the packages.
EVERYTHING = (".github/", "Scripts/", "buf.gen.yaml")

# Median minutes per lane on the hosted runner: the last 15 green develop
# runs, 2026-11-11 to 11-12, measured for #2370. Only the ORDER matters:
# lanes are started in matrix order under `max-parallel`, so the longest go
# first and the short ones fill the gaps at the end. Alphabetical order once
# started Upload LAST and ran it alone for its whole length; the October
# table had CoreNavigation at 3 min (12.3 now), so it started last and ended
# four wide runs in five. A package missing here sorts as an average one; the
# table needs no upkeep to stay correct, only to stay optimal. Refresh it from
# `gh run list --workflow CI --branch develop` when lanes drift.
LANE_MINUTES = {
    "Feed": 15.9, "Upload": 14.7, "Maps": 12.7, "CoreNavigation": 12.3,
    "Chat": 10.2, "Profile": 10.2, "MediaPlayback": 9.6,
    "MediaPlayback (legacy AVPlayerLayer)": 8.8, "Search": 8.3,
    "DesignSystem": 8.1, "EmoteKit": 7.6, "PostGrid": 7.1, "HeroPage": 6.8,
    "CoreNetworking": 6.2, "Notifications": 6.1, "VoiceKit": 5.6,
    "StickerKit": 5.6, "Auth": 5.3, "MediaCore": 5.3, "ShareSheet": 4.8,
    "CacheKit": 4.7, "LocalStore": 3.4, "CoreRealtime": 3.3,
    "CoreStorage": 3.2, "AuthInterface": 3.2, "EntityStore": 2.9,
    "CoreModels": 2.6,
}
DEFAULT_LANE_MINUTES = 5.0

# The repository's guards read every source and every manifest, so a change
# anywhere can break one: every run that builds anything runs their lane
# (#2371). It depends on nothing and takes about a minute, so it sorts last.
ALWAYS = ("Packages/Tools/RepoGuards",)
LANE_MINUTES["RepoGuards"] = 1.0

DEP_RE = re.compile(r'\.package\(\s*path:\s*"([^"]+)"')
NAME_RE = re.compile(r'name:\s*"([^"]+)"')


def packages():
    """dir -> {name, has_tests, deps (dirs)} for every local package."""
    found = {}
    for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, "Packages")):
        dirnames[:] = [d for d in dirnames if d != ".build"]
        if "Package.swift" not in filenames:
            continue
        manifest = os.path.join(dirpath, "Package.swift")
        text = open(manifest, encoding="utf-8").read()
        name = NAME_RE.search(text)
        if not name:
            continue
        rel = os.path.relpath(dirpath, ROOT)
        tests = os.path.join(dirpath, "Tests")
        has_tests = os.path.isdir(tests) and any(
            f.endswith(".swift")
            for _, _, fs in os.walk(tests)
            for f in fs
        )
        deps = {
            os.path.relpath(os.path.normpath(os.path.join(dirpath, p)), ROOT)
            for p in DEP_RE.findall(text)
        }
        found[rel] = {"name": name.group(1), "has_tests": has_tests, "deps": deps}
    return found


def changed_files(base_sha):
    out = subprocess.run(
        ["git", "diff", "--name-only", base_sha, "HEAD"],
        capture_output=True, text=True, cwd=ROOT,
    )
    if out.returncode != 0:
        return None  # cannot tell what changed -> caller selects everything
    return [f for f in out.stdout.splitlines() if f]


def select(pkgs, files):
    """Directly-touched packages, or None when the change selects everything."""
    touched = set()
    for f in files:
        if f.startswith(EVERYTHING):
            return None
        if f.startswith(APP_ONLY) or ("/" not in f and f.endswith(".md")):
            continue
        if f.startswith("Packages/"):
            owner = max(
                (d for d in pkgs if f.startswith(d + "/")),
                key=len,
                default=None,
            )
            if owner:
                touched.add(owner)
                continue
        return None  # unrecognised path: fail safe
    return touched


def closure(pkgs, touched):
    """Touched packages plus everything that transitively depends on them."""
    dependents = {d: set() for d in pkgs}
    for d, meta in pkgs.items():
        for dep in meta["deps"]:
            if dep in dependents:
                dependents[dep].add(d)
    affected, queue = set(touched), list(touched)
    while queue:
        for d in dependents.get(queue.pop(), ()):
            if d not in affected:
                affected.add(d)
                queue.append(d)
    return affected


def entries(pkgs, dirs):
    out = []
    for d in sorted(dirs):
        meta = pkgs[d]
        if not meta["has_tests"]:
            continue
        out.append({"label": meta["name"], "name": meta["name"],
                    "dir": d, "scheme": "", "avsbdl": ""})
    # MediaPlayback's AVSampleBufferDisplayLayer backing is the process default
    # and layerClass resolves once per process, so the lane above only ever
    # covers the new path. This second lane forwards AVSBDL_RENDER=0 for the
    # legacy AVPlayerLayer backing. It pins the product scheme deliberately:
    # the -Package scheme would drag in siblings this pass does not need.
    mp = "Packages/Core/MediaPlayback"
    if mp in dirs and pkgs[mp]["has_tests"]:
        out.append({"label": "MediaPlayback (legacy AVPlayerLayer)",
                    "name": "MediaPlayback", "dir": mp,
                    "scheme": "MediaPlayback", "avsbdl": "0"})
    # Longest first (stable, so ties keep their directory order).
    out.sort(key=lambda e: -LANE_MINUTES.get(e["label"], DEFAULT_LANE_MINUTES))
    return out


def docs_only(files):
    """True when every changed file is documentation: nothing to build or test.

    Deliberately narrow — `.md` and nothing else, and never under a
    `Resources/` or `Fixtures/` directory: a README there can be bundled (or be
    named by a manifest), so it is a build input like any other resource. No
    DocC catalog exists to make Markdown elsewhere an input either.
    """
    def is_doc(f):
        parts = f.split("/")
        return f.endswith(".md") and "Resources" not in parts and "Fixtures" not in parts
    return bool(files) and all(is_doc(f) for f in files)


def main():
    pkgs = packages()
    base = os.environ.get("BASE_SHA", "").strip()
    testable = {d for d, m in pkgs.items() if m["has_tests"]}
    # The app build runs unless the change is documentation only.
    build_app = True

    if not base:
        chosen, why = testable, "not a pull request - testing everything"
    else:
        files = changed_files(base)
        if files is None:
            chosen, why = testable, f"cannot diff against {base[:7]} - testing everything"
        elif docs_only(files):
            chosen, why = set(), "documentation only - nothing to build or test"
            build_app = False
        else:
            touched = select(pkgs, files)
            if touched is None:
                chosen, why = testable, "change reaches outside the packages - testing everything"
            elif not touched:
                chosen, why = set(), "no package touched - app build only"
            else:
                affected = closure(pkgs, touched)
                chosen = affected & testable
                names = ", ".join(sorted(pkgs[d]["name"] for d in touched))
                why = f"touched: {names}"

    if build_app:
        chosen = set(chosen) | {d for d in ALWAYS if d in testable}

    matrix = entries(pkgs, chosen)
    print(f"Reason: {why}")
    print(f"App build: {'yes' if build_app else 'no'}")
    print(f"Lanes: {len(matrix)} of {len(testable) + 1} (longest first)")
    for e in matrix:
        print(f"  - {e['label']}")
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(f"matrix={json.dumps(matrix, separators=(',', ':'))}\n")
            fh.write(f"count={len(matrix)}\n")
            fh.write(f"app={'true' if build_app else 'false'}\n")
    else:
        print(json.dumps(matrix, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
