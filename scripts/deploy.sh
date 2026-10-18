#!/usr/bin/env bash
# Build images, load them into K3s, and apply the manifests. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."

K=${KUBECTL:-kubectl}
SERVICES=(frontend api cart payment ads)

echo "==> Building images"
for s in "${SERVICES[@]}"; do docker build -q -t "shop/$s:dev" "services/$s"; done

echo "==> Importing images into K3s containerd"
docker save $(printf 'shop/%s:dev ' "${SERVICES[@]}") | sudo k3s ctr images import -

echo "==> Namespaces"
$K apply -f k8s/namespaces.yaml

echo "==> Secrets (generated once, never written to disk or git)"
PW=$($K -n data get secret db-credentials -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d || true)
PW=${PW:-$(openssl rand -hex 16)}
$K -n data create secret generic db-credentials \
  --from-literal=POSTGRES_USER=shop --from-literal=POSTGRES_DB=shop \
  --from-literal=POSTGRES_PASSWORD="$PW" --dry-run=client -o yaml | $K apply -f -
$K -n web create secret generic api-db \
  --from-literal=DATABASE_URL="postgres://shop:$PW@postgres.data:5432/shop" \
  --dry-run=client -o yaml | $K apply -f -

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

echo "Done: http://$(hostname -I | awk '{print $1}'):30080"
