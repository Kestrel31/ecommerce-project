# Phase 2: Running the store on K3s

Phase 1 ran the store with Docker Compose. Phase 2 runs the same containers on K3s, one namespace per tier, with Kustomize manifests and a single deploy script.

## Architecture

```
                      NodePort 30080
Browser ───────────────────►  web/frontend ──► web/api ──┬─► data/postgres   (StatefulSet + 2Gi PVC)
                                                         ├─► cart/cart        (in-memory)
                                                         ├─► payment/payment  (mock processor, in-memory)
                                                         └─► ads/ads          (in-memory)
```

| Namespace | Workloads | Reachable from |
|-----------|-----------|----------------|
| `web`     | `frontend` (NodePort 30080), `api` | outside (frontend only) |
| `data`    | `postgres` | `web` only |
| `cart`    | `cart` | `web` only |
| `payment` | `payment` | `web` only |
| `ads`     | `ads` | `web` only |

Services talk to each other by cluster DNS (`<service>.<namespace>`), for example `http://cart.cart:3001`.

## Layout

```
k8s/
  namespaces.yaml       the five namespaces
  kustomization.yaml    ties everything together; generates the db-init ConfigMap
  data/postgres.yaml    StatefulSet, Service, 2Gi PVC (K3s local-path)
  data/init.sql         schema and seed data, mounted into the Postgres init directory
  cart/cart.yaml        Deployment + Service
  payment/payment.yaml  Deployment + Service
  ads/ads.yaml          Deployment + Service
  web/api.yaml          Deployment + Service
  web/frontend.yaml     Deployment + NodePort Service
  netpol.yaml           NetworkPolicies: data/cart/payment/ads accept ingress only from `web`
scripts/deploy.sh       build, import, secrets, apply, wait
```

## Hardening applied to every pod

- Runs as a non-root user, with a `RuntimeDefault` seccomp profile.
- `allowPrivilegeEscalation: false` and all capabilities dropped.
- Read-only root filesystem on every app pod (Postgres needs a writable data directory, so it is excluded).
- CPU requests and memory limits set. The full stack should use well under 1 GB of RAM.
- `cart`, `payment` and `ads` keep state in memory, so they stay at 1 replica.

## Prerequisites

- K3s running on the VM.
- Docker installed (Phase 1).
- `kubectl` access to K3s, either:
  - `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml`, or
  - `export KUBECTL="sudo k3s kubectl"`
- `sudo` rights, because the script imports images with `sudo k3s ctr`.
- `openssl` for password generation (installed by default on Debian).

## Usage

```bash
docker compose down        # optional: stop the Phase 1 stack to free RAM
./scripts/deploy.sh
# open http://<vm-ip>:30080
```

The script is idempotent, so run it again after any code or manifest change.

---

## How `deploy.sh` works

The script runs in six steps.

### 0. Setup
```bash
set -euo pipefail
cd "$(dirname "$0")/.."
K=${KUBECTL:-kubectl}
SERVICES=(frontend api cart payment ads)
```
- `set -euo pipefail` makes the script stop on any error, unset variable or failed pipe.
- `cd` moves to the repo root, so you can run the script from anywhere.
- `K` is the kubectl command. It defaults to `kubectl` and can be overridden with `KUBECTL`.

### 1. Build images
```bash
for s in "${SERVICES[@]}"; do docker build -q -t "shop/$s:dev" "services/$s"; done
```
Builds each service from its multi-stage Dockerfile and tags it `shop/<service>:dev`. `-q` keeps the output quiet.

### 2. Import images into K3s
```bash
docker save shop/frontend:dev shop/api:dev ... | sudo k3s ctr images import -
```
K3s uses its own containerd, not Docker, so it cannot see images built by Docker. This step streams them from Docker into K3s, so no registry is needed. In Phase 6, CI will push to GHCR and this step goes away.

### 3. Namespaces
```bash
$K apply -f k8s/namespaces.yaml
```
Namespaces are created first, because the secrets in the next step live inside them.

### 4. Secrets
```bash
PW=$($K -n data get secret db-credentials -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d || true)
PW=${PW:-$(openssl rand -hex 16)}
```
- It tries to read the existing database password from the cluster. If the secret doesn't exist yet, the read fails quietly (`|| true`).
- If there is no existing password, it generates a random 32-character one.
- So the first run creates a password and later runs reuse it.

It then creates two secrets:

| Secret | Namespace | Contents | Used by |
|--------|-----------|----------|---------|
| `db-credentials` | `data` | `POSTGRES_USER`, `POSTGRES_DB`, `POSTGRES_PASSWORD` | Postgres |
| `api-db` | `web` | `DATABASE_URL` (`postgres://shop:<pw>@postgres.data:5432/shop`) | API |

Both use `create --dry-run=client -o yaml | kubectl apply -f -`, which makes creation idempotent: it creates the secret if missing and updates it otherwise. The password never touches disk or git.

### 5. Apply manifests
```bash
$K apply -k k8s
```
Applies everything in `k8s/kustomization.yaml`: Postgres, the four apps, the NetworkPolicies, and the `db-init` ConfigMap generated from `init.sql`.

### 6. Restart and wait
```bash
$K -n <ns> rollout restart deploy/<name>     # for the five app deployments
$K -n data rollout status sts/postgres --timeout=180s
$K -n <ns> rollout status deploy/<name> --timeout=120s
```
- **Why restart?** Every image uses the same `:dev` tag, so Kubernetes sees no manifest change and wouldn't replace the pods. The restart forces new pods that use the freshly imported images.
- **Why wait?** The script blocks until each workload is ready, and fails if one isn't within its timeout. Postgres is not restarted, which protects your data.
- Finally it prints the URL: `http://<vm-ip>:30080`.

---

## Verify

```bash
kubectl get pods -A | grep -E 'web|data|cart|payment|ads'
curl -s http://localhost:30080/healthz
curl -s http://localhost:30080/api/products | head -c 200
```

## Failure drills (independent failure per namespace)

```bash
kubectl -n ads scale deploy/ads --replicas=0           # banner disappears
kubectl -n cart scale deploy/cart --replicas=0         # cart panel: "Cart unavailable"
kubectl -n payment scale deploy/payment --replicas=0   # checkout fails
# recover
kubectl -n ads scale deploy/ads --replicas=1
```

The `/chaos/down` endpoints also work, but the NetworkPolicies block direct access, so use a port-forward:
```bash
kubectl -n cart port-forward deploy/cart 3001 &
curl -X POST localhost:3001/chaos/down
```

## Troubleshooting

| Symptom | Likely cause and fix |
|---------|----------------------|
| `ImagePullBackOff` or `ErrImageNeverPull` | Image import failed. Re-run the script and check the `ctr images import` step. `sudo k3s ctr images ls \| grep shop` lists imported images. |
| Postgres `CrashLoopBackOff` | Check `kubectl -n data logs sts/postgres`. Volume permission errors point to `fsGroup` or storage class issues. |
| API can't log in to the database | The password in the secret doesn't match the one stored in an existing volume (see Gotchas). |
| `kubectl` permission denied | Set `KUBECONFIG` or `KUBECTL="sudo k3s kubectl"`. |
| Name collisions | Another project already uses these namespaces. Check `kubectl get ns`. |

## Gotchas

- **Database password and the PVC.** Postgres reads its password only when it first initializes an empty data directory. If you delete the `db-credentials` secret but keep the PVC, the script generates a new password that no longer matches the data. To reset, delete both: `kubectl -n data delete sts postgres pvc -l app=postgres` and the secret, then re-run the script. This wipes the data.
- **Seed data runs once.** `init.sql` only runs on an empty data directory. Changing it later does not alter an existing database.
- **Duplicate `init.sql`.** `db/init.sql` (Compose) and `k8s/data/init.sql` (K3s) are separate copies. Keep them in sync until a later phase unifies them.
- **In-memory services lose state.** Restarting `cart` or `payment` empties their data. This is by design.

## What comes next

- **Phase 3:** Terraform for K3s, namespaces and Helm releases.
- **Phase 4:** a Cloudflare Tunnel replaces the NodePort as the public entry point.
- **Phase 5:** Prometheus and Grafana. The NetworkPolicies will need a rule that lets the monitoring namespace scrape `/metrics`.
