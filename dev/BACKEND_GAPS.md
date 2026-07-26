# Backend / infra gaps — iOS fleet integration

Findings from wiring the iOS client to the local Docker fleet (Phases 1–5).
Each item is an issue on the **backend or infra side** that blocks or
complicates a client feature. The client side is implemented and, where
possible, worked around; these are the things that need a backend change for
full functionality.

| # | Gap | Blocks | Severity |
|---|-----|--------|----------|
| 1 | Realtime gateway resets WebSocket connections | Live counters, notifications, chat streams | **High** |
| 2 | Media processing worker not running | Posts with images (upload can't finalize) | **High** |
| 3 | Presigned media URLs use the Docker-internal host | Media upload + image delivery (client rewrite needed) | Medium |
| 4 | Services expose only gRPC/h2c (no Connect/gRPC-Web over HTTP/1.1) | Any native URLSession client (needs a gateway) | Medium (by design?) |
| 5 | Seed data has no avatars and only text-only posts | Nothing visual to render (images) | Low |
| 6 | IdP authenticates on bare username, not email | Login (a gotcha, easily worked around) | Low |
| 7 | `counter.v1` does not project profile follower/following counts | Profile counters (client falls back to social_graph) | Medium |
| 8 | Envoy gateway didn't route `search.v1` (fixed in-repo) | People search (fixed; needs a gateway restart) | Low |
| 9 | No seeded notifications | Activity tab shows empty against the fleet | Low |
| 10 | No seeded conversations | Messages list shows empty against the fleet | Low |
| 11 | `moderation.v1` unrouted + upstream port unknown | Profile "Report User" against the fleet | Medium |
| 12 | No account-level block RPC; alias enumeration is client-side | Profile "Block Account & All Profiles" is best-effort | Medium |

---

## 1. Realtime gateway resets WebSocket connections

**Status: still broken — re-verified 2026-07-08** (gateway had been restarted ~5h
prior). Two independent clients reproduce it: `websocat` → `EINVAL` (os error 22);
Node's built-in `WebSocket` → `OPEN` at 60ms then `CLOSE code 1006` (no close
frame) at 61ms. Handshake succeeds, teardown is immediate. Realtime work (live
feed counters, notification/comment/chat streams) stays blocked on this.

**Symptom.** The realtime gateway (`ws://localhost:8443/ws?access_token=<edge-token>`)
completes a valid WebSocket handshake (`101 Switching Protocols`, correct
`Sec-WebSocket-Accept`), then tears the TCP socket down within ~20ms with **no
WebSocket close frame** (`NSPOSIXErrorDomain 57` / ENOTCONN). The client then
reconnect-loops.

**Isolation (points squarely at the gateway):**
- A **passive raw socket** (handshake, then only reads) stays connected for seconds.
- **Active** WS clients fail on frame I/O: `URLSessionWebSocketTask` → ENOTCONN;
  `websocat` → `EINVAL`.
- `URLSessionWebSocketTask` connects and stays alive fine against a **reference**
  `ws://` echo server — so it is not the iOS client, ATS, or the environment.

**Repro:**
```bash
TOKEN=$(grpcurl -plaintext -d '{"grantType":"PASSWORD","password":{"username":"alice","password":"password"}}' \
  localhost:50060 auth.v1.AuthService/Login | jq -r .tokens.accessToken)   # or .accessToken
websocat "ws://localhost:8443/ws?access_token=$TOKEN"    # connects, then errors immediately
```

**Client impact.** No live updates at all — the feed's live like-counters, the
notification stream, and chat streams cannot function. The client wiring is
correct and will work unchanged once the gateway holds the connection.

**Suggested fix.** Investigate the realtime-gateway's WebSocket frame layer /
what it does immediately after `upgrade`. It resets standard active clients
(URLSession is the default native iOS/macOS client, so this blocks every native
app).

---

## 2. Media processing worker is not running

**Symptom.** Uploaded assets commit successfully (bytes land in minio) but stay
`MEDIA_ASSET_STATE_PENDING` forever — polled for 8s+, never advances. There is
no media-worker container (only `media-server`). `ResolveDelivery` therefore
returns a `PENDING` asset with **no rendition URL**.

**Repro:** IssueUploadTicket → PUT bytes → CommitUpload → then:
```bash
grpcurl -plaintext -d '{"assetId":"<id>"}' localhost:50063 media.v1.MediaService/GetAsset
# -> "state": "MEDIA_ASSET_STATE_PENDING" (indefinitely)
```

**Client impact.** A post *with an image* cannot be finalized: the compose flow
reaches `IssueUploadTicket → PUT → CommitUpload → ResolveDelivery` and then has
no CDN URL to attach. (The client now polls ResolveDelivery and errors clearly
on timeout.) Text-only posts are unaffected.

**Suggested fix.** Run the media processing worker so assets transition
PENDING → PROCESSING → READY and get delivery renditions.

---

## 3. Presigned media URLs use the Docker-internal host

**Symptom.** `IssueUploadTicket` returns a presigned S3 URL whose host is
`minio:9000` — the Docker-internal hostname, unreachable from the client
(simulator/host). The published minio is at `localhost:9000`, but the SigV4
signature signs the `host` header, so a naive host swap yields `403`.

**Repro:**
```bash
# PUT to the published host with the original Host header -> 200
curl -X PUT -H "Host: minio:9000" --data-binary @file \
  "http://localhost:9000/media/uploads/<id>?<presigned-query>"     # 200
# without the Host header -> 403 (signature mismatch)
```

**Client impact.** The client must rewrite `minio:9000` → `localhost:9000` and
re-send the original `Host` header (implemented as a dev-only host rewrite).
Delivery/download URLs are expected to have the same problem.

**Suggested fix.** Presign against a client-reachable endpoint — e.g. set
minio's public URL (`MINIO_SERVER_URL` / the media service's S3 public
endpoint) to `http://localhost:9000` for local dev — so no client rewrite is
needed.

---

## 4. Services expose only raw gRPC over h2c

**Symptom.** Every service speaks raw gRPC over **h2c** (HTTP/2 cleartext) and
rejects HTTP/1.1. `URLSession` (and thus connect-swift's URLSession transport)
cannot do h2c or raw gRPC.

**Client impact.** A native iOS client cannot reach the fleet directly. We run a
local **Envoy gRPC-Web gateway** (`dev/envoy/envoy.yaml`) that terminates
gRPC-Web over HTTP/1.1 and translates to the h2c gRPC upstreams; the client
talks to a single host (`http://localhost:8080`).

**Suggested fix / decision.** Fine if a gRPC-Web/Connect **edge gateway is the
permanent architecture** (production will have one). Otherwise, have the
services also serve the **Connect** or **gRPC-Web** protocol over HTTP/1.1 (or
TLS) so native clients don't need the local gateway.

---

## 5. Seed data has no avatars and only text-only posts

**Symptom.** Seeded profiles return empty `avatar_url`; seeded posts are
`POST_KIND_TEXT_ONLY` (no media). Combined with #2, there are **no image URLs**
anywhere in the fleet for the client to render.

**Client impact.** The real image fetcher is wired and verified (a JPEG
round-trips through minio and decodes), but nothing visual appears because there
is no seeded media.

**Suggested fix.** Seed a few profiles with avatars and some posts with media so
the image path is exercisable end to end.

---

## 6. IdP authenticates on the bare username, not the email

**Gotcha, not a defect.** The seeded user logs in as `alice` / `password`.
`alice@coreplatform.local` is **rejected** (`Unauthenticated: identity provider
rejected the credentials`). Worth documenting, or aligning the IdP to accept the
email form.

Related forward-looking gap: the login screen now accepts **phone numbers**
as identifiers (client normalizes to bare digits and forwards them through
`LoginRequest.username` — the wire contract has a single opaque string field).
There is no phone identity or OTP plane on the BFF/IdP. The client ships the
full phone UX (country-prefix entry, live formatting, OTP verification sheet
with `.oneTimeCode` AutoFill) but verification lands on an "isn't available
yet" alert; the seam is `LoginFlowCoordinator.beginOTPVerification(e164:display:)`
— SMS dispatch goes there before presenting, and `onVerify` exchanges the
code for a session once the backend exists.

---

## 7. `counter.v1` does not project profile follower/following counts

**Symptom.** `counter.v1.BatchGetCounters` for a `COUNTER_ENTITY_TYPE_PROFILE`
entity with metrics `FOLLOWER`/`FOLLOWING` returns a snapshot with **no
`values`** — even for a profile that has real edges in `social_graph.v1`. The
counter read-model is never populated for these metrics (the counter-worker does
not appear to consume `social_graph` follow/unfollow events).

**Isolation (counter empty, but the graph is not):**
```bash
PID=019f39be-6b86-7022-808b-bae992a25908   # alice

# counter.v1 → empty snapshot, no values
grpcurl -plaintext -d '{"entities":[{"entityType":"COUNTER_ENTITY_TYPE_PROFILE","id":"'$PID'"}],
  "metrics":["COUNTER_METRIC_FOLLOWER","COUNTER_METRIC_FOLLOWING"]}' \
  localhost:50064 counter.v1.CounterService/BatchGetCounters
# -> { "snapshots": [ { "entity": {...} } ] }   ← no "values"

# social_graph.v1 → the edges plainly exist (2 followers, 2 following)
grpcurl -plaintext -d '{"followeeId":"'$PID'","limit":50}' \
  localhost:50053 social_graph.v1.SocialGraphService/ListFollowers   # 2 edges
grpcurl -plaintext -d '{"followerId":"'$PID'","limit":50}' \
  localhost:50053 social_graph.v1.SocialGraphService/ListFollowing   # 2 edges
```

**Client impact.** The profile screen's headline metric. Reading counts from
`counter.v1` alone renders "—" for **every** profile, even ones with followers.
**Worked around:** `ProfileRepository` treats an empty counter as a cache miss
and falls back to counting a bounded page of `social_graph.v1` edges (exact when
the page is complete, `atLeast(n)` when truncated). Verified end-to-end against
the fleet: alice renders **2 / 2**. The fast `counter.v1` path takes over
automatically once the projection lands — no client change needed.

**Suggested fix.** Have the counter-worker project `FOLLOWER`/`FOLLOWING` on the
`PROFILE` entity from `social_graph` follow/unfollow Kafka events (the same
pattern `LIKE` already uses on `POST`). Counting via graph pagination is an O(n)
stopgap; the O(1) read-model is the right home for these counts.

---

## 8. Envoy gateway did not route `search.v1` (fixed in this repo)

**Symptom.** People search failed in-app ("Couldn't search") even though the
search service itself works: `grpcurl -plaintext localhost:50062
search.v1.SearchService/Search` returns hits. The app goes through the Envoy
gateway (`localhost:8080`, gRPC-Web); grpcurl hit the raw gRPC port directly.

**Root cause.** `dev/envoy/envoy.yaml` had no route or cluster for
`search.v1.SearchService`, so the gateway 404s the path. The gateway config is
**in this repo**, so this was fixed here (added a `search` route + a
`search-server:50062` cluster, mirroring the other 12 services).

**To apply:** restart the gateway so it reloads the config —
`docker restart core-platform-gateway`.

**Latent note.** The gateway still routes only a subset of services. Besides
`search` (now added), these remain **unrouted** and will hit the same wall when
a client feature needs them: `geo_discovery.v1`, `moderation.v1`, `audit.v1`
(likely internal-only), and `realtime.v1` (served over the WebSocket gateway on
`:8443`, not Envoy — expected). Add routes as features require them.

---

## 9. No seeded notifications

**Symptom.** `notification.v1.ListNotifications` returns `{}` for the seeded
user (alice) — the notification store is empty because no seeded activity
(reactions/comments/mentions on her posts) has been produced.

```bash
grpcurl -plaintext -d '{"profileId":"019f39be-6b86-7022-808b-bae992a25908","limit":10}' \
  localhost:50055 notification.v1.NotificationService/ListNotifications   # -> {}
```

**Client impact.** The Activity tab is correct but empty against the fleet.
The client is verified against `MockNotificationService` (a few reaction/
comment/mention rows over the shared dataset), which also keeps offline mode
useful. `notification.v1` **is** routed through Envoy (unlike search was), so
no gateway change was needed.

**Suggested fix.** Seed a handful of notifications for the demo user (or have
another seeded profile react to/comment on alice's posts so the projector
emits them).

---

## 10. No seeded conversations

**Symptom.** `chat.v1.ListSubscriptions` returns `{}` for the seeded user —
there are no seeded conversations, so the Messages list is empty against the
fleet.

```bash
grpcurl -plaintext -d '{"subscriberId":"019f39be-6b86-7022-808b-bae992a25908","limit":20}' \
  localhost:50051 chat.v1.ChatService/ListSubscriptions   # -> {}
```

**Client impact.** The Messages list + thread are correct but empty against
the fleet. Verified against `MockChatService` (two DMs with a short history),
which also keeps offline mode useful. `chat.v1` **is** routed through Envoy.
Live delivery (`streamConversation`) is not wired — blocked by §1.

**Suggested fix.** Seed a couple of conversations with messages for the demo
user.

---

## 11. `moderation.v1` is unrouted and its upstream port is unknown

**Symptom.** The profile overflow menu's **Report User** calls
`moderation.v1.ModerationService/OpenCase`. The Envoy gateway had no route for
`moderation.v1` (it was already named as latent in §8's closing note), so the
call 404s against the local fleet.

**What was done here.** A route + cluster were added to `dev/envoy/envoy.yaml`,
mirroring the `search` fix from §8. **The upstream address is a placeholder and
has not been verified**: no `moderation-server` port is documented anywhere in
this repo, and the fleet's assignments are not contiguous (50051-50070 with
several unused values), so `50054` is a guess, not a finding. The route will not
work until someone confirms the real port against the fleet's compose file.

```bash
# Confirm the port, then update the cluster in dev/envoy/envoy.yaml:
docker ps --format '{{.Names}}\t{{.Ports}}' | grep -i moderation
grpcurl -plaintext localhost:<port> list   # expect moderation.v1.ModerationService
docker restart core-platform-gateway       # reload the gateway config
```

**Client impact.** Report is fully implemented and verified against
`MockModerationService` (which answers `OpenCase` with a deterministic case id
and the contract's idempotent-reopen semantics). Against the fleet a report
surfaces an honest "Couldn't send this report" until the route resolves —
`ProfileViewModel.report` reports failures rather than pretending to succeed.

**Note on scope.** Only `OpenCase` is mocked. The rest of `moderation.v1` is a
moderator console (`listQueue`, `assignCase`, `decideCase`, appeals) with no
client in this app.

---

## 12. No account-level block, and aliases must be enumerated client-side

**Symptom.** The profile overflow menu offers "Block Account & All Profiles".
`social_graph.v1.Block` takes a **profile** id and nothing else — there is no
`BlockAccount` RPC and no account-scoped flag — so the client implements the
scope as a fan-out: resolve `ProfileView.account_id`, call
`ListProfilesByAccount` for the aliases, then issue one `Block` per profile.

**Two consequences the client cannot fix.**

1. **It is a snapshot, not a rule.** A profile created on that account *after*
   the block is not covered. For a safety feature this is the important one: a
   blocked user can reach the viewer again simply by making a new profile. A
   server-side account block would hold.
2. **It is not transactional.** Partial failure blocks some aliases and not
   others. `ProfileRepository.blockAccount` therefore returns the ids it
   actually blocked and the UI reports that count ("Blocked @ada and 2 more")
   rather than claiming the whole account.

**Open question for the backend — `ListProfilesByAccount` on someone else's
account.** The client now calls it with a *stranger's* account id, which
enumerates that person's alternate identities. That is privacy-sensitive and
may not be what the contract intends to expose to an arbitrary viewer. The
mock answers it (so the flow is verifiable); the fleet may refuse, and if it
does, the client degrades correctly — `accountSiblings` falls back to blocking
just the profile in hand. **If the fleet currently answers this for any
caller, that is worth a look on its own merits, independent of this feature.**

**Suggested fix.** Add `social_graph.v1.BlockAccount(actor_id, target_account_id)`
(or an `account_scope` flag on `BlockRequest`) and enforce it server-side on
profile creation. Then the client drops the fan-out entirely and the alias
enumeration goes away with it.

---

## Resolved

- **`ProfileService.ListProfilesByAccount` ScyllaDB CQL type bug** (`limit`
  bound as `i64`, schema expects `Int`) — returned `Internal` and blocked the
  feed's viewer-profile resolution. **Fixed** by the backend; verified working,
  and the client's temporary handle fallback was removed.
