# Tasks

## 1. Providers and inputs

- [x] 1.1 Add `alekc/kubectl` to `required_providers`, raise `required_version` to `>= 1.4`, and add a `provider "kubectl"` block in `main.tf` using the same host, token and CA as `kubernetes` with `load_config_file = false`; verify `terraform init -upgrade` and `terraform validate` pass
- [x] 1.2 Add the inputs `gke_gateway_api_channel` (validated to `null`, `CHANNEL_STANDARD`, `CHANNEL_DISABLED`), `gke_proxy_only_subnet_cidr`, `gitlab_enable_gateway_certificate`, `gitlab_gke_gateway` and `gitlab_enable_shell_load_balancer`, all defaulting to off; verify `terraform validate` passes and `CHANNEL_EXPERIMENTAL` fails validation
- [x] 1.3 Add a `terraform_data` resource with `precondition` blocks for the NGINX conflict, the GKE Gateway prerequisites and the chart 10.3 minimum; verify each invalid combination fails `terraform plan` against the example with an error naming the inputs involved
- [x] 1.4 Pass `gke_gateway_api_channel` to `module.gke` as `gateway_api_channel`; verify the example plan sets `gateway_api_config` to `CHANNEL_STANDARD` when the input is set, and shows no change when it is `null`

## 2. Network and certificate

- [x] 2.1 Create the `REGIONAL_MANAGED_PROXY` subnet (role `ACTIVE`) when `gke_proxy_only_subnet_cidr` is set, with no module firewall rule; verify in the scratch project that the subnet is `ACTIVE` and that GKE's `gkegw1-*-l7-*` rule lists its range once the Gateway exists
- [x] 2.2 Build the certificate host list (`gitlab`, KAS when installed, registry when enabled) and create one regional `PER_PROJECT_RECORD` DNS authorization per host plus one regional managed certificate, when `gitlab_enable_gateway_certificate` is true; verify the plan lists exactly the expected hosts for KAS on and registry off
- [x] 2.3 Add the `gitlab_gateway_certificate_dns_records` output (map of host role, `gitlab`, `kas` or `registry`, to `host`, `name`, `type` and `data`) with a description warning that records must be updated if an authorization is replaced; verify in the scratch project that creating the output records makes the certificate `ACTIVE` while DNS for the hosts points elsewhere
- [x] 2.4 Document the new network and certificate inputs and the output in `README.md` with `make generate_docs`; verify the generated tables list them

## 3. Envoy CRDs

- [x] 3.1 Add `data "helm_template"` rendering the `gitlab` chart at `var.helm_chart_version` with a fixed set of placeholder values, `envoy-gateway.crds.enabled=true` and `include_crds = true`, only when the gateway API and Envoy inputs are both true; verify the data source is absent from the default-input plan
- [x] 3.2 Filter the rendered documents to `CustomResourceDefinition` objects in `gateway.envoyproxy.io`, keyed by name, and apply each with `kubectl_manifest` (`server_side_apply = true`, `force_conflicts = true`); verify chart 10.4.3 yields exactly the 8 Envoy CRDs and no `gateway.networking.k8s.io` CRD
- [x] 3.3 Set `envoy-gateway.crds.enabled=false` in `values.yaml` and add the CRD resources to `helm_release.gitlab` `depends_on`; verify in the scratch project that a first apply installs the CRDs before the release, with no GKE admission denial
- [ ] 3.4 Verify in the scratch project that raising `helm_chart_version` to a release bundling a newer Envoy updates the CRDs in the same apply, and that disabling Envoy updates the release without errors and leaves the CRDs in place

## 4. Chart values for the Gateway path

- [x] 4.1 When `gitlab_gke_gateway` is set, set `gatewayApiResources.gateway.protocol: HTTP`, set the chart's Envoy Service to `type: ClusterIP` through `gatewayApiResources.envoy.proxySpec`, and keep `global.gatewayApi.configureCertmanager` false; verify `helm template` output shows HTTP listeners without `tls` and an `EnvoyProxy` with a ClusterIP Service
- [x] 4.2 Create the `gitlab-envoy-http` and `gitlab-envoy-h2c` ClusterIP Services selecting the Envoy pods by their owning-gateway labels, the second with `appProtocol: kubernetes.io/h2c`; verify in the scratch project that both Services have the Envoy pods as endpoints
- [x] 4.3 Override `gitlab.webservice.clientTrafficPolicy.main.spec` with the chart default plus client IP detection trusting the load balancer hops, and set `workhorse.trustedCIDRsForXForwardedFor` to the proxy-only subnet and the GitLab IP `/32`; verify in the scratch project that GitLab logs the client's public IP and generates `https` URLs
- [x] 4.4 Set `gitlab-shell.gatewayRoute.enabled=false` when `gitlab_enable_shell_load_balancer` is true; verify `helm_template` output contains no `TCPRoute`
- [x] 4.5 Make `global.ingress.configureCertmanager` follow `gitlab_enable_certmanager`; verify the default-input plan shows no change to the release values
- [x] 4.6 Add `gitlab_enable_ingress` (default `true`) driving `global.ingress.enabled`, document it in `README.md` and set it to `false` in the example; verify the default release values are unchanged and `helm template` renders no Ingress when it is `false`

## 5. GKE Gateway resources

- [x] 5.1 Create the Gateway (`gke-l7-regional-external-managed`, `NamedAddress` on the GitLab address, HTTPS 443 with `networking.gke.io/cert-manager-certs`, HTTP 80) with `kubectl_manifest`; verify in the scratch project that the Gateway is `Programmed` on the GitLab IP
- [x] 5.2 Create the HTTPRoutes: the HTTP 80 redirect, the GitLab and registry hosts to `gitlab-envoy-http`, and the KAS host split by `Upgrade: websocket` between `gitlab-envoy-http` and `gitlab-envoy-h2c`; verify `curl http://<host>/explore` redirects to HTTPS and `/api/v4/projects/group%2Fproject` reaches GitLab unchanged
- [x] 5.3 Create the HealthCheckPolicy (`/ready`, `19003`) and the GCPBackendPolicy (timeout, optional security policy); verify the backends report healthy, and that a deny rule in a scratch regional policy returns 403 while a clean request returns 200
- [ ] 5.4 Verify in the scratch project that a GitLab agent connects to KAS over WebSocket, that a gRPC call to KAS returns `grpc-status: 0`, and that with `backend_timeout_sec` lowered to 120 the agent reconnects on its own after the connection is cut
- [x] 5.5 Document `gitlab_gke_gateway` in `README.md` with `make generate_docs`, including the prerequisites the preconditions enforce; verify the generated table lists it

## 6. SSH load balancer

- [x] 6.1 Create a Service of type `LoadBalancer` for GitLab Shell on port 22 with `loadBalancerClass: networking.gke.io/l4-regional-external` and the GitLab IP, when `gitlab_enable_shell_load_balancer` is true (replaced by section 9); verify in the scratch project that `git clone` over SSH works on the GitLab IP while the Gateway serves 443 on the same IP
- [x] 6.2 Document `gitlab_enable_shell_load_balancer` in `README.md` with `make generate_docs`; verify the generated table lists it

## 7. Example, changelog and integration checks

- [x] 7.1 Add an example under `examples/` that enables the full Gateway path, with a regional Cloud Armor policy created in the example; verify `terraform validate` and `make docker_test_lint` pass
- [x] 7.2 Add `CHANGELOG.md` entries under `## [Unreleased]`: the new inputs and output, the `alekc/kubectl` provider and lock file update, the `required_version` change, the CRD ownership move for consumers who already enabled Envoy, and the `configureCertmanager` fix; verify the entries follow Keep a Changelog
- [ ] 7.3 Deploy the example in the scratch project end to end following the migration plan steps 2 and 3, then destroy it and confirm no resources remain
- [x] 7.4 Run `terraform plan` of `gitlab-platform` against this branch with default inputs and confirm it shows no changes

## 8. Live test follow-ups

- [x] 8.1 Enable `certificatemanager.googleapis.com` with the module's project services when `gitlab_enable_gateway_certificate` is true, and create the DNS authorizations after it; verify a project without the API gets it enabled in the same apply
- [x] 8.2 Make the webservice ClientTrafficPolicy target the whole `gitlab-gw` Gateway, because Envoy Gateway rejects a policy on one of the plain HTTP listeners sharing port 80, and stop passing the GitLab IP as `global.hosts.externalIP`; verify `%2F` reaches GitLab unchanged, `/` redirects to `https` and Workhorse logs the client IP
- [x] 8.3 Require the `hashicorp/helm` provider `~> 3.3`, whose Helm library honours `null` overrides of subchart defaults; verify the test deployment migrates the `helm_release` state and plans no changes afterwards
- [x] 8.4 Set `gitlab.kas.clientTrafficPolicy.spec: null` behind the GKE Gateway, because chart 10.5 renders a rejected KAS policy that overrides the Gateway-wide one; verify only `gitlab-webservice-ctp` remains, accepted and not overridden
- [x] 8.5 Add `gitlab_gke_gateway.envoy_listener_mode`: `http` (default, chart 10.3 or later) also removes the chart's Gateway-wide policy, and `external_tls_termination` (chart 10.6 or later) uses `global.gatewayApi.externalTlsTermination` with the backends on container port 10443; verify the `http` mode plans only the values change on the test deployment, and render `external_tls_termination` against the chart's main branch
- [ ] 8.6 When chart 10.6.0 is released, upgrade the test deployment in `http` mode (covers 3.4 with the Envoy Gateway 1.10 CRDs), then switch to `external_tls_termination`; verify the checks of 4.3, 5.1 to 5.3 and 6.1 and measure the switch downtime
- [ ] 8.7 Rerun the `gitlab-platform` plan against the release with the `hashicorp/helm` 3.x constraint and syntax, and confirm default inputs show no changes
- [x] 8.8 Never delete the Envoy CRDs (`apply_only`): turning Envoy off destroyed them before the release update, which deletes every Envoy object and breaks the update; verify the CRD resources set `apply_only`
- [x] 8.9 Require `gke_gateway_api_channel = "CHANNEL_STANDARD"` whenever the chart's Envoy Gateway is installed, and disable the chart's shell `TCPRoute` in that case too; verify the plan fails without the channel and the rendered chart has no `TCPRoute`
- [x] 8.10 Reject `gitlab_enable_shell_load_balancer` together with the chart's own Gateway when `gitlab_gke_gateway` is not set; verify the plan fails
- [x] 8.11 Add `gitlab_gateway_api_envoy_replicas` and `gitlab_gateway_api_envoy_min_available`, and mirror them for NGINX with `gitlab_ingress_nginx_replicas` and `gitlab_ingress_nginx_min_available`; verify chart 10.5.6 renders the `EnvoyProxy` and the NGINX controller with those values, and no override when they are `null`
- [x] 8.12 Set `wait` on the Gateway, the SSH Service and the backend policies, so a delete waits for GKE to release the load balancer resources (the SSH Service no longer owns a load balancer, see section 9)
- [x] 8.13 Create the backend Services, their policies and the SSH Service without waiting for the Helm release, and the routes after the backend Services; verify in the dependency graph that none of them depends on `helm_release.gitlab`
- [x] 8.14 Verify on the test deployment that turning Envoy off brings NGINX back and leaves the Envoy CRDs in place, and that removing the GKE Gateway waits for the load balancer cleanup, then repeat the cutover; verified: rollback 75 s web and 2 min 17 s SSH downtime, CRDs kept with the same UIDs, `wait` blocked about 46 s (SSH) and 60 s (Gateway), the `GatewayClass` finalizer needs a manual removal (documented); second cutover 2 min 20 s web and 2 min 46 s SSH downtime, against 7 min 8 s and about 4.5 min for the first
- [x] 8.15 Add `gitlab_gke_gateway.log_sample_rate`, setting `logging` on both GCPBackendPolicies when it is not `null`; verify on the test deployment that the backend services get `logConfig.enable: true` and that Cloud Armor verdicts appear in the request logs
- [x] 8.16 Add `gitlab_ingress_configure_certmanager` (default `null`, following `gitlab_enable_certmanager`), so that consumers with their own cert-manager keep `global.ingress.configureCertmanager` true; verify the three input combinations render the expected value
- [x] 8.17 Leave `sampleRate` out of the GCPBackendPolicies when `log_sample_rate` is `0`: GKE marks a policy with `sampleRate` and logging disabled as invalid and drops all its settings, including the backend timeout; verify on the test deployment that the policies are attached, the backend services have `logConfig.enable: false` and the timeout stays at `backend_timeout_sec`
- [x] 8.18 Render the Envoy CRDs from a fixed set of placeholder values instead of the release values with placeholders; verify charts 10.3.0, 10.4.7, 10.5.6 and 10.5.7 render the same 8 Envoy CRDs, and that the test deployment plans no change on the CRD resources
- [x] 8.19 Add `terraform test` cases with mocked providers under `tests/`: default inputs keep the NGINX path and create no Gateway resource, both listener modes render their values, the chart version gates hold at `10.2.9`/`10.3.0` and `10.5.9`/`10.6.0`, and every cross-input check and input validation rejects its invalid input; verify the tests fail when a gate, `numTrustedHops`, a check or the backend port is changed
- [x] 8.20 Reject `gitlab_ingress_nginx_min_available` at or above `gitlab_ingress_nginx_replicas` (two replicas when null) when the NGINX Ingress is installed; verify the plan fails for 1 of 1 and for 2 with the default replicas, and passes for 2 of 3

## Workflow follow-up

- Get platform team approval on the input design, as required by sparkfabrik-innovation-team/board#5223, before publishing the release.
- Archive the change after the release is published.

## 9. SSH proxy load balancer

- [x] 9.1 Replace the `LoadBalancer` Service with a ClusterIP Service that carries the `cloud.google.com/neg` annotation, and create the regional external proxy Network Load Balancer on port 22 of the GitLab IP: health check, backend service, target TCP proxy and forwarding rule; verified on the test deployment that pods in the cluster reach ports 443 and 22 of the GitLab IP, and that SSH clone and push work from outside
- [x] 9.2 Read the zones of the network endpoint groups from the `cloud.google.com/neg-status` annotation, and stop the apply when it is missing; verified on the test deployment that the cutover from NGINX and the replacement of the `LoadBalancer` Service each finish in one apply
- [x] 9.3 Create a firewall rule that admits the proxy-only subnet and the health check ranges to GitLab Shell on the nodes, selected by the cluster service account and those of the additional node pools
- [x] 9.4 Add `gitlab_shell_load_balancer_idle_timeout_sec` (default `3600`); verified on the test deployment that a 120-second timeout closes an idle SSH connection after 121 seconds
- [x] 9.5 Require `gke_proxy_only_subnet_cidr` when `gitlab_enable_shell_load_balancer` is true; verify the plan fails without it
- [x] 9.6 Verify on the test deployment that turning the SSH load balancer off leaves no network endpoint group; verified: GKE removed them about two minutes after the apply
- [ ] 9.7 Verify a new deployment from an empty project and its destroy, confirming that no network endpoint group blocks the deletion of the network

## 10. Two-step rollback to NGINX

- [x] 10.1 Keep the Envoy CRD management and the chart's CRD switch tied to `gitlab_gateway_api_install_envoy` alone, so the controller can stay installed with `gitlab_enable_gateway_api = false`; verify chart 10.5.6 renders the controller, no `GatewayClass` and no `Gateway` in that state
- [x] 10.2 Document the two-step rollback and the hook objects Helm leaves behind in the `gateway_api` example README
- [x] 10.3 Verify on the test deployment that the first apply succeeds, that the controller deletes the Envoy proxy and releases the `GatewayClass`, and that the second apply uninstalls the controller; verified: each apply finished in one pass, the `GatewayClass` and the proxy objects were gone about 2 minutes after the first apply started with no manual patch, the first apply caused about 2 min 16 s of HTTPS and 2 min 33 s of SSH downtime and the second none, the Envoy CRDs stayed, and the next cutover applied in one pass with the leftover hook objects in place
