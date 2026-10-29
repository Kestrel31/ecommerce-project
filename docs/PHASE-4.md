# Phase 4: Cloudflare Tunnel

Public HTTPS access to the store at `https://shop.webfranzresume.click` with no inbound ports opened on the VM.

```
Browser ─► Cloudflare edge (TLS) ─► tunnel ◄── cloudflared pod (ns: cloudflare) ─► http://frontend.web:8080
```
`cloudflared` makes an **outbound** connection to Cloudflare, so there is no port-forwarding or public IP involved. This works behind VirtualBox NAT.

## What Terraform creates (`terraform/cloudflare.tf`)

| Resource | Purpose |
|----------|---------|
| `random_id.tunnel_secret` | Tunnel secret (kept in gitignored state) |
| `cloudflare_zero_trust_tunnel_cloudflared.shop` | The tunnel |
| `..._config.shop` | Ingress: `shop.webfranzresume.click` → `http://frontend.web:8080`, everything else 404 |
| `cloudflare_record.shop` | Proxied CNAME `shop` → `<tunnel-id>.cfargotunnel.com` |
| `kubernetes_secret_v1.tunnel_token` | `TUNNEL_TOKEN` in new namespace `cloudflare` |
| `kubernetes_deployment_v1.cloudflared` | 1 replica, non-root, read-only filesystem, probes on `/ready` |

Only the `shop` record is created. Your existing `www` record (EC2) is not touched.

## Prerequisites
1. The zone is **Active** in Cloudflare. The tunnel works without it, but the DNS record won't resolve until it is.
2. A **new** API token with *Account → Cloudflare Tunnel → Edit* and *Zone → DNS → Edit*, scoped to this account and zone. Keep it on the VM only.
3. Terraform on the VM, with Phase 3 applied.

## Run (on the VM)
```bash
git pull
cd terraform
cp terraform.tfvars.example terraform.tfvars      # IDs only, no secrets
export TF_VAR_cloudflare_api_token='<token>'      # never in a file or in chat
terraform init                                    # downloads the cloudflare provider
terraform plan                                    # read it
terraform apply
```

The plan should show **adds only**: the new `cloudflare` namespace, tunnel resources, DNS record, secret and deployment. Nothing existing should change or be replaced. If a Phase 3 resource shows `must be replaced`, stop and send me the plan.

## Verify
```bash
kubectl -n cloudflare get pods
kubectl -n cloudflare logs deploy/cloudflared | tail      # "Registered tunnel connection"
curl -I https://shop.webfranzresume.click
```
DNS for the new record normally resolves within minutes once the zone is Active.

## Gotchas
- **`cloudflared:latest` is a mutable tag.** Fine for a lab, but pin a version for anything serious.
- **The token is in state.** `tunnel_token` is stored in `terraform.tfstate` and in the Kubernetes secret. Keep state gitignored and backed up off the VM.
- **Rolled tokens:** a rolled or deleted API token breaks `terraform plan`. Update `TF_VAR_cloudflare_api_token`. It doesn't affect the running tunnel, which uses its own token.
- **Public exposure:** the store is now on the internet with no authentication. The ingress forwards every path to the frontend, so the frontend's own `/metrics` and `/healthz` are public too. Consider Cloudflare Access, or restricting paths, later. The `/chaos` endpoints are not reachable, since they live on the backend services, which the frontend doesn't proxy.
- **NodePort 30080** is still open on the VM. It can be removed once the tunnel works.
- **Destroying:** `terraform destroy` removes the DNS record and tunnel too.
