# 1. K3s (skipped if already installed)
resource "null_resource" "k3s" {
  provisioner "local-exec" {
    command = <<-EOT
      if ! command -v k3s >/dev/null 2>&1; then
        curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
      fi
    EOT
  }
}

# 2. Namespaces
resource "kubernetes_namespace_v1" "ns" {
  for_each   = var.namespaces
  depends_on = [null_resource.k3s]

  metadata { name = each.key }
}

# 3. Database credentials. The password lives in Terraform state (gitignored), not in git.
resource "random_password" "db" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "db_credentials" {
  metadata {
    name      = "db-credentials"
    namespace = kubernetes_namespace_v1.ns["data"].metadata[0].name
  }
  data = {
    POSTGRES_USER     = "shop"
    POSTGRES_DB       = "shop"
    POSTGRES_PASSWORD = random_password.db.result
  }
}

resource "kubernetes_secret_v1" "api_db" {
  metadata {
    name      = "api-db"
    namespace = kubernetes_namespace_v1.ns["web"].metadata[0].name
  }
  data = {
    DATABASE_URL = "postgres://shop:${random_password.db.result}@postgres.data:5432/shop"
  }
}
