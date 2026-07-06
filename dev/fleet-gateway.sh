#!/usr/bin/env bash
# Local gRPC-Web gateway (Envoy) fronting the core-platform fleet for the iOS
# client. Exposes http://localhost:8080 (gRPC-Web over HTTP/1.1); admin on :9901.
#
#   dev/fleet-gateway.sh up       start the gateway
#   dev/fleet-gateway.sh down     stop and remove it
#   dev/fleet-gateway.sh status   show cluster health
#   dev/fleet-gateway.sh logs     tail Envoy logs
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=core-platform-gateway
NETWORK=core-platform-fleet_default
IMAGE=envoyproxy/envoy:v1.31-latest
CONFIG="$(pwd)/dev/envoy/envoy.yaml"

case "${1:-up}" in
  up)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" \
      --network "$NETWORK" \
      -p 8080:8080 -p 9901:9901 \
      -v "$CONFIG:/etc/envoy/envoy.yaml:ro" \
      "$IMAGE" -c /etc/envoy/envoy.yaml >/dev/null
    echo "gateway up → http://localhost:8080 (admin http://localhost:9901)"
    ;;
  down)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    echo "gateway down"
    ;;
  status)
    curl -s http://localhost:9901/clusters 2>/dev/null | grep -E "::health_flags::|::rq_" | head -40 || echo "gateway not reachable"
    ;;
  logs)
    docker logs -f "$NAME"
    ;;
  *)
    echo "usage: $0 {up|down|status|logs}" >&2
    exit 1
    ;;
esac
