# Phase 3: Terraform

Terraform now owns the cluster foundations, and `deploy.sh` only handles the app.

| Owned by Terraform | Owned by `deploy.sh` |
|--------------------|----------------------|
| K3s install (skipped if present) | Docker builds and image import |
| 5 namespaces | `kubectl apply -k k8s` |
| `db-credentials` and `api-db` secrets | Rollout restart and wait |
| DB password (`random_password`) | |

Cloudflare resources (tunnel, DNS) move to Phase 4, next to the `cloudflared` deployment that uses them.

## Layout
```
terraform/
  versions.tf    providers: kubernetes, random, null
  variables.tf   kubeconfig path, namespace set
  main.tf        K3s install, namespaces, password, secrets
  outputs.tf
```

## How it works
- **K3s:** a `null_resource` runs the install script only if `k3s` isn't on the PATH. Terraform doesn't track K3s's version or state beyond that.
- **Namespaces:** `for_each` over a set, so adding a namespace is a one-word change in `variables.tf`.
- **Password:** `random_password` generates it once and keeps it in state. Both secrets derive from it, so they can't drift apart.
- **Order:** namespaces depend on the K3s install, and secrets depend on their namespace.

## State and secrets
The password is stored in `terraform.tfstate`. It is gitignored (along with `*.tfvars`), so keep it that way. State is local and lives on the VM, so back it up. If you lose it, Terraform forgets the password it generated.

## Run on a fresh cluster
```bash
cd terraform
terraform init
terraform apply
cd .. && ./scripts/deploy.sh
```

## Migrating the existing cluster (Phase 2 resources already exist)
A plain `apply` fails because the namespaces and secrets exist. It would also generate a new password that doesn't match the one stored in the Postgres volume. Import the existing resources and password instead:

```bash
cd terraform
terraform init

# the existing password, so Postgres keeps working
PW=$(kubectl -n data get secret db-credentials -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
terraform import random_password.db "$PW"

for ns in web data cart payment ads; do
  terraform import "kubernetes_namespace_v1.ns[\"$ns\"]" $ns
done
terraform import kubernetes_secret_v1.db_credentials data/db-credentials
terraform import kubernetes_secret_v1.api_db web/api-db

terraform plan    # should show no changes, or only the null_resource
terraform apply
```
Check the plan before applying. If it proposes replacing a namespace, stop, because that would delete everything in it.

## Gotchas
- **Namespaces are no longer in `k8s/`.** `namespaces.yaml` was removed. `deploy.sh` checks that the secrets exist and tells you to run Terraform if they don't.
- **Destroying is dangerous.** `terraform destroy` deletes the namespaces, and with them the Postgres data.
- **Rotating the password** (`terraform apply -replace=random_password.db`) updates the secrets but not the password inside Postgres, so the API would lose access.
- **First run on a fresh VM:** the Kubernetes provider reads the kubeconfig while planning, and K3s creates that file during apply. If the first `apply` complains about it, run `terraform apply -target=null_resource.k3s` and then a full `apply`.
- **Terraform runs on the VM.** Pull the code there, as in your usual workflow.
