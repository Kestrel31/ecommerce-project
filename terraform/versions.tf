terraform {
  required_version = ">= 1.6"

  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
    null       = { source = "hashicorp/null", version = "~> 3.2" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 4.40" }
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
