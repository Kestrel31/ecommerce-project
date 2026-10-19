#!/usr/bin/env bash
# Build images, load them into K3s, and apply the manifests. Safe to re-run.
# Namespaces and secrets are owned by Terraform (see terraform/).
set -euo pipefail
cd "$(dirname "$0")/.."

K=${KUBECTL:-kubectl}
SERVICES=(frontend api cart payment ads)

$K -n data get secret db-credentials >/dev/null 2>&1 || {
  echo "Namespaces/secrets missing. Run: terraform -chdir=terraform init && terraform -chdir=terraform apply" >&2
  exit 1
}

echo "==> Building images"
for s in "${SERVICES[@]}"; do docker build -q -t "shop/$s:dev" "services/$s"; done

echo "==> Importing images into K3s containerd"
docker save $(printf 'shop/%s:dev ' "${SERVICES[@]}") | sudo k3s ctr images import -

echo "==> Applying manifests"
$K apply -k k8s

echo "==> Restarting app deployments to pick up fresh images"
for ns_dep in web/frontend web/api cart/cart payment/payment ads/ads; do
  $K -n "${ns_dep%/*}" rollout restart "deploy/${ns_dep#*/}"
done

echo "==> Waiting for rollout"
$K -n data rollout status sts/postgres --timeout=180s
for ns_dep in web/frontend web/api cart/cart payment/payment ads/ads; do
  $K -n "${ns_dep%/*}" rollout status "deploy/${ns_dep#*/}" --timeout=120s
done

echo "Done: http://localhost:30080  (VM IP: $(hostname -I | awk '{print $1}'))"
