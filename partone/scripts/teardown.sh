#!/usr/bin/env bash
# Idempotent teardown. Deletes the cluster and the container image if they
# exist. Safe to re-run or to run when the environment is already clean.

# Note: deliberately no 'set -e' -- we want to continue past "not found" cases.
set -uo pipefail

GCLOUD_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
[[ -n "${GCLOUD_PROJECT}" ]] || { echo "ERROR: no active gcloud project." >&2; exit 1; }

INSTANCE_ZONE=us-central1-a
PROJECT_NAME=partone
CLUSTER_NAME="${PROJECT_NAME}-cluster"
CONTAINER_NAME="${PROJECT_NAME}-container"
IMAGE="gcr.io/${GCLOUD_PROJECT}/${CONTAINER_NAME}"

echo ">> project:  ${GCLOUD_PROJECT}"
echo ">> cluster:  ${CLUSTER_NAME} (${INSTANCE_ZONE})"
echo ">> image:    ${IMAGE}"

if gcloud container clusters describe "${CLUSTER_NAME}" --zone "${INSTANCE_ZONE}" >/dev/null 2>&1; then
  echo ">> deleting cluster ${CLUSTER_NAME}"
  gcloud container clusters delete "${CLUSTER_NAME}" --zone "${INSTANCE_ZONE}" --quiet
else
  echo ">> cluster ${CLUSTER_NAME} not found, skipping"
fi

if gcloud container images describe "${IMAGE}" >/dev/null 2>&1; then
  echo ">> deleting image ${IMAGE}"
  gcloud container images delete "${IMAGE}" --force-delete-tags --quiet
else
  echo ">> image ${IMAGE} not found, skipping"
fi

echo ">> teardown complete."
