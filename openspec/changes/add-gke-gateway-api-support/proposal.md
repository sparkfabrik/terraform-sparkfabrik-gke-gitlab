# Proposal

## Why

The module can only expose GitLab through the bundled NGINX Ingress on a passthrough Network Load Balancer, which Cloud Armor cannot protect. The bundled NGINX is deprecated in GitLab 19 and removed in GitLab 20.0. sparkfabrik-innovation-team/board#5223 asks for a release that can put GitLab behind a Google regional Application Load Balancer with Cloud Armor, in front of the chart's bundled Envoy Gateway, while existing NGINX deployments keep working unchanged.

The spike in sparkfabrik-innovation-team/board#5221 recommended going ahead and listed the design changes this proposal adopts.

## What Changes

- **Gateway API on the cluster.** The module can enable the GKE Gateway API standard channel.
- **Proxy-only subnet.** The module can create the regional proxy-only subnet. The GKE Gateway controller creates the firewall rule from it to the cluster.
- **Regional load balancer for HTTPS.** The module can create a GKE Gateway of class `gke-l7-regional-external-managed` on the existing GitLab IP. It routes to the bundled Envoy Gateway with a health check, a backend timeout and an optional Cloud Armor policy that the consumer creates and passes by name.
- **TLS certificate.** The module can create a regional Google-managed Certificate Manager certificate for the hosts GitLab serves, through its own input, so it can become active while NGINX still serves traffic. Each host gets a DNS authorization, and the module outputs the CNAME records the DNS owner must create.
- **HTTP redirect.** Plain HTTP on port 80 redirects to HTTPS, as NGINX does today.
- **Envoy Gateway CRDs.** The module installs the Envoy Gateway CRDs taken from the configured GitLab chart version, with server-side apply, and keeps them in step on chart upgrades. GKE supplies the Gateway API CRDs.
- **Envoy and Workhorse settings.** Envoy keeps encoded slashes unchanged and trusts the load balancer's forwarded headers. Workhorse trusts `X-Forwarded-For` from the proxy-only subnet and the load balancer IP. The load balancer reaches Envoy over HTTP/1.1 for KAS WebSocket and over HTTP/2 for KAS gRPC.
- **SSH.** The module can expose GitLab Shell on its own regional L4 `LoadBalancer` Service on the same IP.
- **Defaults unchanged.** All new inputs default to off. A plan with default inputs shows no changes for existing deployments.
- **cert-manager follows its input.** The chart's Ingress cert-manager setting follows `gitlab_enable_certmanager`, so consumers can remove cert-manager after moving to the Gateway.
- **Ingress toggle.** A new input turns off the chart's Ingress resources, which nothing serves once GitLab runs behind the Gateway.
- **New provider.** The module requires the `alekc/kubectl` provider. Consumers do not configure it, but must update their dependency lock file.

## Capabilities

### New Capabilities

- `gateway-https-exposure`: exposing GitLab HTTPS traffic (web, API, git over HTTP, KAS) through a GKE regional Application Load Balancer and the bundled Envoy Gateway, including the certificate, Cloud Armor attachment, client IP and protocol handling.
- `envoy-gateway-crds`: installing and upgrading the Envoy Gateway CRDs that the bundled Envoy Gateway requires on a cluster where GKE manages the Gateway API CRDs.
- `gitlab-shell-load-balancer`: exposing GitLab Shell (SSH) on its own regional L4 load balancer that shares the GitLab IP.

### Modified Capabilities

None. The project has no existing specs.

## Impact

- **Code:** `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `values.yaml`, `README.md`, `CHANGELOG.md`, and a new example under `examples/`.
- **Dependencies:** a new required provider, `alekc/kubectl`. Consumers must run `terraform init -upgrade` and commit their lock file.
- **Consumers:** no plan changes with default inputs. Consumers opting in must create a regional Cloud Armor policy, create the certificate CNAME records in their DNS zone, and disable the NGINX Ingress, since it holds the same IP.
- **Out of scope:** the Cloud Armor rules (sparkfabrik-innovation-team/board#5224), the production cutover and removal of the old forwarding rule (sparkfabrik-innovation-team/board#5225, sparkfabrik-innovation-team/board#5226), and the DNS records themselves.
