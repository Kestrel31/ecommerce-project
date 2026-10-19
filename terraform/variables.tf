variable "kubeconfig" {
  description = "Path to the K3s kubeconfig"
  type        = string
  default     = "/etc/rancher/k3s/k3s.yaml"
}

variable "namespaces" {
  description = "One namespace per tier / microservice"
  type        = set(string)
  default     = ["web", "data", "cart", "payment", "ads"]
}
