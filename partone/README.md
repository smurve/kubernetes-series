# Part One — Your First Kubernetes Deployment on GKE

A guided, self-contained tutorial that takes you from an empty Google Cloud project
to a publicly reachable, load-balanced, self-healing Node.js service running on a
Kubernetes cluster in Google Kubernetes Engine (GKE).

The goal is not just to make the demo work, but to explain **why** each piece exists,
so the rest of the series builds on solid ground.

---

## Table of Contents

1. [What you will build](#1-what-you-will-build)
2. [Prerequisites](#2-prerequisites)
3. [Background: Google Cloud fundamentals](#3-background-google-cloud-fundamentals)
4. [Background: Kubernetes fundamentals](#4-background-kubernetes-fundamentals)
5. [Walkthrough of the source](#5-walkthrough-of-the-source)
   - [The app: `server.js`](#51-the-app-serverjs)
   - [The image: `Dockerfile`](#52-the-image-dockerfile)
   - [The Deployment: `k8s/deployment.yaml`](#53-the-deployment-k8sdeploymentyaml)
   - [The Service: `k8s/service.yaml`](#54-the-service-k8sserviceyaml)
6. [Walkthrough of the scripts](#6-walkthrough-of-the-scripts)
7. [Running it end-to-end](#7-running-it-end-to-end)
8. [Verification: how to know it really works](#8-verification-how-to-know-it-really-works)
9. [Teardown](#9-teardown)
10. [Troubleshooting & the bugs this tutorial teaches you to recognise](#10-troubleshooting--the-bugs-this-tutorial-teaches-you-to-recognise)
11. [What's next](#11-whats-next)
12. [Reference: every field in the Deployment manifest, explained](#12-reference-every-field-in-the-deployment-manifest-explained)

---

## 1. What you will build

A trivial HTTP service, `server.js`, that answers `Hello Docker` on `GET /` and
returns `200 OK` on the probe paths `GET /readiness` and `GET /healthcheck`. You
will:

- package it as a container image with **Docker** (a `Dockerfile` that starts from
  `node:16`),
- push the image to **Google Container Registry** via **Google Cloud Build** (no
  local Docker daemon required),
- create a small **Google Kubernetes Engine** cluster,
- deploy the image as three Pods behind a `Deployment`,
- expose those Pods publicly via a `LoadBalancer` `Service`,
- watch Kubernetes heal the workload when probes fail or Pods die.

End state: an external IP you can `curl` from anywhere, serving traffic balanced
across three Pods, with automatic restart on liveness failures and automatic
traffic-gating until readiness passes.

```
    internet
       |
       v
 +---------------------+
 |  LoadBalancer       |   <- service/endpoints, external IP
 |  :80 -> :8080       |
 +---------+-----------+
           |
   +-------+-------+-------+
   |               |       |
   v               v       v
 Pod A           Pod B   Pod C       <- deployment/endpoints, 3 replicas
 node:16         ...     ...
 server.js:8080
```

## 2. Prerequisites

| Tool                       | Why you need it                                     |
| -------------------------- | --------------------------------------------------- |
| `gcloud` (Google Cloud SDK) | Talk to GCP: enable APIs, create clusters, submit builds |
| `kubectl`                  | Talk to the Kubernetes API server                    |
| `gke-gcloud-auth-plugin`   | Credential plugin that `kubectl` uses to auth to GKE |
| A GCP project with billing | Everything here costs something (see cost notes)    |
| `bash` 4+                  | The scripts use `set -euo pipefail` and arrays       |

Install the auth plugin once:

```bash
gcloud components install gke-gcloud-auth-plugin
```

Authenticate and pick a project:

```bash
gcloud auth login
gcloud config set project <your-project-id>
```

The scripts read the *active* project via `gcloud config get-value project`, so as
long as the above is set you never need to pass it explicitly.

### Cost awareness

This demo creates a single-node, `--preemptible` GKE cluster. That's the cheapest
GKE footprint you can run, but it is **not free**. The `LoadBalancer` Service
provisions a forwarding rule + static IP that is billed hourly. Tear everything
down (section 9) when you're done.

## 3. Background: Google Cloud fundamentals

### 3.1 Projects

A **project** is the top-level container for GCP resources, quotas, billing and
IAM. Every API call is scoped to a project. In the scripts, this is the
`GCLOUD_PROJECT` variable, read at runtime from your active gcloud configuration:

```bash
GCLOUD_PROJECT="$(gcloud config get-value project)"
```

### 3.2 APIs must be enabled per project

Most GCP services are gated behind an **API** that you explicitly enable on a
project. `startup.sh` enables the three we need:

| API                          | What it powers                             |
| ---------------------------- | ------------------------------------------ |
| `compute.googleapis.com`     | VMs, networks, load balancers              |
| `container.googleapis.com`   | GKE clusters                               |
| `cloudbuild.googleapis.com`  | Building container images remotely         |

Enabling is idempotent — safe to run every time.

### 3.3 GKE (Google Kubernetes Engine)

GKE is a managed Kubernetes. Google operates the **control plane** (the API
server, scheduler, controller manager, `etcd`) for you; you only see and pay for
the **node pool** — the VMs where your Pods actually run.

Key flags we use when creating the cluster:

| Flag                      | Meaning                                                                 |
| ------------------------- | ----------------------------------------------------------------------- |
| `--zone us-central1-a`    | Zonal cluster (single zone, cheaper, no HA control plane)               |
| `--preemptible`           | Nodes can be reclaimed by Google with ~30s notice; ~80% cheaper         |
| `--num-nodes 1`           | One worker VM. Pods fit because the demo uses no resource requests      |
| `--scopes cloud-platform` | Grants the node service account full scope for trying out other APIs    |

Preemptible nodes are fine for learning. For production you'd use regular nodes,
a regional cluster (`--region` not `--zone`), multiple node pools, and workload
identity rather than `cloud-platform` scopes.

### 3.4 Container Registry vs Artifact Registry

This tutorial pushes to **Google Container Registry** (`gcr.io/<project>/…`).
That's the legacy registry; the successor is **Artifact Registry**
(`<region>-docker.pkg.dev/…`). The Medium series predates the migration, and
`gcr.io` paths still resolve (they are transparently served by Artifact Registry
under the hood), so the demo keeps working. For a greenfield project prefer
Artifact Registry.

### 3.5 Cloud Build

`gcloud builds submit -t <image> <context>` uploads your build context (the
contents of the `partone/` directory, minus anything `.gcloudignore`'d) to Cloud
Build, which runs Docker for you on a remote worker and pushes the resulting
image. You never need a local Docker daemon. This is also why the cluster's
nodes can pull the image immediately afterwards: the registry is already in GCP.

## 4. Background: Kubernetes fundamentals

You don't need to read a book before doing this tutorial, but you will see every
concept below at least once, so it's worth having a one-line mental model of
each.

### 4.1 Cluster, control plane, nodes

A **cluster** is one control plane + one or more nodes. The control plane runs
the API server (the only thing `kubectl` talks to), the scheduler (decides which
node a Pod lands on) and the controller manager (runs the reconcile loops that
make Deployments, Services, etc. actually do what they say). **Nodes** run
Pods. In GKE you don't see the control plane, you just see the nodes as VMs.

### 4.2 Pod

The smallest deployable unit. A Pod is one or more containers that share a
network namespace (same IP, same port space) and usually one filesystem volume.
In this demo each Pod has exactly one container: the Node app.

### 4.3 ReplicaSet

A controller that keeps *N* Pods running that match a **label selector**. You
almost never write a ReplicaSet by hand.

### 4.4 Deployment

A higher-level controller that owns a ReplicaSet and gives you rolling updates
and rollback. When you `kubectl apply` a new image tag, the Deployment creates a
new ReplicaSet, scales it up while scaling the old one down, and only declares
success when the new Pods pass their readiness probe.

In this demo: `kind: Deployment`, `replicas: 3`, selector `tier: endpoints`.

### 4.5 Service

A stable network identity for a set of Pods. Pods come and go (and get new IPs);
a Service keeps a steady cluster-internal IP and DNS name. Its `selector` picks
the Pods that back it, **by labels**, not by Pod name or Deployment reference.
This decoupling is a core Kubernetes idea — see the next section.

The `type: LoadBalancer` variant additionally provisions an external cloud load
balancer (on GKE: a Google Cloud Network Load Balancer) and fills in an external
IP on the Service's `status`. That's what `check-endpoint.sh` polls for.

### 4.6 Labels and selectors — the glue

Labels are arbitrary key/value tags on any object. Selectors match objects by
labels. The Deployment's Pod template stamps every Pod with:

```yaml
labels:
  app: kubernetes-series
  tier: endpoints
```

The Deployment's own `spec.selector.matchLabels: { tier: endpoints }` tells it
which Pods belong to it. The Service's `spec.selector: { app: kubernetes-series }`
tells it which Pods to route traffic to. Both selectors match the same Pods,
but they are *independent*: you could redeploy with a completely different
Deployment manifest and, as long as the new Pods still carry
`app: kubernetes-series`, the Service would keep working.

### 4.7 Probes: readiness vs liveness

| Probe        | What failure means                                          |
| ------------ | ----------------------------------------------------------- |
| `readinessProbe` | "This Pod is not ready for traffic right now."              |
| `livenessProbe`  | "This Pod is broken; kill it and let the controller restart it." |

A Pod failing readiness is *removed from the Service's endpoint list* but is
**not** killed. A Pod failing liveness is *killed by the kubelet*, and the
Deployment then creates a replacement.

Both probes are defined as HTTP GET requests against paths on the container's
own port. The app **must** actually serve those paths. If it doesn't, the
kubelet sees 404 on every probe attempt, which counts as failure. This demo
serves `/readiness` and `/healthcheck` explicitly (see `server.js`). Forgetting
to add them is the single most common "does not have minimum availability"
root cause on GKE.

### 4.8 Namespace

A cluster-wide partition. Everything here lives in the default namespace, which
is fine for a demo. Real clusters usually split workloads across namespaces for
RBAC and quota reasons.

## 5. Walkthrough of the source

### 5.1 The app: `server.js`

```js
import express from "express";

const PORT = 8080;
const HOST = '0.0.0.0';

const app = express();
app.get('/', (req, res) => { res.send("Hello Docker"); });

app.get('/healthcheck', (req, res) => res.sendStatus(200));
app.get('/readiness',   (req, res) => res.sendStatus(200));

app.listen(PORT, HOST, () => {
    console.log(`Running on http://${HOST}:${PORT}`);
});
```

Notes:

- Listens on `0.0.0.0`, not `127.0.0.1`. Inside a container the localhost
  interface is unreachable from outside; you must bind to all interfaces.
- Port **8080**, not 80. Running as non-root would make `:80` fail anyway;
  convention is to use an unprivileged port and let the Service map 80 → 8080.
- The two probe handlers return `200 OK` with no body. That is deliberately the
  simplest thing that can work: a real service would wire liveness to internal
  state (DB connection, worker queue healthy, etc.) and readiness to "I have
  warmed my caches and can accept traffic now."

### 5.2 The image: `Dockerfile`

```dockerfile
FROM node:16
WORKDIR /usr/src/app
COPY package.json ./
RUN npm install
COPY . .
EXPOSE 8080
CMD [ "node", "server.js" ]
```

Why the two-stage `COPY`? Because `RUN npm install` is expensive and only
depends on `package.json`. By copying `package.json` first and running
`npm install` before copying the rest of the source, Docker can reuse the
cached install layer on every build where dependencies haven't changed.

`EXPOSE 8080` is documentation, not a firewall rule; it tells tooling (and
humans) which port the container intends to serve on.

### 5.3 The Deployment: `k8s/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: endpoints
  labels: { app: kubernetes-series, tier: endpoints }
spec:
  replicas: 3
  selector:
    matchLabels: { tier: endpoints }
  template:
    metadata:
      labels: { app: kubernetes-series, tier: endpoints }
    spec:
      containers:
        - name: partone-container
          image: gcr.io/PROJECT_NAME/partone-container:latest
          ports:
            - containerPort: 8080
          readinessProbe:  { httpGet: { port: 8080, path: /readiness,   scheme: HTTP }, initialDelaySeconds: 3, periodSeconds: 3, successThreshold: 1, failureThreshold: 1, timeoutSeconds: 1 }
          livenessProbe:   { httpGet: { port: 8080, path: /healthcheck, scheme: HTTP }, initialDelaySeconds: 3, periodSeconds: 3, successThreshold: 1, failureThreshold: 1, timeoutSeconds: 1 }
          env:
            - { name: GCLOUD_PROJECT, value: PROJECT_NAME }
            - { name: POD_ENDPOINT,   value: endpoint }
            - { name: NODE_ENV,       value: production }
```

Things worth understanding:

- **`apiVersion: apps/v1`** — the current, stable API. The upstream tutorial was
  written against `apps/v1beta1`, which Kubernetes **removed** in 1.16. Any
  modern GKE cluster rejects it outright.
- **The `PROJECT_NAME` placeholder** is rewritten at apply time by `deploy.sh`
  to your actual GCP project id. That way the manifest stays project-independent
  in git.
- **`containerPort: 8080`** matches the port the Node app actually binds. The
  upstream tutorial had `80` here, which was harmless (`containerPort` is
  informational) but misleading.
- **Probes’ `periodSeconds: 3` / `failureThreshold: 1`** — a single bad response
  takes a Pod out of service immediately and, for liveness, restarts it. That's
  aggressive, great for demonstrating the mechanic, and something you'd soften
  for production (e.g. `failureThreshold: 3`).

### 5.4 The Service: `k8s/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: endpoints
spec:
  type: LoadBalancer
  selector: { app: kubernetes-series }
  ports:
    - name: http
      port: 80
      targetPort: 8080
      protocol: TCP
```

- **`type: LoadBalancer`** — on GKE this triggers creation of a Google Cloud
  Network Load Balancer and a regional static IP.
- **`port: 80, targetPort: 8080`** — clients hit `:80` on the external IP; the
  Service forwards to `:8080` on the Pods.

The upstream tutorial also defined `port: 443 → targetPort: 8443` here. Nothing
in the container listens on 8443, so that entry was dead weight — `kubectl
apply` accepted it, the LB opened a TCP port, and every connection on 443 just
timed out. We removed it.

## 6. Walkthrough of the scripts

All scripts use `set -euo pipefail` (except `teardown.sh`, which deliberately
continues past missing resources). All scripts are **CWD-independent**: they
compute their own directory and resolve sibling paths from there, so you can
invoke them from anywhere.

### 6.1 `scripts/startup.sh`

Idempotent bootstrap. Running it twice does not recreate the cluster:

1. Read the active GCP project, abort if none.
2. Enable the three required APIs.
3. `gcloud container clusters describe` — if the cluster already exists, skip
   creation; otherwise create it.
4. `gcloud container clusters get-credentials` — writes a kube-context into
   `~/.kube/config` and points `kubectl` at the new cluster.
5. Ensure a `cluster-admin` `ClusterRoleBinding` for your gcloud identity (via
   the `kubectl create --dry-run=client -o yaml | kubectl apply -f -` pattern,
   which is the canonical way to make `kubectl create` idempotent).
6. `gcloud builds submit` — builds and pushes the image.

### 6.2 `scripts/deploy.sh`

1. Read the active GCP project.
2. Substitute `PROJECT_NAME` into the Deployment manifest **via a pipe**, not
   an in-place `sed -i`:

   ```bash
   sed "s/PROJECT_NAME/${GCLOUD_PROJECT}/g" deployment.yaml | kubectl apply -f -
   ```

   This keeps the checked-in YAML clean (nothing ever leaks your project id
   into git) and works identically on GNU sed (Linux) and BSD sed (macOS).

3. `kubectl apply -f service.yaml`.
4. `kubectl rollout status deploy/endpoints --timeout=5m` — blocks until three
   new Pods are Ready (or times out and exits non-zero).

### 6.3 `scripts/check-endpoint.sh`

Polls the Service for a `status.loadBalancer.ingress[0].ip`. LoadBalancer
provisioning can take 30–90 seconds on GKE. Bounded 10-minute timeout; returns
non-zero if it never shows up.

### 6.4 `scripts/teardown.sh`

Idempotent teardown. Each resource is gated by a `describe` first so re-runs
don't fail:

1. Delete the GKE cluster (this also releases the LoadBalancer, the forwarding
   rule and the external IP — everything billed hourly).
2. Delete the container image from `gcr.io`.

## 7. Running it end-to-end

From a clean shell:

```bash
# 1. Point gcloud at your project.
gcloud config set project <your-project-id>

# 2. Bring up the cluster and build the image (~2–4 min).
sh partone/scripts/startup.sh

# 3. Deploy and wait for rollout.
sh partone/scripts/deploy.sh

# 4. Wait for the LoadBalancer to get an external IP (~30–90 sec).
sh partone/scripts/check-endpoint.sh endpoints

# 5. Hit it.
IP=$(kubectl get svc endpoints -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl http://$IP/
# -> Hello Docker
```

## 8. Verification: how to know it really works

```bash
kubectl get deploy,pods,svc -l app=kubernetes-series
```

You should see:

- `deployment.apps/endpoints` with `READY 3/3`, `AVAILABLE 3`.
- Three Pods, each `1/1 READY`, `STATUS: Running`, `RESTARTS: 0`.
- `service/endpoints` with `TYPE LoadBalancer` and an `EXTERNAL-IP`.

Exercise the self-healing:

```bash
# Kill one Pod. The Deployment will create a replacement within seconds.
kubectl delete pod -l tier=endpoints --field-selector=status.phase=Running --limit 1
kubectl get pods -w -l tier=endpoints
```

Exercise the LoadBalancer:

```bash
for i in $(seq 1 10); do curl -s http://$IP/; echo; done
# All say "Hello Docker", but they are served by different Pods in rotation.
# If you want proof, have the app echo its hostname — trivial to add.
```

## 9. Teardown

```bash
sh partone/scripts/teardown.sh
```

Safe to run more than once. Double-check with `gcloud container clusters list`
that nothing is left — preemptible clusters still cost money until deleted.

## 10. Troubleshooting & the bugs this tutorial teaches you to recognise

These are real failure modes encountered while hardening this demo. They recur
constantly in real Kubernetes work.

### 10.1 `sed -i` fails on macOS

**Symptom:**

```
sed: 1: "../k8s/deployment.yaml": extra characters at the end of d command
```

**Cause:** GNU `sed -i` and BSD `sed -i` diverge. GNU `sed -i EXPR FILE` edits
in place; BSD `sed -i EXT EXPR FILE` requires a backup-suffix argument (use
`sed -i '' EXPR FILE` for no backup).

**Robust fix:** don't edit in place at all — pipe through:

```bash
sed "s/PROJECT_NAME/${GCLOUD_PROJECT}/g" deployment.yaml | kubectl apply -f -
```

Works on both seds, and as a bonus never dirties the file in git.

### 10.2 `no matches for kind "Deployment" in version "apps/v1beta1"`

**Cause:** Kubernetes removed `apps/v1beta1` in 1.16 (late 2019). Modern GKE is
far past that. The fix is a one-word change to `apiVersion: apps/v1`; the
existing `spec.selector.matchLabels` already satisfies `apps/v1`'s mandatory
selector field.

### 10.3 "Does not have minimum availability" / `CrashLoopBackOff`

**Symptom:** Pods keep restarting. `kubectl describe pod …` shows:

```
Readiness probe failed: HTTP probe failed with statuscode: 404
Liveness probe failed:  HTTP probe failed with statuscode: 404
Container … failed liveness probe, will be restarted
```

**Cause:** The manifest references `/readiness` and `/healthcheck`, but the app
only implements `/`. Express returns 404, readiness never passes, liveness
failures trigger restarts, and the Deployment can never reach `AVAILABLE > 0`.

**Fix:** implement the endpoints (this repo now does). The general rule:
**every probe path in your manifest must correspond to a real handler in the
app.**

### 10.4 `executable gke-gcloud-auth-plugin not found`

**Cause:** Since client-go 1.26, GKE auth is no longer built into `kubectl`.
You need the separate plugin on `PATH`.

**Fix:**

```bash
gcloud components install gke-gcloud-auth-plugin
```

### 10.5 LoadBalancer stuck on `<pending>`

**Cause:** Several possible — the `compute.googleapis.com` API not enabled,
quota exhaustion on forwarding rules or static IPs, or simply that it hasn't
finished provisioning (30–90 sec is normal).

**Diagnose:** `kubectl describe svc endpoints` shows LB events. If it's stuck
for more than a few minutes, check `gcloud compute forwarding-rules list` and
the GCP console's quota page.

## 11. What's next

The rest of this repo (`autoscaling/`, `batch-job/`, `communication/`,
`cron/`, `daemon/`, `deployment-manager/`, `external-communication/`, `helm/`,
`secrets/`) builds on this foundation. Each topic is self-contained but assumes
you're comfortable with the concepts here.

> **Heads-up:** the other topics still contain the `apps/v1beta1`, `sed -i`, and
> "no `set -e`" issues that `partone` has been hardened against. Before running
> one of them, check its `deployment.yaml` API version and verify that its app
> actually serves the probe paths its manifest references. See `CLAUDE.md` in
> the repo root for the full list of cross-cutting gotchas.

## 12. Reference: every field in the Deployment manifest, explained

| Field                                 | Purpose                                                                  |
| ------------------------------------- | ------------------------------------------------------------------------ |
| `apiVersion: apps/v1`                 | Stable Deployment API (>= 1.9 GA, `apps/v1beta1` was removed in 1.16).   |
| `kind: Deployment`                    | Controller type: rolling updates, rollback, declarative replica count.   |
| `metadata.name`                       | Name within the namespace. Must be unique.                               |
| `metadata.labels`                     | Labels on the Deployment object itself (not the Pods it creates).        |
| `spec.replicas`                       | Desired Pod count. The controller makes reality match.                   |
| `spec.selector.matchLabels`           | Which Pods this Deployment owns. Must match Pod template labels.         |
| `spec.template.metadata.labels`       | Labels stamped onto every Pod the template creates.                      |
| `spec.template.spec.containers[].name` | Container name (unique within the Pod).                                  |
| `…containers[].image`                 | Registry path + tag. `:latest` forces `imagePullPolicy: Always`.         |
| `…containers[].ports[].containerPort` | Informational: which port the app listens on. Does not bind anything.    |
| `…readinessProbe.httpGet.path`        | URL the kubelet polls to decide if the Pod should receive traffic.       |
| `…readinessProbe.initialDelaySeconds` | Grace period after container start before probes begin.                  |
| `…readinessProbe.periodSeconds`       | How often to probe.                                                      |
| `…readinessProbe.failureThreshold`    | Consecutive failures before the Pod is marked not-ready.                 |
| `…readinessProbe.timeoutSeconds`      | Per-attempt timeout.                                                     |
| `…livenessProbe.*`                    | Same semantics, but failure causes the container to be *killed*.         |
| `…containers[].env[]`                 | Environment variables injected into the container process.               |

### External references

- Kubernetes concepts: <https://kubernetes.io/docs/concepts/>
- GKE overview: <https://cloud.google.com/kubernetes-engine/docs/concepts/kubernetes-engine-overview>
- Cloud Build: <https://cloud.google.com/build/docs>
- Artifact Registry (successor to GCR): <https://cloud.google.com/artifact-registry/docs>
- Express.js: <https://expressjs.com/>
