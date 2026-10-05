#!/usr/bin/env bash
# Local gRPC-Web gateway (Envoy) fronting the core-platform fleet for the iOS
# client. Exposes http://localhost:8080 (gRPC-Web over HTTP/1.1); admin on :9901.
#
#   dev/fleet-gateway.sh up         start the gateway on the services' MESH ports
#   dev/fleet-gateway.sh up --edge  start it on their CLIENT EDGE ports (:9443),
#                                   token-checked as in staging — needs the fleet
#                                   started with local-dev/docker-compose.edge.yml
#   dev/fleet-gateway.sh down       stop and remove it
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
    MODE=mesh
    if [[ "${2:-}" == "--edge" ]]; then
      # Edge mode (backend #678): inside the fleet network every client-facing
      # server also listens on :9443, plaintext h2c like the mesh, and checks
      # the bearer against auth's JWKS and the service's EDGE_POLICY. Same
      # routes, every upstream pointed at :9443. The gateway forwards the
      # app's Authorization header untouched.
      MODE=edge
      EDGE_CONFIG="$(mktemp -t envoy-edge).yaml"
      sed -E 's/port_value: 5[0-9]{4}/port_value: 9443/' "$CONFIG" > "$EDGE_CONFIG"
      CONFIG="$EDGE_CONFIG"
    fi
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" \
      --network "$NETWORK" \
      -p 8080:8080 -p 9901:9901 \
      -v "$CONFIG:/etc/envoy/envoy.yaml:ro" \
      "$IMAGE" -c /etc/envoy/envoy.yaml >/dev/null
    echo "gateway up ($MODE) → http://localhost:8080 (admin http://localhost:9901)"
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
