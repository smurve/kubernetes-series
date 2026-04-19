# kitt-prod-deploy

Exposes the `partone` demo container on `https://kitt.smurve.ch` via a
Google-managed SSL certificate, a global External HTTP(S) Load Balancer, and a
reserved global static IP. Deployed to the `kitt-prod` GKE Autopilot cluster in
`europe-west6`.

This stack is intentionally separate from `../partone/`, which stays
pedagogical and uses a regional Network Load Balancer on an ephemeral IP.

---

## 1. Topology

```
  kitt.smurve.ch            (A -> 34.117.180.48, reserved as 'kitt-ingress')
         |
         v
  +------------------------------+
  |  Global External HTTP(S) LB  |     <- Ingress 'kitt-ingress'
  |   :80  -> 301 redirect :443  |        redirect URL map (FrontendConfig)
  |   :443 -> SSL termination    |        ManagedCertificate 'kitt-cert'
  +--------------+---------------+
                 |
            NEG backend                  <- container-native LB, NEGs per zone
                 |
         +-------+-------+
         |       |       |
         v       v       v
        Pod     Pod     Pod              <- Deployment 'endpoints', 3 replicas
```

Four Google Cloud objects are created automatically by the GKE Ingress
controller from the Kubernetes manifests below:

| GCP object             | K8s source                                                                      |
| ---------------------- | ------------------------------------------------------------------------------- |
| Global forwarding rule | `Ingress` + `ingress.global-static-ip-name`                                     |
| Target HTTPS proxy     | `Ingress` + `managed-certificates` + `FrontendConfig`                           |
| URL map                | `Ingress` rules (`host`, `paths`) and `defaultBackend`                          |
| Backend service (NEG)  | `Service` + `cloud.google.com/neg: '{"ingress": true}'` annotation              |

The NEG ("Network Endpoint Group") is the key difference from Google's older,
instance-group-based load balancing: the LB sends traffic directly to Pod IPs
instead of hopping through a NodePort and `kube-proxy`. On Autopilot, NEGs are
in fact mandatory — the legacy `k8s-ig--<hash>` instance-group backend does not
exist.

---

## 2. Manifests

| File                           | Purpose                                                                            |
| ------------------------------ | ---------------------------------------------------------------------------------- |
| `k8s/deployment.yaml`          | 3-replica Deployment, reuses `gcr.io/<project>/partone-container:latest`           |
| `k8s/service.yaml`             | ClusterIP + `cloud.google.com/neg` annotation (container-native LB)                |
| `k8s/managed-certificate.yaml` | `ManagedCertificate` CRD for `kitt.smurve.ch` (Google auto-provisions the cert)    |
| `k8s/frontend-config.yaml`     | `FrontendConfig` CRD enabling `301 Moved Permanently` from HTTP to HTTPS           |
| `k8s/ingress.yaml`             | GCE Ingress: attaches static IP, cert, frontend config, host rule, default backend |

### 2.1 Why `defaultBackend` in the Ingress

On GKE Autopilot the legacy `default-http-backend` Service (in `kube-system`,
backed by a GCE instance group that no longer exists) is referenced but not
reconcilable. If your Ingress has only `rules:` and no `defaultBackend:`, the
URL map's *default* service will point at that broken backend and every
request that doesn't match a rule returns a Google-served 404 HTML page. Worse,
Google's ACME HTTP-01 prober for the ManagedCertificate is such a request —
so the cert can get stuck in `Provisioning` forever.

The fix is to set:

```yaml
spec:
  defaultBackend:
    service:
      name: endpoints
      port:
        number: 80
```

This replaces the URL map's broken default service with your own backend.

---

## 3. Scripts

| Script                | What it does                                                                 |
| --------------------- | ---------------------------------------------------------------------------- |
| `scripts/provision.sh`| Reserves the global static IP `kitt-ingress` (idempotent). Prints the IP.   |
| `scripts/deploy.sh`   | Applies all manifests in the right order and waits for rollout.              |
| `scripts/status.sh`   | Snapshot: pods, service endpoints, ingress IP, cert state, DNS.              |

---

## 4. Prerequisites (one-time)

1. GCP project with `compute.googleapis.com` and `container.googleapis.com` enabled.
2. The `kitt-prod` GKE cluster must exist in `europe-west6`, and `kubectl`'s
   current context must point to it:
   ```bash
   gcloud container clusters get-credentials kitt-prod --region europe-west6
   ```
3. The container image must already be in `gcr.io/<project>/partone-container:latest`
   (run `partone/scripts/startup.sh` once to build it).
4. DNS for `kitt.smurve.ch` must already resolve to the reserved global IP
   before the ManagedCertificate will leave `Provisioning`. See §6.

---

## 5. Usage

```bash
cd kitt-prod-deploy

# 1. Reserve the global IP (idempotent). Prints the address on stdout.
IP=$(sh scripts/provision.sh) && echo "Update A record for kitt.smurve.ch to: $IP"

# 2. (Manual) In your DNS provider:
#       - set the A record for 'kitt' to $IP
#       - remove any other A or AAAA records for 'kitt' (see §6)
#       - drop the TTL to 60s (or the provider minimum) to speed up the switch

# 3. Wait for DNS to propagate on public resolvers.
dig +short @8.8.8.8 kitt.smurve.ch A     # must return $IP, nothing else
dig +short @8.8.8.8 kitt.smurve.ch AAAA  # must be empty

# 4. Deploy.
sh scripts/deploy.sh

# 5. Watch the certificate provision. ManagedCertificate goes
#    Provisioning -> Active. Realistic wait: 10-60 min after DNS is clean.
watch -n 15 sh scripts/status.sh

# 6. Once Active:
curl -v https://kitt.smurve.ch/        # -> "Hello Docker"
curl -v http://kitt.smurve.ch/         # -> 301 to https
```

---

## 6. DNS — the part that will bite you

The ManagedCertificate workflow is an ACME HTTP-01 challenge run by Google
against the domain. For it to succeed, **every public DNS record for the host
must route back to this load balancer on port 80**. A single stray record
pointing elsewhere is enough to keep the cert stuck in `Provisioning` (or flip
it to `FailedNotVisible`). The load balancer itself will serve traffic from
the moment the Ingress object is ready — but without a valid cert, clients
see TLS handshake failures on `:443`.

### 6.1 Requirements on the zone

For the host `kitt.smurve.ch`:

1. **Exactly one `A` record**, pointing at the reserved global IPv4 (here
   `34.117.180.48`). Any additional `A` record — e.g. left over from a previous
   static IP, or the registrar's default parking IP — must be removed.
2. **Zero `AAAA` records.** The reserved GCE global static IP is IPv4 only. An
   `AAAA` pointing anywhere else (in our case cyon's shared hosting default
   `2a01:ab20:0:4::149`) will send every IPv6-capable client, *including
   Google's prober*, to the wrong server. IPv6 clients are growing; you will
   notice this as intermittent failures.
3. No `CNAME` record on the same label (can't coexist with `A` at the apex of
   a label).

### 6.2 Why stale records are so common

Domain registrars that also offer shared hosting (cyon, OVH, GoDaddy, ...)
often provision *default* `A` and `AAAA` records pointing at their own parking
page the moment you register the domain. Those records stay in place when you
add your own `A` record — you end up with *two* A records and a parking
`AAAA`, load-balanced round-robin by the resolver. Half your traffic goes to
Google, half goes to the registrar's 404 page, and the cert provisioner can
land on either.

### 6.3 How to verify

```bash
# Correct state:
dig +short @8.8.8.8 kitt.smurve.ch A       # -> 34.117.180.48   (single line)
dig +short @8.8.8.8 kitt.smurve.ch AAAA    # -> (empty)
dig +short @1.1.1.1 kitt.smurve.ch A       # -> 34.117.180.48   (sanity)

# Local resolver (may lag the TTL — useful for your own reality check):
dig +short kitt.smurve.ch A
```

If the local resolver still returns an old IP, the DNS cache has not expired
yet. You can't meaningfully test from this machine until it has. Use the
`--resolve` flag to bypass it:

```bash
curl --resolve kitt.smurve.ch:443:34.117.180.48 https://kitt.smurve.ch/
curl --resolve kitt.smurve.ch:80:34.117.180.48  http://kitt.smurve.ch/
```

### 6.4 TTL strategy

Before any DNS change, lower the TTL on the record to the provider minimum
(typically 60–300s). Wait at least the *previous* TTL before making the change,
so that downstream caches will have picked up the low value. Only then swap
the record. This is the standard "pre-announce low TTL, then cut over"
playbook and applies whenever you migrate off an IP.

---

## 7. Managed certificate lifecycle

A `ManagedCertificate` resource in GKE is a thin wrapper that asks Google's
cert manager to run ACME HTTP-01 against each domain, then attach the resulting
cert to the HTTPS target proxy. You watch it with:

```bash
kubectl get managedcertificate kitt-cert -o yaml
```

The `status.certificateStatus` field goes through these states:

| Status              | Meaning                                                                       |
| ------------------- | ----------------------------------------------------------------------------- |
| *(empty)*           | Resource just created, controller has not picked it up yet                    |
| `Provisioning`      | Google is running ACME HTTP-01 via the LB on `:80`                            |
| `Active`            | Cert issued, attached to the HTTPS target proxy, served to clients            |
| `FailedNotVisible`  | Google's prober cannot reach the LB at the domain — almost always DNS         |
| `Failed`            | Permanent failure; `status.domainStatus[*].status` has the reason             |

`FailedNotVisible` and long stalls in `Provisioning` self-heal once DNS and
the Ingress are both correct — the controller retries automatically. Typical
time to `Active` from a clean DNS state is 10–60 minutes; extreme cases can
go a few hours.

### 7.1 What the ACME HTTP-01 challenge actually does

1. Google's cert manager POSTs a challenge token to its own infrastructure.
2. It then makes an unauthenticated HTTP request to
   `http://kitt.smurve.ch/.well-known/acme-challenge/<token>` from the public
   internet.
3. The global HTTPS LB serves that request via the HTTP target proxy.
   Because our `FrontendConfig` forces a 301 redirect to HTTPS, Google's
   prober follows the redirect — this is fine; the prober handles redirects.
4. The redirected HTTPS request is eventually terminated by the same LB (using
   a temporary cert) and routed to the backend, which returns the expected
   token.

Anything that breaks step 2 (wrong `A`, stray `AAAA`, firewall, wrong
Ingress, broken default backend) will cause `FailedNotVisible`.

### 7.2 How to debug from the GCP side

The objects that the Ingress controller produces are all inspectable:

```bash
# Show the URL map that handles HTTPS. defaultService must point at YOUR backend,
# not k8s-be-<NodePort>--<hash> (the broken default-http-backend).
gcloud compute url-maps describe $(kubectl get ingress kitt-ingress \
  -o jsonpath='{.metadata.annotations.ingress\.kubernetes\.io/url-map}') --global

# Show backend service health. Each zonal NEG should report HEALTHY endpoints.
BS=$(kubectl get ingress kitt-ingress \
  -o jsonpath='{.metadata.annotations.ingress\.kubernetes\.io/backends}' | jq -r 'keys[0]')
gcloud compute backend-services get-health "${BS}" --global

# Show the redirect URL map used by the HTTP target proxy.
# Should contain defaultUrlRedirect.httpsRedirect: true.
gcloud compute url-maps describe $(kubectl get ingress kitt-ingress \
  -o jsonpath='{.metadata.annotations.ingress\.kubernetes\.io/redirect-url-map}') --global
```

---

## 8. Adding more services later

Two idiomatic patterns; neither requires rework to switch between them.

**Path-based on same host:**

```yaml
rules:
  - host: kitt.smurve.ch
    http:
      paths:
        - { path: /api/*,       pathType: ImplementationSpecific,
            backend: { service: { name: api,       port: { number: 80 } } } }
        - { path: /dashboard/*, pathType: ImplementationSpecific,
            backend: { service: { name: dashboard, port: { number: 80 } } } }
        - { path: /*,           pathType: ImplementationSpecific,
            backend: { service: { name: endpoints, port: { number: 80 } } } }
```

**Subdomain-based:**

Add the subdomain(s) to `managed-certificate.yaml` (up to 100 SANs per
`ManagedCertificate`) and an additional `rules[].host` block in the Ingress.
Each subdomain needs its own `A` record pointing at the same global IP. You
can reuse the single static IP across any number of hostnames on this LB.

---

## 9. Cost notes

The global External HTTPS LB is billed per forwarding rule-hour plus data
processing; the reserved global static IP is free while it is attached to a
forwarding rule, and charged (small hourly) while unattached. The NEG and the
ManagedCertificate have no direct cost. In `europe-west6` the resting cost of
this stack (3 small Autopilot pods + LB + IP) is modest but non-zero — do not
leave it running if you are not using it. Autopilot bills by requested Pod CPU
and memory, not by VM.

---

## 10. Troubleshooting cheat-sheet

| Symptom                                                             | Likely cause                                           | Check / fix                                                                         |
| ------------------------------------------------------------------- | ------------------------------------------------------ | ----------------------------------------------------------------------------------- |
| `curl https://...` gives `SSL_ERROR_SYSCALL` or TLS handshake fail  | Cert not yet `Active`                                  | `kubectl get managedcertificate`; also verify DNS is clean (§6)                    |
| `curl http://...` returns a Google-looking 404 HTML                 | URL map default points at broken `default-http-backend`| `spec.defaultBackend` missing (§2.1); check `gcloud compute url-maps describe`     |
| `curl http://...` returns a cyon/registrar 404 page                 | DNS still returns the registrar's IP                   | Stale local DNS cache or stray A/AAAA records (§6)                                 |
| Cert stuck in `Provisioning` > 1 h                                  | ACME prober can't reach the LB                         | Check for `AAAA` records, extra `A` records, or pending DNS propagation (§6)       |
| Cert status `FailedNotVisible`                                      | Prober reached the wrong server                        | Same as above; fix DNS and wait — controller retries                               |
| Ingress Events show `error retrieving IG for ...k8s-ig--<hash>`     | Autopilot + no `spec.defaultBackend`                   | Add `defaultBackend` to the Ingress (§2.1)                                         |
| NEG backend shows `UNHEALTHY`                                       | Probe path or port wrong                               | Confirm app serves `/readiness` and `/healthcheck` on `containerPort`              |
| HTTP returns 404 instead of 301                                     | Request went to the wrong IP                           | `curl --resolve host:80:<static IP>` to test the LB directly, then fix DNS         |

---

## 11. Design decisions worth remembering

- **Global LB over regional** — global External HTTPS LB is required for
  Google-managed certs and for a global anycast IP. The cost difference over
  the regional Network LB is small at this scale and buys HTTPS, HTTP→HTTPS
  redirect, and multi-host / path routing for free.
- **Container-native LB (NEG) over NodePort** — avoids the extra `iptables`
  hop through `kube-proxy`, gives real per-Pod health, and is the only option
  on Autopilot.
- **`pathType: Prefix` with `path: /`** — safest default; matches everything
  under the host and lets the app handle routing.
- **`ManagedCertificate` over `cert-manager` in-cluster** — fewer moving
  parts, no in-cluster ACME client to maintain, and the cert lives on the
  Google target proxy directly. Trade-off: you can only use it on a GCLB, and
  it can be opaque when DNS is wrong (hence §6).
- **`FrontendConfig` for the 301** — serves the redirect at the LB edge, no
  round trip to a Pod; also keeps the app code free of HTTP/HTTPS logic.
