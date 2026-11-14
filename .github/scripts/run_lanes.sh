#!/bin/bash
# Runs a test job's lanes, one after another (ci.yml, `test` and `test-hosted`).
#
# LANES is `dir name scheme shard` per package, `-` for an empty field
# (select_packages.py). A long lane is one shard of a package (#2370: Feed in
# two); short ones share a job, paying its fixed cost (checkout, Xcode,
# mirrors, a simulator boot) once. Each package gets its own DerivedData, in
# the job's temporary directory, so no module leaks onto another's search
# path; it is deleted once the package's tests have run.
#
# Reads LANES, NO_INDEX, GITHUB_WORKSPACE and RUNNER_TEMP; TEST_RUNNER_*
# variables pass through to the test runner.
# `bash -e`, as the `run:` step this was, and pipefail.
set -eo pipefail
SPM="$GITHUB_WORKSPACE/.spm"
read -ra FIELDS <<< "$LANES"
FAILED=()
for ((i = 0; i < ${#FIELDS[@]}; i += 4)); do
  DIR="${FIELDS[i]}"; NAME="${FIELDS[i+1]}"
  PINNED="${FIELDS[i+2]}"; SHARD="${FIELDS[i+3]}"
  [ "$PINNED" = "-" ] && PINNED=""
  [ "$SHARD" = "-" ] && SHARD=""
  echo "::group::$NAME${SHARD:+ ($SHARD)}"
  DERIVED="$RUNNER_TEMP/DerivedData/$NAME${SHARD:+-${SHARD%/*}}"
  if ! (
    cd "$GITHUB_WORKSPACE/$DIR"

    # On a fresh runner xcodebuild reports "Supported platforms for
    # the buildables is empty" and falls back to My Mac unless the
    # package resolves first.
    xcodebuild -resolvePackageDependencies -scheme "$NAME" -clonedSourcePackagesDirPath "$SPM"

    # Multi-product packages (e.g. CoreNetworking + CoreNetworkingMocks)
    # put the test action on the auto-generated "<name>-Package"
    # scheme, not the product scheme; single-product packages only
    # have "<name>". Prefer -Package when it exists, unless the
    # matrix pinned a scheme.
    SCHEME="$PINNED"
    if [ -z "$SCHEME" ]; then
      SCHEME="$NAME"
      if xcodebuild -list -clonedSourcePackagesDirPath "$SPM" 2>/dev/null \
           | grep -qE "^[[:space:]]+${NAME}-Package$"; then
        SCHEME="${NAME}-Package"
      fi
    fi
    echo "Using scheme: $SCHEME"

    # CoreSimulator enumerates its devices lazily, and asking too
    # early gets an answer with the "Any iOS Simulator Device"
    # placeholder and nothing else (run 33816841427: MediaPlayback
    # green and red on the same scheme). Warm the list, then retry.
    xcrun simctl list devices available >/dev/null 2>&1 || true

    # A concrete iPhone simulator from xcodebuild's own destination
    # list for THIS scheme (guaranteed valid). The `|| true` on the
    # assignments: under `bash -e` and pipefail a grep that matches
    # nothing would abort here, before the diagnostic below runs.
    DEST_ID=""
    for attempt in 1 2 3 4 5 6; do
      DESTS=$(xcodebuild -scheme "$SCHEME" -showdestinations \
        -clonedSourcePackagesDirPath "$SPM" 2>&1) || true
      DEST_ID=$(printf '%s\n' "$DESTS" \
        | grep 'platform:iOS Simulator' | grep -iE 'name:iPhone' \
        | grep -oE 'id:[0-9A-Fa-f-]+' | head -1 | cut -d: -f2) || true
      if [ -n "$DEST_ID" ]; then
        break
      fi
      echo "attempt $attempt: no iPhone destination yet, retrying"
      printf '%s\n' "$DESTS" | tail -20
      sleep 10
    done
    if [ -z "$DEST_ID" ]; then
      echo "::error::No iPhone simulator destination for scheme $SCHEME after 6 attempts"
      xcrun simctl list runtimes | grep -i ios >&2 || true
      exit 1
    fi
    echo "Using simulator id=$DEST_ID (attempt $attempt)"

    # A shard's filter (#2370): `-only-testing` for its suites, or,
    # for the last shard, `-skip-testing` for every other shard's —
    # so a suite the script cannot see still runs.
    FILTER=()
    if [ -n "$SHARD" ]; then
      read -ra FILTER <<< "$(python3 -I "$GITHUB_WORKSPACE/.github/scripts/test_shard.py" . "${SHARD%/*}" "${SHARD#*/}")"
      echo "Shard $SHARD: ${#FILTER[@]} filter arguments"
    fi

    # ⚠️ DO NOT BOOT THE SIMULATOR DURING THE BUILD (PR #354: a
    # first boot on a 3-core, 7 GB runner starves the compiler). The
    # boot stays where `xcodebuild test` puts it, after the build;
    # a job's later packages find it booted.
    #
    # No sysdiagnose on a red test: it added ~1m40s to every failing
    # lane (run 36904429986) and nothing ever downloads it.
    xcodebuild test -scheme "$SCHEME" -destination "id=$DEST_ID" \
      -clonedSourcePackagesDirPath "$SPM" -derivedDataPath "$DERIVED" \
      -skipMacroValidation "$NO_INDEX" \
      -collect-test-diagnostics never "${FILTER[@]}"
  ); then
    FAILED+=("$NAME${SHARD:+ ($SHARD)}")
    echo "::error::$NAME${SHARD:+ ($SHARD)} failed"
  fi
  rm -rf "$DERIVED"
  echo "::endgroup::"
done
if [ ${#FAILED[@]} -ne 0 ]; then
  echo "::error::Failed in this job: ${FAILED[*]}"
  exit 1
fi
