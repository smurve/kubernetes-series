#!/usr/bin/env bash
# Quick status snapshot: pods, service, ingress address, and managed-cert state.

set -euo pipefail

echo "--- pods ---"
kubectl get pods -l app=endpoints -o wide

echo
echo "--- service endpoints (Pod IPs backing the Service) ---"
kubectl get endpoints endpoints

echo
echo "--- ingress ---"
kubectl get ingress kitt-ingress -o wide

echo
echo "--- managed certificate ---"
# Domain-level status: empty = not started, Provisioning / Active / Failed / FailedNotVisible
kubectl get managedcertificate kitt-cert \
  -o custom-columns='NAME:.metadata.name,OVERALL:.status.certificateStatus,DOMAIN:.status.domainStatus[*].domain,STATE:.status.domainStatus[*].status'

echo
echo "--- DNS (as seen by 8.8.8.8) ---"
dig +short @8.8.8.8 kitt.smurve.ch A
