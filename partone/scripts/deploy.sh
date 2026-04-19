#!/usr/bin/env bash
# Render the deployment manifest with the current GCP project and apply
# both deployment and service. Waits for the rollout to become ready.
#
# Assumes ./startup.sh has already run successfully.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../k8s"

GCLOUD_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
[[ -n "${GCLOUD_PROJECT}" ]] || { echo "ERROR: no active gcloud project." >&2; exit 1; }

echo ">> applying manifests (project=${GCLOUD_PROJECT})"
# Pipe through sed instead of mutating the tracked file (keeps git clean and
# works on BSD sed where 'sed -i' needs a backup extension argument).
sed "s/PROJECT_NAME/${GCLOUD_PROJECT}/g" "${K8S_DIR}/deployment.yaml" | kubectl apply -f -
kubectl apply -f "${K8S_DIR}/service.yaml"

echo ">> waiting for rollout"
kubectl rollout status deploy/endpoints --timeout=5m

echo ">> deploy complete. Next: ${SCRIPT_DIR}/check-endpoint.sh endpoints"
