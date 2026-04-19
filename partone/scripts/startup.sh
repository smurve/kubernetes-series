#!/usr/bin/env bash
# Idempotent bootstrap for the "partone" GKE demo:
#   - enables required GCP APIs
#   - creates the GKE cluster if it does not already exist
#   - configures kubectl to talk to it
#   - ensures a cluster-admin binding for the current gcloud user
#   - builds and pushes the container image
#
# Safe to re-run. Does not deploy workloads -- run ./deploy.sh for that.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_CONTEXT="${SCRIPT_DIR}/.."

GCLOUD_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
[[ -n "${GCLOUD_PROJECT}" ]] || { echo "ERROR: no active gcloud project. Run 'gcloud config set project <id>'." >&2; exit 1; }

INSTANCE_ZONE=us-central1-a
PROJECT_NAME=partone
CLUSTER_NAME="${PROJECT_NAME}-cluster"
CONTAINER_NAME="${PROJECT_NAME}-container"
IMAGE="gcr.io/${GCLOUD_PROJECT}/${CONTAINER_NAME}"

echo ">> project:   ${GCLOUD_PROJECT}"
echo ">> zone:      ${INSTANCE_ZONE}"
echo ">> cluster:   ${CLUSTER_NAME}"
echo ">> image:     ${IMAGE}"

echo ">> enabling services"
gcloud services enable \
  compute.googleapis.com \
  container.googleapis.com \
  cloudbuild.googleapis.com

echo ">> ensuring cluster exists"
if gcloud container clusters describe "${CLUSTER_NAME}" --zone "${INSTANCE_ZONE}" >/dev/null 2>&1; then
  echo "   cluster ${CLUSTER_NAME} already present, skipping create"
else
  gcloud container clusters create "${CLUSTER_NAME}" \
    --zone "${INSTANCE_ZONE}" \
    --preemptible \
    --num-nodes 1 \
    --scopes cloud-platform
fi

echo ">> fetching kubectl credentials"
gcloud container clusters get-credentials "${CLUSTER_NAME}" --zone "${INSTANCE_ZONE}"
kubectl cluster-info

echo ">> ensuring cluster-admin binding for current user"
ACCOUNT="$(gcloud config get-value account 2>/dev/null)"
kubectl create clusterrolebinding cluster-admin-binding \
  --clusterrole=cluster-admin \
  --user="${ACCOUNT}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ">> building and pushing ${IMAGE}"
gcloud builds submit -t "${IMAGE}" "${BUILD_CONTEXT}"

echo ">> startup complete. Next: ${SCRIPT_DIR}/deploy.sh"
