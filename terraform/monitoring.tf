# Prometheus + Grafana via kube-prometheus-stack, trimmed for a 12 GB VM.
# PodMonitor / PrometheusRule / dashboard live in k8s/monitoring (applied by deploy.sh)
# because their CRDs only exist after this chart is installed.

resource "random_password" "grafana" {
  length  = 24
  special = false
}

resource "kubernetes_secret_v1" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.ns["monitoring"].metadata[0].name
  }
  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana.result
  }
}

resource "helm_release" "monitoring" {
  name       = "monitoring"
  namespace  = kubernetes_namespace_v1.ns["monitoring"].metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_version
  timeout    = 600

  values = [yamlencode({
    alertmanager = { enabled = false }

    # K3s embeds these components, so their endpoints aren't scrapeable. Disable to avoid permanently-down targets.
    kubeEtcd              = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeControllerManager = { enabled = false }
    kubeProxy             = { enabled = false }

    prometheus = {
      prometheusSpec = {
        retention = "3d"
        # Pick up PodMonitors / rules from any namespace, not only ones labelled with this release
        podMonitorSelectorNilUsesHelmValues     = false
        serviceMonitorSelectorNilUsesHelmValues = false
        ruleSelectorNilUsesHelmValues           = false
        resources = {
          requests = { cpu = "100m", memory = "400Mi" }
          limits   = { memory = "900Mi" }
        }
        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              accessModes = ["ReadWriteOnce"]
              resources   = { requests = { storage = "5Gi" } }
            }
          }
        }
      }
    }

    grafana = {
      admin = {
        existingSecret = kubernetes_secret_v1.grafana_admin.metadata[0].name
        userKey        = "admin-user"
        passwordKey    = "admin-password"
      }
      # Dashboards are loaded from ConfigMaps labelled grafana_dashboard=1
      sidecar = { dashboards = { enabled = true, label = "grafana_dashboard", searchNamespace = "ALL" } }
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "300Mi" }
      }
    }

    prometheus-node-exporter = {
      resources = { limits = { memory = "64Mi" } }
    }
    kube-state-metrics = {
      resources = { limits = { memory = "128Mi" } }
    }
  })]
}
