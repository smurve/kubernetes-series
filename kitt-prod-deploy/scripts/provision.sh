#!/usr/bin/env bash
# Reserves the global static IP used by the HTTPS Ingress. Idempotent.
# Prints the IP value on stdout so it can be captured: `IP=$(./provision.sh)`.

set -euo pipefail

IP_NAME="${IP_NAME:-kitt-ingress}"

if gcloud compute addresses describe "${IP_NAME}" --global >/dev/null 2>&1; then
  :  # already exists
else
  gcloud compute addresses create "${IP_NAME}" --global >/dev/null
fi

gcloud compute addresses describe "${IP_NAME}" --global --format='value(address)'
