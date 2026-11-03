variable "project_id" {
  type        = string
  description = "The project to run the example in"
}

variable "region" {
  type        = string
  description = "The region of the GitLab cluster, load balancer and certificate"
  default     = "europe-west1"
}

variable "domain" {
  type        = string
  description = "Domain for GitLab, served at gitlab.<domain> and kas.<domain>"
}

variable "proxy_only_subnet_cidr" {
  type        = string
  description = "CIDR of the proxy-only subnet. It must not overlap the GitLab VPC ranges."
  default     = "10.40.0.0/23"
}
