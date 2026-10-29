output "gitlab_url" {
  value       = module.gke_gitlab.gitlab_url
  description = "URL of the GitLab instance"
}

output "gitlab_address" {
  value       = module.gke_gitlab.gitlab_address
  description = "IP address to point the GitLab and KAS DNS records at"
}

output "gitlab_gateway_certificate_dns_records" {
  value       = module.gke_gitlab.gitlab_gateway_certificate_dns_records
  description = "CNAME records to create so the certificate becomes active"
}
