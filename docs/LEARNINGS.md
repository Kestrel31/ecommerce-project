# Learnings: Questions and Answers

A running log of questions raised while building this project, grouped by phase. Each entry has the question, the answer, and a short "interview angle". This file is meant to grow, and new entries go under the phase where they came up.

**Project in one line:** a 3-tier e-commerce store (Node.js 20 / Express / PostgreSQL 16) with independently failable cart, payment (mock) and ads microservices, running on K3s on a Debian VM, with Terraform, Cloudflare Tunnel, monitoring and CI/CD planned for later phases.

---

## Phase 0: Planning and repo setup

### Q: Doesn't the `3tier-ecommerce-devops` folder already have files and belong to another repo?
**Answer:** Yes. It had a full existing project (`apps/`, `infra/`, `gitops/`, CI workflows). My first scaffold wrongly assumed it was empty, and it added files there. Everything was moved to a separate folder, `ecommerce-standalone`, and the original repo was restored.

**What went wrong and why it matters**
- The assumption "only a README exists" was never verified. Always inspect `git status`, `git remote -v` and the file tree before writing into an existing directory.
- A stale `.git/index.lock` (0 bytes, dated days earlier, no running git process) made `git checkout` fail. The workaround was `git show HEAD:.gitignore > .gitignore`. The lock file is safe to delete only after confirming no git process is running (`pgrep -fl git`).

**Interview angle:** "Tell me about a mistake." Talk about the discipline of verifying state before changing it, and about cleaning up without destroying someone else's untracked work (`docs/runbooks/terraform-troubleshooting.md` was left alone).

### Q: Why these tool choices (Prometheus/Grafana, GitHub Actions + Argo CD)?
**Answer:** The VM has 6 cores and 12 GB of RAM.
- **Datadog and Splunk:** free tiers are trials or limited.
- **ELK:** too heavy for 12 GB.
- **Jenkins:** heavy compared to GitHub Actions.
- **Flux:** a fine alternative to Argo CD.
- **Prometheus + Grafana:** free, light, and the standard pairing for a `prom-client` app.

**Interview angle:** being able to justify tool choices against a resource budget.

---

## Phase 1: Standalone app with Docker Compose

### Q: What do I need to install on the VM?
**Answer:** Docker Engine plus the Compose plugin, and git. Node.js and PostgreSQL are not needed on the VM, because the images build and run everything inside containers.

### Q: `Package docker-ce is not available` / `Unable to locate package containerd.io`
**Answer:** The cause was simple: `sudo apt-get update` hadn't been run after adding Docker's apt repo, so apt didn't know about the new packages. The diagnosis steps were to check `docker.list`, the Debian codename, and the key file.

**Lesson:** after adding any apt source, run `apt-get update`. This error message ("no installation candidate") is the classic symptom.

### Q: `permission denied while trying to connect to the docker API at unix:///var/run/docker.sock`
**Answer:** The user wasn't in the `docker` group, or the current shell hadn't picked up the membership.
```bash
sudo usermod -aG docker $USER
newgrp docker        # or log out and back in
```
**Note:** membership in the `docker` group is effectively root-equivalent on that host, so it's fine for a lab VM but something to mention in a security discussion.

---

## Phase 2: Running on K3s

### Q: Explain `deploy.sh`
**Answer:** The script is idempotent and has seven parts:

| Step | What it does |
|------|--------------|
| 0. Setup | `set -euo pipefail`, `cd` to the repo root, `KUBECTL` override |
| 1. Build | `docker build` each service, tagged `shop/<svc>:dev` |
| 2. Import | `docker save ... \| sudo k3s ctr images import -` |
| 3. Namespaces | `kubectl apply -f k8s/namespaces.yaml` |
| 4. Secrets | reuse or generate DB password, create two secrets |
| 5. Apply | `kubectl apply -k k8s` |
| 6. Restart and wait | `rollout restart`, then `rollout status` with timeouts |

**Why import into K3s?** K3s uses its own containerd, which can't see images in Docker's store. Piping `docker save` into `ctr images import` avoids running a registry. Phase 6 replaces this with GHCR.

**Interview angle:** idempotency, fail-fast shell options, and the Docker vs containerd image stores.

### Q: Explain step 4, the secrets logic
```bash
PW=$($K -n data get secret db-credentials -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d || true)
PW=${PW:-$(openssl rand -hex 16)}
```
**Answer:**
- The first line tries to read the existing password from the cluster. If the secret doesn't exist, the failure is swallowed (`|| true`) and `PW` is empty.
- The second line uses `${PW:-default}`: if `PW` is empty, it generates 32 hex characters with `openssl`.
- Result: the first run generates a password, and later runs reuse it.

**Idempotent creation:** `kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -` creates the secret if missing and updates it otherwise. Plain `kubectl create` would fail on the second run.

### Q: Where does the `api-db` secret come from, and why is it a secret?
**Answer:**
- **Origin:** it is created by `deploy.sh` itself; no file in the repo defines it. The value is `DATABASE_URL=postgres://shop:<pw>@postgres.data:5432/shop`.
- **Why a secret:** the URL contains the password. A secret keeps it out of git, out of `kubectl describe pod` output, and under separate RBAC from ConfigMaps.
- **Why two secrets:** secrets are namespaced, and a pod can only reference secrets in its own namespace. Postgres (`data`) needs `POSTGRES_PASSWORD`; the API (`web`) needs the full URL. Both are derived from the same `$PW`.
- **Consumption:** `envFrom: secretRef: api-db` in `api.yaml` exposes `DATABASE_URL` as an environment variable.

**Caveat to state honestly:** secrets are base64-encoded, not encrypted, unless encryption at rest is enabled. Anyone who can run `kubectl get secret -o yaml` can read them. For production use Sealed Secrets, SOPS or External Secrets.

### Q: Explain step 5, Apply manifests
**Answer:** `kubectl apply -k k8s` builds and applies the Kustomize directory.
- `apply` is declarative: it creates missing resources, patches changed ones and leaves unchanged ones alone.
- It runs after namespaces and secrets, because resources need their namespace, and pods that reference a missing secret get stuck in `CreateContainerConfigError`.
- Preview tools: `kubectl kustomize k8s`, `kubectl diff -k k8s` and `kubectl apply -k k8s --dry-run=server`.

### Q: What does Kustomize actually do here?
**Answer:** Very little, and that's worth admitting.
1. It bundles seven manifests behind one `apply -k`.
2. It generates the `db-init` ConfigMap from `init.sql`, so the SQL stays a real `.sql` file. `disableNameSuffixHash: true` keeps the ConfigMap name stable, because `postgres.yaml` references it by plain name.

It does not yet use overlays, patches or image transformers. It is kept because Phase 6 needs it: `kustomize edit set image shop/api=ghcr.io/...:<sha>` for CI, and Argo CD's native Kustomize support.

### Q: K3s isn't installed yet. What now?
**Answer:**
```bash
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes
```
- K3s bundles containerd, `local-path` storage (used by the Postgres PVC), a network policy controller (enforces `netpol.yaml`), CoreDNS, metrics-server and Traefik.
- Traefik can be disabled with `--disable traefik` once `cloudflared` is the entry point, saving roughly 100 MB of RAM.
- Docker and K3s coexist, because K3s doesn't use Docker.

Phase 3 will move this install into Terraform.

### Q: What does the API pod do?
**Answer:** It is the backend and the only component that talks to Postgres.
```
Browser → frontend (proxies /api/*) → api → postgres / cart / payment / ads
```
- **Endpoints:** products, ads, cart (get, add, clear), checkout, `/healthz` and `/metrics`.
- **Checkout flow:** get cart → reject empty → compute total → charge via payment → insert order into Postgres → clear cart → return order ID. Declines return 402 and an unreachable payment returns 503, and both increment `orders_total{result="failed"}`.
- **Why it exists:** it concentrates database credentials in one place and isolates failures. Every upstream call has a 2-second timeout and its own error handling.
- **Degradation:** ads down means the banner disappears; cart down returns 503 "cart unavailable"; payment down fails checkout; Postgres down breaks products and checkout.
- **Price integrity:** the browser sends only a `productId`. The API looks up the price in the database, so clients can't set prices.

**Interview angle:** graceful degradation, timeouts, circuit-breaker-style isolation (this project has timeouts but no real circuit breaker, so say so), and the backend-for-frontend pattern.

### Q: Why restart and wait? Isn't the image already built and loaded into K3s?
**Answer:** The image is rebuilt and imported on every run (steps 1 and 2). The restart is still needed because a running pod keeps the image it started with.
- Kubernetes only replaces pods when the pod spec changes. The spec says `image: shop/api:dev` both before and after, so `apply` reports `unchanged`.
- `rollout restart` creates new pods, and containerd resolves the tag `shop/api:dev` to the newly imported image. The pull policy is `IfNotPresent` for non-`latest` tags, so nothing is pulled from a registry.
- On a first deploy the restart is redundant, because pods are created after the import.
- **Wait:** `rollout restart` returns immediately. `rollout status` blocks until new pods pass readiness probes, so a crashing build makes the script fail loudly. Rolling updates keep the old pod serving until the new one is ready.
- **Postgres is not restarted:** this protects stateful data.

**Better approach (Phase 6):** unique, immutable tags such as `shop/api:<git-sha>`. The spec then changes on every build, `apply` rolls pods by itself, and the forced restart goes away.

**Interview angle:** mutable tags (`:dev`, `:latest`) vs immutable tags, and why GitOps relies on the latter.

### Q: What is `http://10.0.2.15:30080`, and why does the page show only the cart there while `localhost:30080` works?
**Answer:**
- **The address:** `10.0.2.15` is the default IP VirtualBox gives a VM on NAT networking. `deploy.sh` prints it via `hostname -I | awk '{print $1}'`. The host can't reach it directly under NAT. `localhost:30080` works because of a port-forward rule from the host to the VM.
- **The bug:** the page script began with `crypto.randomUUID()`. Browsers only expose it in **secure contexts** (HTTPS or `localhost`). On plain HTTP to `10.0.2.15` it is undefined, so the script threw on its first line. Nothing after it ran, so products, the ad and the cart never loaded, and only the static HTML (the cart panel) showed.
- **Fix:** fall back to a `getRandomValues`-based UUID when `randomUUID` is missing. `loadProducts` now also shows an error message or "No products available" instead of failing silently.
- **My misdiagnosis:** I first guessed that Postgres or `init.sql` was failing. The fact that `localhost` worked and the IP didn't ruled that out, since both hit the same server. Same backend, different result means the cause is client-side.

**Interview angle:** secure-context restrictions on browser APIs, and using "works here, fails there" to isolate client vs server. Also: don't commit to a diagnosis before comparing the working and failing cases.

---

## Phase 3: Terraform

### Q: Why move namespaces and secrets from `deploy.sh` into Terraform?
**Answer:** They are infrastructure, not application releases. Terraform gives declarative state, drift detection and a single source of truth, and `deploy.sh` is left to do the app release. The DB password becomes a `random_password` resource, so both secrets derive from one value.

**Trade-off to state:** the password now lives in Terraform state, so state must be gitignored and backed up. A remote, encrypted backend would be the production choice.

### Q: Why wasn't Cloudflare in Phase 3?
**Answer:** The tunnel and DNS only matter alongside the `cloudflared` deployment, so they were moved to Phase 4. That also avoids needing a domain and API token before they're useful.

### Q: What happens when Terraform meets resources that already exist?
**Answer:** Terraform only manages what is in its state. Existing namespaces and secrets cause "already exists" errors, so you `terraform import` them. For `random_password`, importing the existing value keeps Postgres working, because the volume already holds that password. Always read the plan before applying: a proposed namespace replacement would delete its contents.

**Interview angle:** adopting existing infrastructure into IaC, state as a source of truth, and the danger of replace actions on stateful resources.

### Q: How does `terraform import` work?
**Answer:** Terraform compares three things: your `.tf` code, the state file, and the real world. Phase 2 resources existed in the cluster but not in state, so a plain `apply` would fail with "already exists". `terraform import <address> <id>` looks up the real resource and records it in state under the address from your code. It changes nothing in the cluster and writes no `.tf` code, so the resource block must already exist.
- **Address:** the resource in code, e.g. `kubernetes_namespace_v1.ns["web"]`.
- **ID:** how the provider finds it: `web` for a namespace, `namespace/name` for a secret.
- **`random_password` is special:** it isn't a real object, so the import ID is the value itself. Importing the existing password kept it matching the Postgres volume.

**Interview angle:** adopting existing infrastructure into IaC without recreating it, and why the plan after an import is the safety check.

### Q: How does `kubernetes_namespace_v1` get the real resource from K3s during import?
**Answer:** Terraform core only manages state and the dependency graph. The `kubernetes` provider plugin (downloaded by `terraform init`) reads credentials from the kubeconfig (`config_path`, default `/etc/rancher/k3s/k3s.yaml`) and calls the K3s API: `GET /api/v1/namespaces/web`. It maps the JSON onto the resource schema and Terraform saves it to state. Import is read-only, and every `plan` repeats the lookup to detect drift.
- The `KUBECONFIG` env var only affects `kubectl`, not the provider. I told you to export it before `terraform init`, which was unnecessary for Terraform.

**Interview angle:** core vs provider architecture. The same pattern applies to the Cloudflare provider in Phase 4.

### Q: What did `lifecycle { ignore_changes = all }` on `random_password.db` do, and why was it needed?
**Answer:** I suspected the import stored only the password value, not settings such as `length` and `special`. Terraform would then see differences and plan to **replace** the password, producing a new one that no longer matches the Postgres volume and locking the API out. `ignore_changes = all` freezes the resource at its imported value. I did not see the plan, so that is my inference, not a confirmed diagnosis.
- **Side effect:** a normal `apply` can no longer rotate the password. `-replace=random_password.db` still works but only updates the secrets, not the password inside Postgres.

**Interview angle:** imported state can differ from what the code describes, and `plan` caught it before anything was applied. Never apply a plan that replaces a stateful resource without understanding why.

---

## Phase 4: Cloudflare Tunnel and DNS

### Q: Do I need to register the `shop` subdomain? I already have a `www` on EC2.
**Answer:** No. A subdomain isn't registered anywhere. AWS holds only the registration of `webfranzresume.click`, and every hostname under it is a DNS record in whichever DNS host is authoritative. Terraform creates one proxied CNAME for `shop`, and the existing `www` record is untouched.

### Q: Why did Cloudflare say "invalid nameserver" when Route 53 looked correct?
**Answer:** The registered domain listed **six** nameservers: Cloudflare's `audrey` and `dion` plus the four old `awsdns` ones. Cloudflare only activates a zone when the registrar lists exactly its assigned pair. Resolvers also picked from the mixed list, so `8.8.8.8` returned Cloudflare servers at one moment and AWS servers the next. `whois` exposed it, because it reads the registry and not a cache. Removing the four AWS entries fixed it.
- Route 53 has two lists that look alike: the hosted zone's NS record (not read by the internet once you've moved) and the registered domain's name servers (the one that counts).
- `original_name_servers` in Cloudflare's API only records where the domain started. It routes nothing.

**Interview angle:** registrar vs DNS host vs origin are separate roles, and the registrar's nameserver list is authoritative. Details are in `DNS-CLOUDFLARE-AWS.md`.

### Q: Why did `dig` time out against `1.1.1.1` and `8.8.8.8`?
**Answer:** The corporate VPN blocked outbound DNS to anything but its own resolver. With the VPN off they worked. This was unrelated to the domain.

### Q: I pasted my API token into the chat. What now?
**Answer:** Treat it as exposed and roll or delete it, which was done. Tokens belong in an environment variable on the VM (`TF_VAR_cloudflare_api_token`), never in chat, files or git. Account and zone IDs are identifiers, not credentials, and are fine to commit.

### Q: `git pull` failed because of `terraform/.terraform.lock.hcl`.
**Answer:** The lock file is tracked, and both the VM's `terraform init` and the pull had changed it. It only records provider versions and checksums, so `git checkout` on that one file discards the VM's copy, and `terraform init` regenerates it. Commit the result so versions stay pinned.

### Q: `expected DNS record to not already be present but already exists`.
**Answer:** A `shop` CNAME already existed in Cloudflare. Importing it would have been wrong here: it pointed at tunnel `896f2ce1...`, while Terraform's state held tunnel `47f861eb...`. The likely cause is an earlier `apply` that created the record and then failed before saving state. I inferred that from the symptoms and never confirmed it. The fix was to compare the IDs, delete the stale record and re-apply.

**Interview angle:** check what an existing resource points at before adopting it into state. Importing a record that targets the wrong tunnel would have aimed the site at nothing.

### Q: What is `cfargotunnel.com`?
**Answer:** Cloudflare's domain for tunnel endpoints, with addresses of the form `<tunnel-id>.cfargotunnel.com`. It is only usable as a **proxied** CNAME target inside a Cloudflare zone and isn't publicly resolvable. When the zone was pending, `dig` returned the raw `cfargotunnel.com` name instead of Cloudflare IPs, which was a sign the proxy wasn't active.

### Q: Why is the tunnel healthy but `curl` says "Could not resolve host"?
**Answer:** They are separate layers. The tunnel is `cloudflared` connecting outbound to Cloudflare, and it worked. Resolving the hostname depends on the zone being Active. Pending zones don't serve proxied records.

### Q: My `www` runs on HTTP only. Will it survive the move?
**Answer:** Once the zone is Active, an orange-cloud record routes through Cloudflare, which connects to the origin according to the SSL mode. Full or Full (strict) against an HTTP-only origin gives 52x errors, and Flexible with an origin that redirects to HTTPS gives a redirect loop. Options are grey cloud (nothing changes), Flexible (stopgap), or a certificate on the EC2 with Full (strict). See `WWW-FIX.md`. The outcome here was that `www` and `shop` both loaded after activation. I don't know which option you chose.

---

## Phase 5: Monitoring

> Written and validated locally, but not yet recorded as deployed. Update this section once it runs.

### Q: Why Prometheus and Grafana, and why trimmed?
**Answer:** `kube-prometheus-stack` is the standard pairing for `prom-client` apps and is free. On 12 GB it is trimmed: Alertmanager off, the K3s-embedded control-plane targets off (they'd show permanently down), 3-day retention, and explicit memory limits. Roughly 1.5 GB total.

### Q: Why are the PodMonitor, alerts and dashboard in Kustomize instead of Terraform?
**Answer:** `PodMonitor` and `PrometheusRule` are custom resources whose definitions only exist after the Helm chart installs. Terraform's Kubernetes provider needs the schema at plan time, so declaring them in the same run can fail. `deploy.sh` applies them only if the CRDs exist.

### Q: Why does `ServiceUnavailable` use kube-state-metrics instead of `up`?
**Answer:** A deployment scaled to zero has no pod and no scrape target, so `up` vanishes instead of reporting 0, and an alert on `up == 0` would never fire. kube-state-metrics reports the deployment's available replicas directly.

### Q: Why did the NetworkPolicies and port names change?
**Answer:** The policies only allowed ingress from `web`, which would block Prometheus from `/metrics`, so `cart`, `payment` and `ads` now also allow `monitoring`. The PodMonitor refers to the container port by name, so each port is now `http`. That changes the pod spec and rolls the pods.

---

## Design decisions to be ready to defend

| Decision | Reasoning | Trade-off |
|----------|-----------|-----------|
| One namespace per service | Isolation of blast radius, per-namespace policies and quotas | More objects to manage; cross-namespace DNS names (`cart.cart`) |
| NetworkPolicy: only `web` can reach backends | Least privilege between tiers | Must add rules for monitoring in Phase 5; chaos endpoints require port-forward |
| In-memory cart, payment, ads | Simple, and demonstrates independent failure | State lost on restart; must stay at 1 replica |
| Mock payment processor | No real card data and no PCI scope | Not realistic |
| Multi-stage, non-root, alpine images | Smaller attack surface and image size | Alpine's musl libc can cause rare native-module issues |
| Read-only root filesystem and dropped capabilities | Container hardening | Apps can't write to disk (Postgres is excluded) |
| Secrets generated at deploy time | Nothing sensitive in git | Not reproducible from git alone; deleting the secret but keeping the PVC breaks DB login |
| Images imported directly into K3s | No registry needed for a single node | Doesn't scale to multiple nodes; replaced by GHCR in Phase 6 |

## Known limitations

- Secrets are base64, not encrypted at rest.
- Mutable `:dev` tags need a forced restart.
- `db/init.sql` (Compose) and `k8s/data/init.sql` (K3s) are duplicate copies and must be kept in sync.
- Postgres is a single replica with a local-path volume, so there is no HA and no backup yet.
- Seed SQL runs only on an empty data directory.
- No lockfiles yet, so the Dockerfiles use `npm install` rather than `npm ci`.
- Tested paths: Phase 1 (Compose) was confirmed working by the owner. Phase 2 manifests were written but their deployment result has not been recorded yet.

## Likely interview questions

1. **Walk me through the architecture.** Browser → frontend → API → Postgres plus three microservices, each in its own namespace.
2. **How do you handle a microservice failing?** Per-call timeouts, explicit error handling, and degraded behavior per dependency. Prove it with the scale-to-zero drills.
3. **How do you manage secrets?** Generated at deploy time, kept out of git, stored as Kubernetes Secrets. Know the limitations and the production alternatives.
4. **How does your deploy work and is it idempotent?** Walk through `deploy.sh`.
5. **Why Kustomize, and what will you use it for?** Honest answer, plus the Phase 6 plan.
6. **How would you make this production-ready?** Immutable image tags, a registry, encrypted secrets, Postgres HA or a managed DB with backups, network policies for monitoring, resource quotas, and a pod disruption budget.
7. **How do containers differ from Docker on K3s?** K3s uses containerd, so images must be imported or pulled from a registry.

---

## Template for new entries

```
### Q: <question>
**Answer:** ...
**Interview angle:** ...
```
