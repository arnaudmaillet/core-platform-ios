#!/usr/bin/env python3
"""Print the xcodebuild filter arguments for one shard of a package's tests.

usage: test_shard.py <package dir> <shard> <count>    (shard counts from 1)

A long lane (Feed: 2,576 tests, about 10 of its 17 minutes in execution) is
split across jobs (#2370). Shards 1 to count-1 each take `-only-testing:` for
a set of top-level suites, balanced by source size. The LAST shard takes
`-skip-testing:` for every suite the others took, never a list of its own. So a
suite this script fails to see (an XCTest class, a suite declared in an
unusual way, a new file) still runs, in the last shard. Nothing is lost, only
balance.

The sharding is deterministic: the same tree always gives the same split.
"""

import os
import re
import sys

# A top-level test suite: a struct or class at column 0, optionally under
# attributes on the lines above (`@Suite(...)`, `@MainActor`).
SUITE_RE = re.compile(r"^(?:final\s+)?(?:struct|class)\s+([A-Z]\w*)", re.M)


def suites(package_dir):
    """{(target, suite): weight} for every test target under Tests/."""
    found = {}
    tests = os.path.join(package_dir, "Tests")
    for target in sorted(os.listdir(tests)):
        root = os.path.join(tests, target)
        if not os.path.isdir(root):
            continue
        for dirpath, _, files in os.walk(root):
            for name in sorted(files):
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(dirpath, name)
                text = open(path, encoding="utf-8").read()
                names = SUITE_RE.findall(text)
                # A file's weight is shared by its suites; tests, not
                # helpers, are what take time, so count the @Test marks.
                weight = max(1, text.count("@Test"))
                for suite in names:
                    found[(target, suite)] = found.get((target, suite), 0) + weight / len(names)
    return found


def split(found, count):
    """Greedy balance: heaviest suite first, onto the lightest shard."""
    shards = [[] for _ in range(count)]
    loads = [0.0] * count
    for key, weight in sorted(found.items(), key=lambda kv: (-kv[1], kv[0])):
        index = loads.index(min(loads))
        shards[index].append(key)
        loads[index] += weight
    return shards


def main():
    package_dir, shard, count = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    if count < 2 or not 1 <= shard <= count:
        return 0  # no sharding: no filter
    shards = split(suites(package_dir), count)
    if shard < count:
        args = [f"-only-testing:{target}/{suite}" for target, suite in sorted(shards[shard - 1])]
    else:
        taken = [key for index in range(count - 1) for key in shards[index]]
        args = [f"-skip-testing:{target}/{suite}" for target, suite in sorted(taken)]
    print(" ".join(args))
    return 0


if __name__ == "__main__":
    sys.exit(main())
