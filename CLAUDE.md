# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Nature

This is a tutorial/sample repository accompanying Jon Campos's Medium blog series on Kubernetes
(origin: `jonbcampos/kubernetes-series`). Each top-level directory (`partone`, `autoscaling`,
`batch-job`, `communication`, `cron`, `daemon`, `deployment-manager`, `external-communication`,
`helm`, `secrets`) is a **self-contained example** for one post in the series. They do not import
from one another and do not share a build.

The example workloads are trivial Node.js Express apps (`server.js` / `app.js`, port 8080). The
learning material is in the Kubernetes manifests under `*/k8s/` and the orchestration scripts
under `*/scripts/`, not in the app code.

## Common Commands

All commands are run from inside a topic's `scripts/` directory (the scripts use relative
`../k8s/...` paths and will silently target the wrong files if invoked from elsewhere).

Typical lifecycle for a topic (using `partone` as the template; others follow the same pattern
with additional helper scripts):

```bash
cd <topic>/scripts
sh startup.sh         # enable GCP APIs, create GKE cluster, build image via Cloud Build
sh deploy.sh          # kubectl apply of ../k8s/*.yaml
sh check-endpoint.sh <service-name>   # polls LoadBalancer for external IP
sh teardown.sh        # delete cluster and GCR image
```

There is **no** lint, unit-test, or CI configuration in this repo. `package.json` defines only
`npm start` (`node server.js`) for local runs outside the cluster.

## Environment Requirements (implicit)

The scripts assume an authenticated `gcloud` CLI with a default project set
(`gcloud config get-value project` is used verbatim), plus `kubectl`. The cluster is always
created in `us-central1-a` as a single-node **preemptible** GKE cluster, and images are pushed
to `gcr.io/<project>/<topic>-container`. There is no parameterization — edit the scripts if a
different region/project is needed.

## Cross-Cutting Gotchas

- `deploy.sh` uses `sed -i "s/PROJECT_NAME/.../g" ../k8s/deployment.yaml` (GNU syntax). On
  macOS BSD `sed` this fails unless you change it to `sed -i '' ...`. It also **mutates the
  checked-in YAML in place**, so re-running `deploy.sh` after a project change, or committing
  after a deploy, will leak the GCP project id into git. Revert `k8s/deployment.yaml` before
  committing.
- `partone/k8s/deployment.yaml` uses `apiVersion: apps/v1beta1`, which was removed in
  Kubernetes 1.16+. Expect it to fail on any modern GKE cluster and require migration to
  `apps/v1` (with a matching `spec.selector`).
- `node_modules/` is checked in under `partone/` (and possibly other topics). `.gitignore`
  lists `node_modules/` but git is already tracking these files; deletions must be staged
  explicitly if cleanup is wanted.
- Scripts have no `set -e`; failures partway through (e.g. `gcloud builds submit` at the end
  of `startup.sh`) do not abort earlier side-effects like cluster creation. Always check
  `teardown.sh` ran cleanly when abandoning an experiment — leftover GKE clusters cost money.

## User's Global Safety Rule

Per the user's global instructions, writes are restricted to `/Users/wgiersche/workspace`,
`/Users/wgiersche/obsidian`, and `/Users/wgiersche/.claude/skills`. This repo lives under
`workspace`, so edits here are allowed; do not write outside it.
