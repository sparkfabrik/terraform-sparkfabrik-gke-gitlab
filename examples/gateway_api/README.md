# GitLab behind a GKE Gateway

This example deploys GitLab behind a GKE regional Application Load Balancer with a Cloud Armor policy, in front of the chart's bundled Envoy Gateway. SSH runs on its own proxy Network Load Balancer on the same IP.

## Usage

1. Run `terraform init` and `terraform apply` with `project_id` and `domain` set.
2. Create the records from the `gitlab_gateway_certificate_dns_records` output in the DNS zone of `domain`, and wait until the certificate is active.
3. Point `gitlab.<domain>` and `kas.<domain>` at the `gitlab_address` output.

## Roll back to NGINX

Move a deployment from the GKE Gateway back to the NGINX Ingress in two applies. The Envoy Gateway controller must outlive the chart's Gateway: it is the controller that deletes the Envoy proxy and removes the finalizer from the `GatewayClass`.

1. Set `gitlab_install_ingress_nginx = true`, `gitlab_enable_ingress = true` and `gitlab_enable_gateway_api = false`, remove `gitlab_gke_gateway`, and set `gitlab_enable_shell_load_balancer = false`. Keep `gitlab_gateway_api_install_envoy = true`. Keep the Gateway API channel, the proxy-only subnet and the gateway certificate, so you can move back to the Gateway later.
2. Apply. GitLab is unavailable while the Gateway and the SSH load balancer release the IP and NGINX takes it over. The DNS records do not change, because every load balancer uses the same reserved address.
3. Check that the controller has cleaned up: both commands must return nothing.

   ```bash
   kubectl get gatewayclass gitlab-gw
   kubectl -n gitlab get deploy,svc,pdb,sa,cm -l gateway.envoyproxy.io/owning-gateway-name=gitlab-gw
   ```

4. Set `gitlab_gateway_api_install_envoy = false` and apply. The module leaves the Envoy Gateway CRDs in the cluster.

### Leftover objects

Helm does not delete the objects that the chart creates through hooks. After step 4 these stay in the GitLab namespace, and you can delete them:

- The ServiceAccount, Role and RoleBinding `gitlab-envoy-gateway-certgen`.
- The ClusterRole and ClusterRoleBinding `gitlab-envoy-gateway-certgen:gitlab`, named after the namespace.
- The Secrets `envoy`, `envoy-gateway`, `envoy-oidc-hmac` and `envoy-rate-limit`.

### If the controller was removed with the Gateway

Turning `gitlab_enable_gateway_api` and `gitlab_gateway_api_install_envoy` off in the same apply removes the controller before it can clean up. The `GatewayClass` then stays in `Terminating`, with the Envoy proxy Deployment, Service and PodDisruptionBudget it owns still running. Remove the finalizer, and Kubernetes deletes those objects:

```bash
kubectl patch gatewayclass gitlab-gw --type=json \
  -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

Do this before you enable the Gateway again. Otherwise the new controller removes the finalizer, and the class the chart recreates is deleted with it.
