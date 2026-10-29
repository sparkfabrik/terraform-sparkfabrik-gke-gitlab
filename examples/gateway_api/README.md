# GitLab behind a GKE Gateway

This example deploys GitLab behind a GKE regional Application Load Balancer with a Cloud Armor policy, in front of the chart's bundled Envoy Gateway. SSH runs on its own L4 load balancer on the same IP.

## Usage

1. Run `terraform init` and `terraform apply` with `project_id` and `domain` set.
2. Create the records from the `gitlab_gateway_certificate_dns_records` output in the DNS zone of `domain`, and wait until the certificate is active.
3. Point `gitlab.<domain>` and `kas.<domain>` at the `gitlab_address` output.
