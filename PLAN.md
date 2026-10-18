# 3-Tier E-Commerce DevOps Project — Plan

Target: Debian VM (6 vCPU / 12 GB), K3s, Cloudflare Tunnel, Terraform (applied on the VM, synced via git).

## Architecture
```
Browser ─► Cloudflare Tunnel ─► frontend (Express, static UI + /api proxy)
                                   └─► api (Express + prom-client) ─► PostgreSQL 16
                                          ├─► cart     (ns: cart,    in-memory)
                                          ├─► payment  (ns: payment, mock processor)
                                          └─► ads      (ns: ads,     in-memory)
```
Each microservice has `/healthz`, `/metrics` and a `/chaos/down|up` switch so it can fail independently.
The API degrades gracefully: ads down → no banner, cart down → cart unavailable, payment down → checkout error.

## Phases
| # | Phase | Output | RAM budget |
|---|-------|--------|-----------|
| 1 | **Standalone app (Docker Compose)** ← this commit | working store on VM:8080 | ~1 GB |
| 2 | K3s manifests (Kustomize), namespaces: `web`, `data`, `cart`, `payment`, `ads`; NetworkPolicies | app on K3s | ~1.5 GB |
| 3 | Terraform: K3s install, namespaces, Helm releases, Cloudflare tunnel + DNS | `terraform apply` rebuilds all | – |
| 4 | Cloudflare Tunnel (`cloudflared` Deployment, token in Secret) | public HTTPS hostname | 50 MB |
| 5 | Monitoring: **Prometheus + Grafana** (kube-prometheus-stack, trimmed) + **Loki** or Jaeger/OTel for traces | dashboards, alerts per service | ~2.5 GB |
| 6 | CI/CD: **GitHub Actions** (build, test, Trivy scan, push to GHCR) + **Argo CD** (GitOps, pulls from repo) | push → deploy | ~600 MB |
| 7 | Chaos/failure drills + SLO dashboards | runbook | – |

Tool choices (free, fits 12 GB): Prometheus+Grafana (not Datadog/Splunk — trial/limited; ELK is too heavy at 12 GB), Jaeger optional, GitHub Actions + Argo CD (Jenkins is heavy; Flux is a fine alternative).

## Repo layout
```
db/init.sql
services/{frontend,api,cart,payment,ads}/   # each: Dockerfile, package.json, server.js
docker-compose.yml
k8s/  terraform/  .github/workflows/        # later phases
```

## Phase 1 run
```
docker compose up -d --build
open http://<vm-ip>:8080
# failure test
curl -X POST localhost:3003/chaos/down   # ads
curl -X POST localhost:3001/chaos/down   # cart
curl -X POST localhost:3002/chaos/down   # payment
curl -X POST localhost:300X/chaos/up     # recover
```
Test card: any number = approved; ending `0000` = declined.
