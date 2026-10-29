# Design

## Context

See proposal.md for motivation. The facts below shape the approach.

- The module creates the GKE cluster (`terraform-google-modules/kubernetes-engine` `beta-private-cluster` v37, which accepts `gateway_api_channel`), the VPC, the regional GitLab address and the `gitlab` Helm release. It configures its own `helm` and `kubernetes` providers against `module.gke`, so consumers do not configure them.
- The module creates no DNS records. It outputs `gitlab_address` and the zone owner creates records elsewhere.
- Production today serves two hosts, `gitlab.<domain>` and `kas.gitlab.<domain>`. Each has its own Let's Encrypt certificate issued by cert-manager through HTTP-01 on NGINX. The registry is disabled. NGINX's `LoadBalancer` Service holds the GitLab IP on ports 80, 443 and 22.
- GitLab chart 10.4.3 bundles Envoy Gateway 1.9.1 as the `envoy-gateway` subchart. Its CRDs live in one Helm `crds/` directory that mixes 13 experimental Gateway API CRDs with 8 Envoy CRDs, behind the single switch `envoy-gateway.crds.enabled`. GKE's `enforce-gateway-standard-channel` admission policy denies the experimental CRDs, and GKE recreates the policy if it is deleted.
- The chart creates Envoy resources (`EnvoyProxy`, `ClientTrafficPolicy`, `BackendTrafficPolicy`, `SecurityPolicy`) that need the Envoy CRDs. Helm installs `crds/` only on first install and never upgrades it.
- The chart's Gateway listeners (`gitlab-web`, `kas-web`, and others) default to TLS termination with their own certificates. The shell `TCPRoute` is controlled by `gitlab-shell.gatewayRoute.enabled`. The webservice listener policy is `gitlab.webservice.clientTrafficPolicy.main.spec`, which already sets `escapedSlashesAction: KeepUnchanged`.
- Spike findings (sparkfabrik-innovation-team/board#5221): the regional load balancer keeps `%2F`; Envoy's default redirects it unless `KeepUnchanged` applies on the receiving listener; the load balancer sends `X-Forwarded-For: <client>, <LB IP>, <proxy-only address>`; Envoy rewrites `X-Forwarded-Proto` to `http` unless it trusts the load balancer; KAS WebSocket fails over an H2C backend and gRPC needs one; the load balancer must health-check Envoy on `/ready`, port `19003`; a Gateway and an L4 `LoadBalancer` Service can share one regional IP.

## Goals / Non-Goals

**Goals:**

- Each new resource is opt-in and created with `count` or `for_each`, so default inputs plan no changes.
- One mechanism (`alekc/kubectl`, server-side apply) for every Kubernetes object whose CRD may not exist at plan time.
- Stages that match the migration: the certificate can exist while NGINX still serves traffic, and the Gateway and SSH load balancer arrive in the cutover apply.

**Non-Goals:**

- Creating or tuning the Cloud Armor policy, or any DNS record.
- Removing cert-manager or NGINX automatically. Consumers turn them off with existing inputs.
- Supporting the Gateway API experimental channel, Pages, smartcard or Geo hosts on the GKE Gateway.
- Shared VPC networks. GKE does not create its Gateway firewall rule there, and this module always creates its own VPC.

## Decisions

### Inputs

| Input                                | Type and default                                                                                       | Effect                                                                                                                                                                                    |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gke_gateway_api_channel`            | `string`, `null`                                                                                       | Passed to the GKE module's `gateway_api_channel`. Validated to `null`, `CHANNEL_STANDARD` or `CHANNEL_DISABLED`.                                                                          |
| `gitlab_proxy_only_subnet_cidr`      | `string`, `null`                                                                                       | Creates a `REGIONAL_MANAGED_PROXY` subnet (role `ACTIVE`).                                                                                                                                |
| `gitlab_gateway_certificate_enabled` | `bool`, `false`                                                                                        | Creates the DNS authorizations, the regional certificate and the records output. Allowed while NGINX runs.                                                                                |
| `gitlab_gke_gateway`                 | `object({ security_policy = optional(string), backend_timeout_sec = optional(number, 3600) })`, `null` | Creates the GKE Gateway, routes and policies, and switches the chart's Envoy listeners to plain HTTP.                                                                                     |
| `gitlab_shell_load_balancer`         | `bool`, `false`                                                                                        | Creates the SSH `LoadBalancer` Service and turns off the chart's shell `TCPRoute`.                                                                                                        |
| `gitlab_enable_ingress`              | `bool`, `true`                                                                                         | Drives `global.ingress.enabled`. Set to `false` on the Gateway path, so the chart stops rendering Ingresses that no controller serves and cert-manager stops renewing their certificates. |

New output: `gitlab_gateway_certificate_dns_records`, a map keyed by host with `name`, `type` and `data`.

**Why a separate certificate input:** the certificate must be `ACTIVE` before cutover, but the Gateway cannot exist while NGINX holds the IP. Tying the certificate to `gitlab_gke_gateway` would force the certificate to provision during the outage. Alternative considered: one `gitlab_gke_gateway` object with a nested `create_gateway` flag. Rejected because a separate boolean reads more clearly in the consumer's diff.

### Envoy CRDs from the GitLab chart

When `gitlab_enable_gateway_api` and `gitlab_gateway_api_install_envoy` are both true:

1. `data "helm_template"` renders the same `gitlab` chart at `var.helm_chart_version` with the module's real values plus `envoy-gateway.crds.enabled=true` and `include_crds = true`. Placeholder values fail the chart's configuration checks, so the real values are required.
2. The module splits the rendered manifest into documents and keeps only `CustomResourceDefinition` objects whose `spec.group` is `gateway.envoyproxy.io`, keyed by name.
3. `kubectl_manifest` applies each with `server_side_apply = true` and `force_conflicts = true`. Force is needed because releases that installed Envoy before this change own those CRDs through Helm.
4. The real release sets `envoy-gateway.crds.enabled=false`, and `helm_release.gitlab` depends on the CRD resources. Terraform therefore upgrades the release before the CRDs and removes the release's Envoy resources before deleting the CRDs.

Alternatives considered:

- **Let the chart own the CRDs.** Blocked: the single switch includes experimental Gateway API CRDs that GKE denies, and Helm never upgrades `crds/`.
- **Commit the CRDs into the module.** Plans run offline, but every Envoy bump in the chart needs a module release, and two version sources can drift.
- **`gateway-crds-helm` as its own Helm release.** The Envoy-only set is about 83% of the 1 MiB release limit, which leaves little headroom for growth.
- **`gavinbunney/kubectl`.** Unmaintained. `alekc/kubectl` is the maintained fork.

### Kubernetes objects for the GKE Gateway

All are `kubectl_manifest` resources with server-side apply in the GitLab namespace, created when `gitlab_gke_gateway` is set. Services use server-side apply too, because GKE writes NEG and load balancer annotations on them, which a `kubernetes_service` would report as drift on every plan. The SSH `LoadBalancer` Service follows the same rule.

- **Gateway** of class `gke-l7-regional-external-managed`, `spec.addresses` set to the GitLab address by name (`NamedAddress`). An HTTPS listener on 443 uses `tls.options` `networking.gke.io/cert-manager-certs: <certificate name>`. A regional Gateway does not use a certificate map. An HTTP listener on 80 serves a redirect to HTTPS, keeping NGINX's port 80 behavior.
- **Two Envoy backend Services** of type ClusterIP that select the Envoy pods by Envoy Gateway's owning-gateway labels. Both target the same Envoy container port. `gitlab-envoy-http` has no `appProtocol`, so the load balancer speaks HTTP/1.1, and `gitlab-envoy-h2c` sets `appProtocol: kubernetes.io/h2c`.
- **HTTPRoutes:** the HTTP listener redirects to HTTPS. The GitLab host and the registry host (when enabled) go to `gitlab-envoy-http`. The KAS host sends requests with `Upgrade: websocket` to `gitlab-envoy-http`, and everything else to `gitlab-envoy-h2c`.
- **HealthCheckPolicy** on both Services: HTTP `/ready` on port `19003`.
- **GCPBackendPolicy** on both Services: `timeoutSec` from `backend_timeout_sec`, and `securityPolicy` from `security_policy` when set.

**Why module-owned Services:** the chart gives every HTTP listener port 80, so Envoy exposes one HTTP port, and a Service port carries a single `appProtocol`. Two Services on the same pods let the load balancer use HTTP/1.1 for WebSocket and H2C for gRPC. They also avoid depending on the hashed name of the Service Envoy Gateway generates. Alternative considered: a fixed name and two ports through `EnvoyProxy`. Rejected because the chart cannot render a second HTTP listener port. The Envoy pods run in the GitLab namespace with the routes, so no ReferenceGrant is needed; the scratch test confirms the namespace and the container port.

### Envoy and chart values

Passed through `values.yaml` when `gitlab_gke_gateway` is set:

- `gatewayApiResources.gateway.protocol` is `HTTP`, so every chart listener without its own protocol (`gitlab-web`, `kas-web`, `registry-web`) is plain HTTP on port 80 without `tls`, because TLS ends at the load balancer. The section-scoped `ClientTrafficPolicy` still targets `gitlab-web`, so `KeepUnchanged` applies on the listener that receives traffic.
- `gatewayApiResources.envoy.proxySpec` sets the chart's Envoy Service to `type: ClusterIP`. The chart default, `LoadBalancer`, would create a second L4 load balancer with an ephemeral IP.
- The webservice `clientTrafficPolicy.main.spec` is set to the chart default plus client IP detection that trusts the load balancer hops, so Envoy keeps the forwarded client IP and `X-Forwarded-Proto: https`. The exact field is confirmed in the scratch test.
- `gitlab.webservice.workhorse.trustedCIDRsForXForwardedFor` lists the proxy-only subnet and the GitLab IP as `/32`.
- `global.gatewayApi.configureCertmanager` stays `false`.
- `global.ingress.configureCertmanager` follows `gitlab_enable_certmanager`, instead of the hardcoded `true`.

### Proxy-only subnet firewall

The module creates no firewall rule. When the first Gateway exists, the GKE Gateway controller creates `gkegw1-*-l7-<network>-<region>`, which allows TCP from `35.191.0.0/16`, `130.211.0.0/22` and the proxy-only subnet to the whole VPC. The spike project showed this rule carrying all load balancer traffic. Its hand-made rules targeted a tag the nodes did not have. Production's `gitlab` VPC is not a Shared VPC, the only case where GKE skips the rule. Trade-off: the GKE rule opens all TCP ports from the proxy-only subnet, which only Google's load balancer proxies use. Alternative considered: a module rule limited to Envoy's ports. Rejected as redundant, and it would need Envoy's container port hardcoded.

### Validations

Cross-input checks use `precondition` blocks on a `terraform_data` resource, because `variable` validation in Terraform before 1.9 cannot reference other inputs:

- `gitlab_gke_gateway` or `gitlab_shell_load_balancer` require `gitlab_install_ingress_nginx = false`.
- `gitlab_gke_gateway` requires `gke_gateway_api_channel = "CHANNEL_STANDARD"`, `gitlab_proxy_only_subnet_cidr`, `gitlab_gateway_certificate_enabled`, `gitlab_enable_gateway_api` and `gitlab_gateway_api_install_envoy`.
- Either feature requires `helm_chart_version` 10.3 or later, compared on the major and minor numbers.

### Providers

`versions.tf` adds `alekc/kubectl`. `main.tf` adds `provider "kubectl"` with the same host, token and CA as `kubernetes`, and `load_config_file = false`. `required_version` rises to `>= 1.3`, for `optional()` object attributes and `precondition`.

### Certificate hosts

The host list is built from the module's own settings: `gitlab.<domain>`, the KAS host when `gitlab_install_kas` is true (`local.kas_domain`, or `kas.<domain>` when empty), and `registry.<domain>` when `gitlab_enable_registry` is true. Each host has one `google_certificate_manager_dns_authorization` (`location = var.region`, `type = "PER_PROJECT_RECORD"`), named from the host so it is not replaced by unrelated changes.

## Risks / Trade-offs

- **Plan needs network access** → When Envoy is enabled, every plan downloads the chart from `charts.gitlab.io` for `helm_template`. The real release already does this at apply time, and the data source is skipped when Envoy is disabled.
- **First apply with no cluster** → The `helm` provider's settings are unknown until the cluster exists. `helm_template` should not contact the cluster. The scratch test confirms a single-apply create.
- **Taking CRDs over from Helm** → `force_conflicts` moves field ownership of Envoy CRDs from a release that already installed them to Terraform. The CHANGELOG states this for consumers who enabled `gitlab_gateway_api_install_envoy`.
- **State size** → State holds about 2.5 MB of CRD YAML, and plans refresh it. That is acceptable for a module with one cluster.
- **Third-party provider** → `alekc/kubectl` has a single maintainer. The constraint pins a minor version, and the consumer's lock file holds the hashes.
- **DNS authorization replaced** → A replaced authorization changes the CNAME target, and the certificate fails at its next renewal. Names are derived only from the host, and the output description warns that records must be updated after a replacement.
- **Backend timeout is a hard limit** → `backend_timeout_sec` (default `3600`) is the total time the load balancer waits for a complete HTTP response, and the maximum lifetime of a WebSocket connection. NGINX's timeout only fires on idle connections. A git operation streaming for over an hour is cut off, and KAS agents reconnect once an hour. Google's 30-second default would break long clones, so the module sets 3600, and consumers with very large repositories can raise it. The scratch test confirms the agent reconnects cleanly.
- **Shared IP during cutover** → NGINX's forwarding rule covers ports 22 to 443 on the same IP. Validations stop both from being enabled together. The outage between removing NGINX and the Gateway taking the IP belongs to the runbook in sparkfabrik-innovation-team/board#5225.
- **GKE-managed Gateway API CRD version** → GKE may serve an older Gateway API than the chart expects. The module turns off the shell `TCPRoute`, and the GKE Gateway uses only `HTTPRoute`. If the chart renders another kind GKE lacks, the release fails at apply, and the scratch test exposes it.

## Migration Plan

For a consumer on NGINX, such as `gitlab-platform`:

1. Upgrade the module, run `terraform init -upgrade`, commit the lock file, and confirm the plan shows no changes.
2. Set `gke_gateway_api_channel = "CHANNEL_STANDARD"`, `gitlab_proxy_only_subnet_cidr` and `gitlab_gateway_certificate_enabled = true`, and apply. Add the output CNAME records in the DNS repo, then wait until the certificate is `ACTIVE`. NGINX keeps serving traffic.
3. Cutover apply: set `gitlab_install_ingress_nginx = false`, `gitlab_enable_ingress = false`, `gitlab_enable_gateway_api = true`, `gitlab_gateway_api_install_envoy = true`, `gitlab_gke_gateway` and `gitlab_shell_load_balancer = true`. Expect a short outage while the NGINX forwarding rule is released and the Gateway takes the IP.
4. Optional: set `gitlab_enable_certmanager = false` once no Ingress needs it.

Rollback: revert the step 3 inputs and apply. NGINX and cert-manager return, and the certificate stays in place for a later retry.
