# Phase 5: Monitoring (Prometheus + Grafana)

Metrics, a dashboard and alerts for every service, using the `kube-prometheus-stack` Helm chart trimmed for a 12 GB VM.

```
app pods (/metrics) ◄── PodMonitor ── Prometheus ──► Grafana (dashboard "Shop Overview")
kube-state-metrics, cAdvisor, node-exporter ──────────┘            │
                                                         PrometheusRule (alerts, visible in UI)
```

## What gets installed

| Piece | Managed by | Notes |
|-------|-----------|-------|
| `monitoring` namespace | Terraform | Added to the namespace set |
| Prometheus, Grafana, kube-state-metrics, node-exporter, operator | Terraform (`helm_release.monitoring`) | Chart version is a variable. `null` means latest at apply time. |
| Grafana admin password | Terraform (`random_password.grafana`) | Stored in the `grafana-admin` secret and in gitignored state |
| `PodMonitor` shop-apps | `deploy.sh` (`k8s/monitoring`) | Scrapes `/metrics` on the five apps every 15s |
| `PrometheusRule` shop-alerts | `deploy.sh` | 5 alerts, below |
| Dashboard ConfigMap | `deploy.sh` | Labelled `grafana_dashboard=1`; Grafana's sidecar loads it |

**Why two tools apply this.** The PodMonitor and PrometheusRule are custom resources whose definitions only exist after the chart installs. Terraform's Kubernetes provider needs them at plan time, so they live in Kustomize instead. `deploy.sh` applies them only if the CRDs exist, and prints a skip message otherwise.

## Changes to existing files
- **Named ports:** every app container's port is now `name: http`. The PodMonitor refers to the port by name.
- **NetworkPolicies:** `cart`, `payment` and `ads` now accept ingress from both `web` and `monitoring`. Without this, Prometheus can't reach `/metrics`. The `data` namespace is unchanged, because Postgres has no metrics endpoint.
- **Disabled targets:** `kubeEtcd`, `kubeScheduler`, `kubeControllerManager` and `kubeProxy` are off. K3s embeds those components, so they'd show as permanently down.
- **Alertmanager:** disabled to save RAM. Alerts show in Prometheus (*Status → Alerts*) and Grafana, but nothing notifies you.
- **Selectors:** `*SelectorNilUsesHelmValues = false` lets Prometheus pick up monitors and rules from any namespace.

## Resource budget (limits, not typical usage)

| Component | Memory limit |
|-----------|-------------|
| Prometheus | 900 Mi (3-day retention, 5 Gi PVC) |
| Grafana | 300 Mi |
| kube-state-metrics | 128 Mi |
| node-exporter | 64 Mi |
| operator | chart default |

Expect roughly 1.5 GB in total, which fits alongside the app (~1 GB) and K3s on 12 GB.

## Alerts (`k8s/monitoring/rules.yaml`)

| Alert | Fires when |
|-------|-----------|
| `ServiceUnavailable` | A deployment in `web`, `cart`, `payment` or `ads` has 0 available replicas for 1 minute |
| `PostgresUnavailable` | The Postgres StatefulSet has 0 ready replicas for 1 minute |
| `ApiHighErrorRate` | API 5xx responses exceed 5% for 5 minutes |
| `CheckoutFailures` | More than half of checkouts failed in 10 minutes |
| `PodRestarting` | A pod restarts more than twice in 15 minutes |

`ServiceUnavailable` uses kube-state-metrics rather than `up`. A deployment scaled to zero has no scrape target, so `up` would simply disappear instead of reporting 0.

## Dashboard "Shop Overview"
Available replicas per service (red at 0), API request rate by status, API p95 latency, orders by result, payment charges by result, and memory and CPU per pod.

## Run (on the VM)
```bash
git pull
cd terraform
export TF_VAR_cloudflare_api_token='<token>'
terraform init          # downloads the helm provider
terraform plan          # adds only: namespace, grafana secret/password, helm release
terraform apply         # chart install can take several minutes
cd .. && ./scripts/deploy.sh      # applies PodMonitor, rules, dashboard; app pods restart for the port names
```
The plan should show **adds only**. Stop if a Phase 3 or 4 resource shows `must be replaced`.

## Access Grafana
Grafana has no ingress and isn't on the tunnel, so it isn't public. Use a port-forward:
```bash
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
# open http://localhost:3000   user: admin
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```
Under VirtualBox NAT, forward it to the VM's address with `--address 0.0.0.0`, or add a port-forward rule in VirtualBox. Prometheus the same way: `svc/monitoring-kube-prometheus-prometheus 9090`.

## Verify
```bash
kubectl -n monitoring get pods          # all Running
```
In Prometheus (*Status → Targets*), the `shop-apps` PodMonitor should list five healthy targets. Run `up{namespace=~"web|cart|payment|ads"}` and expect five series with value 1. Then open Grafana → Dashboards → Shop Overview.

## Failure drill
```bash
kubectl -n ads scale deploy/ads --replicas=0
```
After about a minute the panel for `ads/ads` turns red and `ServiceUnavailable` is firing for `ads`. Scale back with `--replicas=1`. To see errors in the dashboard, make some checkout attempts with payment scaled to zero, then watch the failed counters.

## Gotchas
- **Old NetworkPolicies remain.** The policies were renamed, and `kubectl apply` doesn't delete the old `allow-from-web` objects in `cart`, `payment` and `ads`. They're harmless because policies combine additively, but clean up with `kubectl delete netpol allow-from-web -n cart` (and `payment`, `ads`).
- **The app restarts.** Adding port names changes the pod spec, so the first `deploy.sh` rolls the pods. Cart and payment lose their in-memory data.
- **Chart version.** `null` installs the latest chart at apply time. Pin `kube_prometheus_stack_version` once it works, so rebuilds are reproducible.
- **Helm timeout.** The release has a 600-second timeout. On slow disks, rerun `terraform apply` if it times out. A failed release may need `helm uninstall monitoring -n monitoring` before retrying.
- **Metric labels.** The alert and dashboard queries rely on an `app` label on the app metrics, added by `podTargetLabels`. If the panels are empty, check that label first.
- **Custom metrics only exist after use.** `orders_total` and `payment_charges_total` appear once the first order or charge occurs.
- **Retention.** 3 days on a 5 Gi volume. Deleting the PVC wipes the history.
- **Frontend and cart metrics** are only default Node.js metrics. The business metrics come from the API and payment.
- **`docker compose` isn't monitored.** This covers the K3s deployment only.
