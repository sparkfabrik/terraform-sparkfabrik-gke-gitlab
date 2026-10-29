provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# The consumer owns the Cloud Armor policy and passes its name to the module.
resource "google_compute_region_security_policy" "gitlab" {
  name        = "gitlab"
  region      = var.region
  description = "Cloud Armor policy for the GitLab GKE Gateway"
  type        = "CLOUD_ARMOR"
}

resource "google_compute_region_security_policy_rule" "block_sqli" {
  region          = var.region
  security_policy = google_compute_region_security_policy.gitlab.name
  priority        = 1000
  description     = "Block SQL injection"
  action          = "deny(403)"

  match {
    expr {
      expression = "evaluatePreconfiguredWaf('sqli-v33-stable')"
    }
  }
}

module "gke_gitlab" {
  source = "../../"

  project_id        = var.project_id
  region            = var.region
  domain            = var.domain
  certmanager_email = "no-reply@${var.domain}"
  gitlab_log_level  = "info"

  helm_chart_version = "10.4.3"
  gitlab_install_kas = true

  # Gateway API on GKE instead of the NGINX Ingress.
  gitlab_install_ingress_nginx       = false
  gitlab_enable_ingress              = false
  gitlab_enable_gateway_api          = true
  gitlab_gateway_api_install_envoy   = true
  gke_gateway_api_channel            = "CHANNEL_STANDARD"
  gitlab_proxy_only_subnet_cidr      = var.proxy_only_subnet_cidr
  gitlab_gateway_certificate_enabled = true
  gitlab_shell_load_balancer         = true

  gitlab_gke_gateway = {
    security_policy = google_compute_region_security_policy.gitlab.name
  }
}
