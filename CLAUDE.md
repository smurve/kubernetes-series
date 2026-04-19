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

Typical lifecycle for a topic:

```bash
sh <topic>/scripts/startup.sh         # enable GCP APIs, create GKE cluster, build image via Cloud Build
sh <topic>/scripts/deploy.sh          # kubectl apply of k8s/*.yaml, waits for rollout
sh <topic>/scripts/check-endpoint.sh <service-name>   # polls LoadBalancer for external IP
sh <topic>/scripts/teardown.sh        # delete cluster and GCR image
```

Invocation rules differ by topic:

- **`partone`** (rewritten): scripts are CWD-independent, idempotent, use `set -euo pipefail`,
  and tolerate re-runs. `startup.sh` skips cluster creation if it already exists; `teardown.sh`
  skips deletes for resources that don't exist. You can run them from anywhere.
- **All other topics** (`autoscaling`, `batch-job`, `communication`, `cron`, `daemon`,
  `deployment-manager`, `external-communication`, `helm`, `secrets`): scripts use relative
  `../k8s/...` paths and **must be invoked from inside the topic's `scripts/` directory**, or
  they will silently target the wrong files.

There is **no** lint, unit-test, or CI configuration in this repo. `package.json` defines only
`npm start` (`node server.js`) for local runs outside the cluster.

## Environment Requirements (implicit)

The scripts assume an authenticated `gcloud` CLI with a default project set
(`gcloud config get-value project` is used verbatim), plus `kubectl`. The cluster is always
created in `us-central1-a` as a single-node **preemptible** GKE cluster, and images are pushed
to `gcr.io/<project>/<topic>-container`. There is no parameterization — edit the scripts if a
different region/project is needed.

## Cross-Cutting Gotchas (applies to non-`partone` topics)

`partone` has been hardened against these; the rest of the topics still exhibit them:

- `deploy.sh` uses `sed -i "s/PROJECT_NAME/.../g" ../k8s/deployment.yaml` (GNU syntax). On
  macOS BSD `sed` this fails unless you change it to `sed -i '' ...`. It also **mutates the
  checked-in YAML in place**, so re-running `deploy.sh` after a project change, or committing
  after a deploy, will leak the GCP project id into git. Revert `k8s/deployment.yaml` before
  committing. Robust fix: pipe `sed "..." file | kubectl apply -f -` instead.
- `k8s/deployment.yaml` in every non-`partone` topic uses `apiVersion: apps/v1beta1`, which
  was removed in Kubernetes 1.16+. `kubectl apply` will reject with `no matches for kind
  "Deployment" in version "apps/v1beta1"`. Migrate to `apps/v1` (the existing
  `spec.selector.matchLabels` is already compatible).
- Scripts have no `set -e`; failures partway through (e.g. `gcloud builds submit` at the end
  of `startup.sh`) do not abort earlier side-effects like cluster creation. Always check
  `teardown.sh` ran cleanly when abandoning an experiment — leftover GKE clusters cost money.
- `node_modules/` is checked in under several topics (notably `partone`). `.gitignore` lists
  `node_modules/` but git is already tracking those files; deletions must be staged
  explicitly if cleanup is wanted.

## Probe Endpoints (lesson from `partone`)

The `deployment.yaml` in every topic defines readiness/liveness probes on `/readiness` and
`/healthcheck`. The Day-One `server.js` in `partone` originally only served `/`, which caused
`CrashLoopBackOff` / "does not have minimum availability" on deploy. The fix is to add handlers
in the app:

```js
app.get('/healthcheck', (req, res) => res.sendStatus(200));
app.get('/readiness',   (req, res) => res.sendStatus(200));
```

`partone/server.js` has them. Before deploying any other topic, check that its app actually
serves the probe paths its manifest references — if not, expect the same failure mode.

## GKE Client Requirement

Modern `kubectl` against GKE needs the `gke-gcloud-auth-plugin` binary on `PATH`. If `kubectl`
reports "executable gke-gcloud-auth-plugin not found", install via
`gcloud components install gke-gcloud-auth-plugin`.

## User's Global Safety Rule

Per the user's global instructions, writes are restricted to `/Users/wgiersche/workspace`,
`/Users/wgiersche/obsidian`, and `/Users/wgiersche/.claude/skills`. This repo lives under
`workspace`, so edits here are allowed; do not write outside it.
