#!/usr/bin/env bash
# Deploys the HTTPS Ingress stack to the currently-configured kube-context.
# Assumes:
#   - gcloud active project has the partone-container image at gcr.io/<project>/partone-container:latest
#   - provision.sh has already reserved the global static IP named 'kitt-ingress'
#   - DNS for kitt.smurve.ch points at that IP
#
# Apply order matters for GKE Ingress: the Service, ManagedCertificate and
# FrontendConfig must exist before the Ingress references them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../k8s"

GCLOUD_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
[[ -n "${GCLOUD_PROJECT}" ]] || { echo "ERROR: no active gcloud project." >&2; exit 1; }

CTX="$(kubectl config current-context)"
echo ">> kube-context:   ${CTX}"
echo ">> gcloud project: ${GCLOUD_PROJECT}"

echo ">> applying Deployment (image substituted with ${GCLOUD_PROJECT})"
sed "s/PROJECT_NAME/${GCLOUD_PROJECT}/g" "${K8S_DIR}/deployment.yaml" | kubectl apply -f -

echo ">> applying Service (ClusterIP + NEG annotation)"
kubectl apply -f "${K8S_DIR}/service.yaml"

echo ">> applying ManagedCertificate and FrontendConfig"
kubectl apply -f "${K8S_DIR}/managed-certificate.yaml"
kubectl apply -f "${K8S_DIR}/frontend-config.yaml"

echo ">> applying Ingress"
kubectl apply -f "${K8S_DIR}/ingress.yaml"

echo ">> waiting for Deployment rollout"
kubectl rollout status deploy/endpoints --timeout=5m

echo ">> done. Run ./status.sh to check Ingress and certificate provisioning."
