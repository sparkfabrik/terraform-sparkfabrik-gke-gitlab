# GitLab behind a GKE Gateway

This example deploys GitLab behind a GKE regional Application Load Balancer with a Cloud Armor policy, in front of the chart's bundled Envoy Gateway. SSH runs on its own proxy Network Load Balancer on the same IP.

## Usage

1. Run `terraform init` and `terraform apply` with `project_id` and `domain` set.
2. Create the records from the `gitlab_gateway_certificate_dns_records` output in the DNS zone of `domain`, and wait until the certificate is active.
3. Point `gitlab.<domain>` and `kas.<domain>` at the `gitlab_address` output.

## Roll back to NGINX

To move a deployment from the GKE Gateway back to the NGINX Ingress:

1. Set `gitlab_install_ingress_nginx = true`, `gitlab_enable_ingress = true`, `gitlab_enable_gateway_api = false` and `gitlab_gateway_api_install_envoy = false`, remove `gitlab_gke_gateway`, and set `gitlab_enable_shell_load_balancer = false`. Keep the Gateway API channel, the proxy-only subnet and the gateway certificate, so you can move back to the Gateway later.
2. Apply. GitLab is unavailable while the Gateway and the SSH load balancer release the IP and NGINX takes it over: on a test deployment, about 75 seconds for HTTPS and about 2 minutes for SSH. The DNS records do not change, because every load balancer uses the same reserved address.
3. Remove the leftover Envoy objects. The chart deletes the Envoy Gateway controller and its `GatewayClass` together, so the class keeps a finalizer that only the controller removes. It stays in `Terminating`, with the Envoy proxy Deployment, Service and PodDisruptionBudget it owns still running. Remove the finalizer, and Kubernetes then deletes those objects:

   ```bash
   kubectl patch gatewayclass gitlab-gw --type=json \
     -p='[{"op":"remove","path":"/metadata/finalizers"}]'
   ```

   Do this before you enable the Gateway again. Otherwise the new controller removes the finalizer, and the class the chart recreates is deleted with it.

The module keeps the Envoy Gateway CRDs in the cluster when Envoy is turned off.
