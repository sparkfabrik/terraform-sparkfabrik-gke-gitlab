# Tasks

## 1. Providers and inputs

- [x] 1.1 Add `alekc/kubectl` to `required_providers`, raise `required_version` to `>= 1.3`, and add a `provider "kubectl"` block in `main.tf` using the same host, token and CA as `kubernetes` with `load_config_file = false`; verify `terraform init -upgrade` and `terraform validate` pass
- [x] 1.2 Add the inputs `gke_gateway_api_channel` (validated to `null`, `CHANNEL_STANDARD`, `CHANNEL_DISABLED`), `gitlab_proxy_only_subnet_cidr`, `gitlab_gateway_certificate_enabled`, `gitlab_gke_gateway` and `gitlab_shell_load_balancer`, all defaulting to off; verify `terraform validate` passes and `CHANNEL_EXPERIMENTAL` fails validation
- [x] 1.3 Add a `terraform_data` resource with `precondition` blocks for the NGINX conflict, the GKE Gateway prerequisites and the chart 10.3 minimum; verify each invalid combination fails `terraform plan` against the example with an error naming the inputs involved
- [ ] 1.4 Pass `gke_gateway_api_channel` to `module.gke` as `gateway_api_channel`; verify the example plan sets `gateway_api_config` to `CHANNEL_STANDARD` when the input is set, and shows no change when it is `null`

## 2. Network and certificate

- [ ] 2.1 Create the `REGIONAL_MANAGED_PROXY` subnet (role `ACTIVE`) when `gitlab_proxy_only_subnet_cidr` is set, with no module firewall rule; verify in the scratch project that the subnet is `ACTIVE` and that GKE's `gkegw1-*-l7-*` rule lists its range once the Gateway exists
- [x] 2.2 Build the certificate host list (`gitlab`, KAS when installed, registry when enabled) and create one regional `PER_PROJECT_RECORD` DNS authorization per host plus one regional managed certificate, when `gitlab_gateway_certificate_enabled` is true; verify the plan lists exactly the expected hosts for KAS on and registry off
- [ ] 2.3 Add the `gitlab_gateway_certificate_dns_records` output (map of host to `name`, `type`, `data`) with a description warning that records must be updated if an authorization is replaced; verify in the scratch project that creating the output records makes the certificate `ACTIVE` while DNS for the hosts points elsewhere
- [x] 2.4 Document the new network and certificate inputs and the output in `README.md` with `make generate_docs`; verify the generated tables list them

## 3. Envoy CRDs

- [x] 3.1 Add `data "helm_template"` rendering the `gitlab` chart at `var.helm_chart_version` with the module's values, `envoy-gateway.crds.enabled=true` and `include_crds = true`, only when the gateway API and Envoy inputs are both true; verify the data source is absent from the default-input plan
- [x] 3.2 Filter the rendered documents to `CustomResourceDefinition` objects in `gateway.envoyproxy.io`, keyed by name, and apply each with `kubectl_manifest` (`server_side_apply = true`, `force_conflicts = true`); verify chart 10.4.3 yields exactly the 8 Envoy CRDs and no `gateway.networking.k8s.io` CRD
- [ ] 3.3 Set `envoy-gateway.crds.enabled=false` in `values.yaml` and add the CRD resources to `helm_release.gitlab` `depends_on`; verify in the scratch project that a first apply installs the CRDs before the release, with no GKE admission denial
- [ ] 3.4 Verify in the scratch project that raising `helm_chart_version` to a release bundling a newer Envoy updates the CRDs in the same apply, and that disabling Envoy removes the release's Envoy resources before the CRDs without errors

## 4. Chart values for the Gateway path

- [x] 4.1 When `gitlab_gke_gateway` is set, set `gatewayApiResources.gateway.protocol: HTTP`, set the chart's Envoy Service to `type: ClusterIP` through `gatewayApiResources.envoy.proxySpec`, and keep `global.gatewayApi.configureCertmanager` false; verify `helm template` output shows HTTP listeners without `tls` and an `EnvoyProxy` with a ClusterIP Service
- [ ] 4.2 Create the `gitlab-envoy-http` and `gitlab-envoy-h2c` ClusterIP Services selecting the Envoy pods by their owning-gateway labels, the second with `appProtocol: kubernetes.io/h2c`; verify in the scratch project that both Services have the Envoy pods as endpoints
- [ ] 4.3 Override `gitlab.webservice.clientTrafficPolicy.main.spec` with the chart default plus client IP detection trusting the load balancer hops, and set `workhorse.trustedCIDRsForXForwardedFor` to the proxy-only subnet and the GitLab IP `/32`; verify in the scratch project that GitLab logs the client's public IP and generates `https` URLs
- [x] 4.4 Set `gitlab-shell.gatewayRoute.enabled=false` when `gitlab_shell_load_balancer` is true; verify `helm_template` output contains no `TCPRoute`
- [x] 4.5 Make `global.ingress.configureCertmanager` follow `gitlab_enable_certmanager`; verify the default-input plan shows no change to the release values
- [x] 4.6 Add `gitlab_enable_ingress` (default `true`) driving `global.ingress.enabled`, document it in `README.md` and set it to `false` in the example; verify the default release values are unchanged and `helm template` renders no Ingress when it is `false`

## 5. GKE Gateway resources

- [ ] 5.1 Create the Gateway (`gke-l7-regional-external-managed`, `NamedAddress` on the GitLab address, HTTPS 443 with `networking.gke.io/cert-manager-certs`, HTTP 80) with `kubectl_manifest`; verify in the scratch project that the Gateway is `Programmed` on the GitLab IP
- [ ] 5.2 Create the HTTPRoutes: the HTTP 80 redirect, the GitLab and registry hosts to `gitlab-envoy-http`, and the KAS host split by `Upgrade: websocket` between `gitlab-envoy-http` and `gitlab-envoy-h2c`; verify `curl http://<host>/explore` redirects to HTTPS and `/api/v4/projects/group%2Fproject` reaches GitLab unchanged
- [ ] 5.3 Create the HealthCheckPolicy (`/ready`, `19003`) and the GCPBackendPolicy (timeout, optional security policy); verify the backends report healthy, and that a deny rule in a scratch regional policy returns 403 while a clean request returns 200
- [ ] 5.4 Verify in the scratch project that a GitLab agent connects to KAS over WebSocket, that a gRPC call to KAS returns `grpc-status: 0`, and that with `backend_timeout_sec` lowered to 120 the agent reconnects on its own after the connection is cut
- [x] 5.5 Document `gitlab_gke_gateway` in `README.md` with `make generate_docs`, including the prerequisites the preconditions enforce; verify the generated table lists it

## 6. SSH load balancer

- [ ] 6.1 Create a Service of type `LoadBalancer` for GitLab Shell on port 22 with `loadBalancerClass: networking.gke.io/l4-regional-external` and the GitLab IP, when `gitlab_shell_load_balancer` is true; verify in the scratch project that `git clone` over SSH works on the GitLab IP while the Gateway serves 443 on the same IP
- [x] 6.2 Document `gitlab_shell_load_balancer` in `README.md` with `make generate_docs`; verify the generated table lists it

## 7. Example, changelog and integration checks

- [x] 7.1 Add an example under `examples/` that enables the full Gateway path, with a regional Cloud Armor policy created in the example; verify `terraform validate` and `make docker_test_lint` pass
- [x] 7.2 Add `CHANGELOG.md` entries under `## [Unreleased]`: the new inputs and output, the `alekc/kubectl` provider and lock file update, the `required_version` change, the CRD ownership move for consumers who already enabled Envoy, and the `configureCertmanager` fix; verify the entries follow Keep a Changelog
- [ ] 7.3 Deploy the example in the scratch project end to end following the migration plan steps 2 and 3, then destroy it and confirm no resources remain
- [ ] 7.4 Run `terraform plan` of `gitlab-platform` against this branch with default inputs and confirm it shows no changes

## Workflow follow-up

- Get platform team approval on the input design, as required by sparkfabrik-innovation-team/board#5223, before publishing the release.
- Archive the change after the release is published.
