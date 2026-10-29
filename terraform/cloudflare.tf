# Tunnel: outbound-only connection from the VM to Cloudflare. No inbound ports needed.
resource "random_id" "tunnel_secret" {
  byte_length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "shop" {
  account_id = var.cloudflare_account_id
  name       = "ecommerce-k3s"
  secret     = random_id.tunnel_secret.b64_std
}

# Ingress rules are managed remotely by Cloudflare; cloudflared only needs the token.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "shop" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.shop.id

  config {
    ingress_rule {
      hostname = var.hostname
      service  = "http://frontend.web:8080"
    }
    ingress_rule {
      service = "http_status:404"
    }
  }
}

# shop.<domain> -> tunnel. Only this record is created; existing records (e.g. www) are untouched.
resource "cloudflare_record" "shop" {
  zone_id = var.cloudflare_zone_id
  name    = var.hostname
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.shop.id}.cfargotunnel.com"
  proxied = true
}

resource "kubernetes_secret_v1" "tunnel_token" {
  metadata {
    name      = "tunnel-token"
    namespace = kubernetes_namespace_v1.ns["cloudflare"].metadata[0].name
  }
  data = {
    TUNNEL_TOKEN = cloudflare_zero_trust_tunnel_cloudflared.shop.tunnel_token
  }
}

resource "kubernetes_deployment_v1" "cloudflared" {
  metadata {
    name      = "cloudflared"
    namespace = kubernetes_namespace_v1.ns["cloudflare"].metadata[0].name
  }

  spec {
    replicas = 1
    selector { match_labels = { app = "cloudflared" } }

    template {
      metadata { labels = { app = "cloudflared" } }

      spec {
        security_context {
          run_as_non_root = true
          run_as_user     = 65532
          seccomp_profile { type = "RuntimeDefault" }
        }

        container {
          name  = "cloudflared"
          image = var.cloudflared_image
          args  = ["tunnel", "--no-autoupdate", "--metrics", "0.0.0.0:2000", "run"]

          env_from {
            secret_ref { name = kubernetes_secret_v1.tunnel_token.metadata[0].name }
          }

          readiness_probe {
            http_get {
              path = "/ready"
              port = 2000
            }
          }

          liveness_probe {
            http_get {
              path = "/ready"
              port = 2000
            }
            initial_delay_seconds = 10
          }

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { memory = "96Mi" }
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities { drop = ["ALL"] }
          }
        }
      }
    }
  }
}
