# 0003. Protobuf contracts pinned, Connect to the BFF, a hand-rolled realtime client

Date: 2026-07-06 · Status: Accepted

## Context
The backend is a set of gRPC services behind a backend-for-frontend (BFF). Its API is a protobuf module shared with the server. URLSession cannot speak raw gRPC over cleartext HTTP/2, which the local fleet serves.

## Decision
- **The contracts are generated** into `Kit/CoreContracts` by `Scripts/generate-contracts.sh`, committed, and **pinned to a commit** by `.contracts-pin`.
- **The client speaks Connect to the BFF** with connect-swift. Against the local fleet, it speaks gRPC-Web to an Envoy gateway (`dev/envoy/`) that forwards to the services.
- **Realtime is a hand-rolled WebSocket client** (`CoreRealtime`) carrying the realtime contract's frames, not a gRPC library.
- **Development runs on an in-process mock backend first**, deterministic, then against the fleet ([0004](0004-mock-backend-in-debug-and-demo-only.md)).

## Consequences
- A contract change is an explicit pin bump. It can break the mock backend's stubs, which must be updated in the same change.
- Features see repositories and services, never the generated clients directly.
