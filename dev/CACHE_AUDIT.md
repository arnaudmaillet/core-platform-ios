# `-cache-audit`: the device cache instrument (#900)

Budgets, tiers and lookahead windows of the device cache (epic #890) are
guesses until measured. `-cache-audit` (DEBUG builds only) logs what every
cache namespace holds and does, so they can be tuned on measurements.

## Run it

```bash
UDID=C4C49B40-D825-48E2-BED6-CBDF7994A6A3   # your simulator
xcrun simctl launch $UDID cn.wynn.core-platform-ios -mock-auto-login -cache-audit
# optional: -cache-audit-interval 5   (seconds, default 10)

# read the log (a new run starts it afresh)
cat "$(xcrun simctl get_app_container $UDID cn.wynn.core-platform-ios data)/Documents/cache-audit.log"
```

Lines also go to stdout, each prefixed with `[cache-audit]`, so a console
capture greps them out. On stdout only, the image pipeline (#894) adds one
`[cache-audit] image <disk|network> <bucket> <media>` line per image it loads
from disk or the network.

Release signals on cue (#898), since a simulator cannot turn on Low Power or
Low Data Mode and has no scriptable memory warning:
`-cache-signal <name>@<seconds after launch>`, repeatable, with `name` one of
`memoryWarning` (UIKit's notification, to every observer), `memoryCritical`,
`lowPower`/`lowPowerOff`, `lowData`/`lowDataOff`,
`thermalSerious`/`thermalCritical`/`thermalNominal`. Each prints
`[cache-audit] debug signal <name>` when it fires. Background and foreground
are the real thing: open another app (`xcrun simctl launch $UDID
com.apple.Preferences`) and come back.

## When it logs

- `trigger=start`: once, when the app's coordinator starts.
- `trigger=interval`: every interval.
- `trigger=trim:<reason>`: after every trim the coordinator applies:
  `memoryWarning`, `memoryCritical`, `background`, `lowDisk(<pressure>)`,
  `viewerChanged`, `clear(<category>|all)`.

## What a block says

```
[cache-audit] t=42.0 trigger=interval limit=automatic diskPressure=normal policy=full network=wifi device=- memory=96.4MB disk=31.2MB waste=6%(12.9MB of 214.3MB)
[cache-audit]   ns=images medium=disk class=standard scope=public bytes=28.1MB/203.0MB(14%) entries=212 pinned=0.0MB tiers=speculative:3.2MB,recent:24.9MB,retained:0.0MB hits=180 misses=212 hitRate=46% removed=none speculative=stored:40/4.1MB,used:6/0.9MB,wasted:0/0.0MB,discarded:0/0.0MB waste=0%
[cache-audit]   ns=images.decoded medium=memory class=standard scope=public bytes=88.0MB/214.7MB(41%) entries=104 pinned=12.6MB tiers=... removed=budget:12/10.3MB,memoryWarning:4/3.4MB ...
[cache-audit]   prefetch images=ready:120,inFlight:8,missed:14,hitRate:85% nextVideoFirstRange=0/0(-) timeToFirstFrame=n:0,p50:-,p90:-,max:- fetched=P0:12.0MB,P1:30.1MB,P2:8.2MB p2Cellular=0.0MB
```

**Header**

| Field | Meaning |
|---|---|
| `t` | Seconds of system uptime. |
| `trigger` | What logged this block (see above). |
| `limit` | The Settings → Storage limit (`automatic`, or a total). |
| `diskPressure` | `normal`, `low` (< 5 GB free, every pool halved), `critical` (< 1 GB). |
| `policy`, `network` | The prefetch policy (`full`, `cellular`, `reduced`, `off`) and the network path it follows, flagged `(expensive)`, `(constrained)` (Low Data Mode) or `(lessCellularData)` (Settings → Storage → Use Less Cellular Data, #899). |
| `device` | What else the policy follows (#898): `background` (no prefetch, no new decode kept in memory), `lowPower`, `thermal:<state>` when not nominal; `-` for none. |
| `memory`, `disk` | Bytes held in every memory and every disk namespace. |
| `waste` | The app's waste ratio: speculative bytes evicted or expired unused, over the speculative bytes whose fate is known (used or wasted). |

**One line per namespace and medium**

| Field | Meaning |
|---|---|
| `ns`, `medium`, `class`, `scope` | The namespace, where it lives, its priority class and whose data it holds. |
| `bytes` | Bytes held / the budget the coordinator gave it (share used). |
| `entries`, `pinned` | Entries held; bytes held by leases (never evictable). |
| `tiers` | Unleased bytes per tier. |
| `hits`, `misses`, `hitRate` | Lookups that found an entry, and the share. |
| `removed` | Entries/bytes removed per reason: `budget`, `memoryWarning`, `memoryCritical`, `background`, `lowDisk`, `viewerChanged`, `clear`, `expiry`, and `trim`/`wipe` for calls that named no reason. |
| `speculative` | What became of prefetched entries: `stored`, then `used` (read, leased or overwritten at a higher tier), `wasted` (evicted or expired unused) or `discarded` (wiped, removed, replaced by another prefetch). |
| `waste` | The namespace's waste ratio. |
| `indexWrites` | Disk lines only: index files the store wrote since launch — every `flushThreshold` changes, on background, after a wipe, and a few seconds after the last change (#1079); `delayed` counts the last kind. |

**The prefetch line** (`CachePrefetchCounters`, reported by the consumers)

| Field | Meaning | Reported by |
|---|---|---|
| `images=` / `videos=` | Items that reached the screen `ready` (already cached), `inFlight` (a prefetch was running) or `missed`, and the hit rate. | images: wired (`ImagePipeline`); videos: #895 |
| `nextVideoFirstRange` | Next full-screen videos that started on their preloaded first range. | #895 |
| `timeToFirstFrame` | Count, p50, p90 (last 256) and max. | #895 |
| `fetched` | Bytes the fetcher returned per fill priority (P0 visible, P1 next, P2 speculative). In mock mode the fetcher is local, so these are not network bytes. | images: wired; video: #895 |
| `p2Cellular` | P2 bytes fetched on a cellular or expensive path. | same |

Counters that no consumer reports yet read 0 or `-`.

**Images.** An image arrives when a cell asks for it to show: a hit of
`cachedImage(for:)` is `ready`; a visible `image(for:)` finds it decoded
(`ready`), on disk (`ready`, decoded from the preloaded bytes), joins a
prefetch in flight (`inFlight`), or fetches it (`missed`). Each image counts
once per stay on screen: the pipeline remembers the last 512 images that
arrived, so a cell's check, its configuration and the async load that follows
a miss are one arrival. Arrival tracking runs in DEBUG only.

## For a consumer

- Any `ManagedCache` registered with the coordinator appears with its usage
  and `statistics` (`MemoryCache`, `DiskStore` and `LocalStore` count every
  field). A cache with its own storage implements `statistics` and the
  reason-aware `trim(_:reason:)`, `setLimits(_:reason:)`,
  `removeAll(reason:)`, using `CacheStatistics.recordRemoval(_:count:bytes:)`.
- A wrapper that forwards to a store must forward the reason-aware calls and
  `statistics` too, or its line reads zero.
- Report what only the consumer knows on `coordinator.prefetchCounters`:
  `recordArrival(_:_:)` once per item that reaches the screen,
  `recordNextVideoStart(firstRangeHit:)`, `recordTimeToFirstFrame(_:)`, and
  `coordinator.recordTransfer(bytes:priority:)` for every network fill.

For the video byte cache (#895), which keeps `firstRangeHits` and
`firstRangeMisses` in its own `statisticsSnapshot`: wherever it counts one, it
also calls `coordinator.prefetchCounters.recordNextVideoStart(firstRangeHit:)`
with the same value, and the `nextVideoFirstRange` field fills in. Its
`ManagedCache` conformance supplies the namespace line.

The counters exist in Release (an addition under a lock the cache already
holds); the instrument, its timer and its file exist only in DEBUG.

## Budget soak tests

`Packages/Core/CacheKit/Tests/CacheKitTests/CacheBudgetSoakTests.swift`, in
the CacheKit test lane (CI selects it with any CacheKit change):

- `aScriptedLoadThroughTheCoordinatorKeepsEveryBudget`: 3,000 seeded steps
  over 4 memory and 5 disk namespaces (every class, scope and pool): stores,
  reads, leases, tier changes, every signal, Settings limit and free-disk
  changes, clock jumps. After every step: no namespace over its limit unless
  all it holds is pinned, speculative bytes within their cap, each pool's
  namespaces within the pool, held leases still served (until a wipe) and
  their files on disk, and every speculative byte accounted for.
- `fiveMinutesOfFeedImagesStayWithinTheDecodedBudget`: five minutes of
  virtual time on the decoded image namespaces as #894 registers them, with
  real decode sizes: two minutes of the For You grid, three of the
  full-screen feed, a memory warning and a trip to the background. Checked
  every 100 ms; also asserts the prefetch hit rate and the waste ratio.

Both run in well under a second (manual clock, no sleeps).
