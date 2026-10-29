variable "kubeconfig" {
  description = "Path to the K3s kubeconfig"
  type        = string
  default     = "/etc/rancher/k3s/k3s.yaml"
}

variable "namespaces" {
  description = "One namespace per tier / microservice"
  type        = set(string)
  default     = ["web", "data", "cart", "payment", "ads", "cloudflare"]
}

variable "cloudflare_api_token" {
  description = "Scoped token (Account: Cloudflare Tunnel Edit, Zone: DNS Edit). Set via TF_VAR_cloudflare_api_token, never in a file."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  type = string
}

variable "cloudflare_zone_id" {
  type = string
}

variable "hostname" {
  description = "Public hostname for the store"
  type        = string
  default     = "shop.webfranzresume.click"
}

variable "cloudflared_image" {
  type    = string
  default = "cloudflare/cloudflared:latest"
}
