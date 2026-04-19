#!/usr/bin/env bash
# Poll a LoadBalancer Service for its assigned external IP.
# Usage: ./check-endpoint.sh [service-name]   (default: endpoints)

set -euo pipefail

SVC="${1:-endpoints}"
MAX_WAIT_SEC=600
SLEEP_SEC=10
elapsed=0

echo ">> waiting for LoadBalancer IP on service/${SVC} (timeout ${MAX_WAIT_SEC}s)"
while :; do
  ip="$(kubectl get svc "${SVC}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [[ -n "${ip}" ]]; then
    echo "End point ready: ${ip}"
    exit 0
  fi
  if (( elapsed >= MAX_WAIT_SEC )); then
    echo "ERROR: timed out after ${MAX_WAIT_SEC}s waiting for ${SVC} external IP" >&2
    exit 1
  fi
  printf '.'
  sleep "${SLEEP_SEC}"
  elapsed=$(( elapsed + SLEEP_SEC ))
done
