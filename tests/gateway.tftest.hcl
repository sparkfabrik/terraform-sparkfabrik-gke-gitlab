# Runs with mocked providers, so it creates nothing and needs no credentials.
# Requires Terraform 1.7 or later: `terraform init && terraform test`.

mock_provider "google" {
  source = "./tests/mocks/google"
}
mock_provider "google-beta" {}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "random" {}
# Mocked so that time_sleep does not wait.
mock_provider "time" {}

# The GKE module reads zones and versions from data sources that a mock leaves
# empty. The tests only need its outputs.
override_module {
  target = module.gke
  outputs = {
    endpoint        = "192.0.2.10"
    ca_certificate  = "dGVzdA=="
    location        = "europe-west1"
    name            = "gitlab"
    service_account = "gitlab@test-project.iam.gserviceaccount.com"
  }
}

# A valid GKE Gateway deployment. Each run below changes as few inputs as it needs.
variables {
  project_id        = "test-project"
  certmanager_email = "test@example.com"
  domain            = "example.com"
  gitlab_log_level  = "info"

  helm_chart_version                = "10.5.6"
  gke_gateway_api_channel           = "CHANNEL_STANDARD"
  gke_proxy_only_subnet_cidr        = "10.129.0.0/23"
  gitlab_enable_gateway_certificate = true
  gitlab_enable_gateway_api         = true
  gitlab_gateway_api_install_envoy  = true
  gitlab_install_ingress_nginx      = false
  gitlab_enable_ingress             = false
  gitlab_enable_shell_load_balancer = true
  gitlab_install_kas                = true
  gitlab_gke_gateway                = {}
}

# Rendered values and Gateway objects

run "http_mode_renders_plain_http_listeners" {
  command = apply

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).gatewayApiResources.gateway.protocol == "HTTP"
    error_message = "The http mode must set gatewayApiResources.gateway.protocol to HTTP."
  }

  assert {
    condition     = !contains(keys(yamldecode(helm_release.gitlab.values[0]).global.gatewayApi), "externalTlsTermination")
    error_message = "The http mode must not set global.gatewayApi.externalTlsTermination."
  }

  assert {
    condition = (
      contains(keys(yamldecode(helm_release.gitlab.values[0]).gatewayApiResources.envoy), "clientTrafficPolicySpec") &&
      yamldecode(helm_release.gitlab.values[0]).gatewayApiResources.envoy.clientTrafficPolicySpec == null
    )
    error_message = "The http mode must remove the chart's Gateway-wide ClientTrafficPolicy with an explicit null."
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).gitlab.webservice.clientTrafficPolicy.main.spec.clientIPDetection.xForwardedFor.numTrustedHops == 2
    error_message = "The webservice policy must trust two hops: the load balancer and the proxy-only subnet."
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).gitlab.webservice.clientTrafficPolicy.main.spec.targetRefs[0].name == "gitlab-gw"
    error_message = "The webservice policy must target the whole gitlab-gw Gateway."
  }

  assert {
    condition = (
      contains(keys(yamldecode(helm_release.gitlab.values[0]).gitlab.kas.clientTrafficPolicy), "spec") &&
      yamldecode(helm_release.gitlab.values[0]).gitlab.kas.clientTrafficPolicy.spec == null
    )
    error_message = "The http mode must remove the chart's KAS ClientTrafficPolicy with an explicit null."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.envoy_backend_service["http"].yaml_body).spec.ports[0].targetPort == 10080
    error_message = "The http mode must target Envoy container port 10080."
  }
}

run "http_mode_puts_the_gke_gateway_in_front_of_envoy" {
  command = apply

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).global.hosts.externalIP == null
    error_message = "The chart must not receive the GitLab IP behind the GKE Gateway."
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).gatewayApiResources.envoy.proxySpec.provider.kubernetes.envoyService.type == "ClusterIP"
    error_message = "The chart's Envoy Service must be ClusterIP behind the GKE Gateway."
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0])["envoy-gateway"].crds.enabled == false
    error_message = "The release must not install the Envoy Gateway CRDs: the module does."
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).gitlab["gitlab-shell"].gatewayRoute.enabled == false
    error_message = "The chart's GitLab Shell TCPRoute must be disabled: GKE does not serve TCPRoute."
  }

  assert {
    condition = (
      yamldecode(helm_release.gitlab.values[0]).global.ingress.enabled == false &&
      yamldecode(helm_release.gitlab.values[0])["nginx-ingress"].enabled == false
    )
    error_message = "The Ingresses and the NGINX controller must follow their inputs."
  }

  assert {
    condition = toset(yamldecode(helm_release.gitlab.values[0]).gitlab.webservice.workhorse.trustedCIDRsForXForwardedFor) == toset([
      "10.129.0.0/23",
      "${google_compute_address.gitlab[0].address}/32",
    ])
    error_message = "Workhorse must trust the proxy-only subnet and the GitLab IP."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.gke_gateway[0].yaml_body).spec.gatewayClassName == "gke-l7-regional-external-managed"
    error_message = "The Gateway must use the regional external class."
  }

  assert {
    condition     = [for listener in yamldecode(kubectl_manifest.gke_gateway[0].yaml_body).spec.listeners : "${listener.protocol}:${listener.port}"] == ["HTTPS:443", "HTTP:80"]
    error_message = "The Gateway must listen on HTTPS 443 and HTTP 80."
  }

  assert {
    condition     = toset(keys(google_certificate_manager_certificate.gitlab)) == toset(["gitlab", "kas"])
    error_message = "Each served host must have its own certificate."
  }

  assert {
    condition     = toset(keys(kubectl_manifest.gke_gateway_routes)) == toset(["http-redirect", "web", "kas"])
    error_message = "The redirect, web and KAS routes must exist."
  }

  assert {
    condition = (
      yamldecode(kubectl_manifest.gke_gateway_routes["kas"].yaml_body).spec.rules[0].matches[0].headers[0].value == "websocket" &&
      yamldecode(kubectl_manifest.gke_gateway_routes["kas"].yaml_body).spec.rules[0].backendRefs[0].name == "gitlab-envoy-http" &&
      yamldecode(kubectl_manifest.gke_gateway_routes["kas"].yaml_body).spec.rules[1].backendRefs[0].name == "gitlab-envoy-h2c"
    )
    error_message = "KAS WebSocket upgrades must use the HTTP/1.1 backend and everything else the H2C backend."
  }

  assert {
    condition = (
      !contains(keys(yamldecode(kubectl_manifest.envoy_backend_service["http"].yaml_body).spec.ports[0]), "appProtocol") &&
      yamldecode(kubectl_manifest.envoy_backend_service["h2c"].yaml_body).spec.ports[0].appProtocol == "kubernetes.io/h2c"
    )
    error_message = "Only the h2c backend Service must set appProtocol."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.envoy_backend_policy["http"].yaml_body).spec.default == { timeoutSec = 3600 }
    error_message = "Without the optional inputs the backend policy must only set the 3600-second timeout."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.gitlab_shell_load_balancer[0].yaml_body).spec.ports[0].port == 22
    error_message = "The GitLab Shell load balancer must serve port 22."
  }
}

run "external_tls_termination_mode_uses_the_chart_setting" {
  command = apply

  variables {
    helm_chart_version = "10.6.0"
    gitlab_gke_gateway = {
      envoy_listener_mode     = "external_tls_termination"
      cloud_armor_policy_name = "gitlab"
      backend_timeout_sec     = 120
      log_sample_rate         = 1
    }
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).global.gatewayApi.externalTlsTermination == true
    error_message = "The mode must set global.gatewayApi.externalTlsTermination."
  }

  assert {
    condition     = !contains(keys(yamldecode(helm_release.gitlab.values[0]).gatewayApiResources), "gateway")
    error_message = "The mode must leave the chart listener protocol alone."
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).gatewayApiResources.envoy.clientTrafficPolicySpec.clientIPDetection.xForwardedFor.numTrustedHops == 2
    error_message = "The chart's Gateway-wide policy must trust two hops: the load balancer and the proxy-only subnet."
  }

  assert {
    condition = (
      !contains(keys(yamldecode(helm_release.gitlab.values[0]).gitlab.webservice), "clientTrafficPolicy") &&
      !contains(keys(yamldecode(helm_release.gitlab.values[0]).gitlab.kas), "clientTrafficPolicy")
    )
    error_message = "The mode must not override the chart's webservice and KAS policies."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.envoy_backend_service["http"].yaml_body).spec.ports[0].targetPort == 10443
    error_message = "The mode must target Envoy container port 10443."
  }

  assert {
    condition = yamldecode(kubectl_manifest.envoy_backend_policy["h2c"].yaml_body).spec.default == {
      timeoutSec     = 120
      securityPolicy = "gitlab"
      logging        = { enabled = true, sampleRate = 1000000 }
    }
    error_message = "The backend policy must carry the timeout, the Cloud Armor policy and the request logs."
  }
}

# GKE rejects a policy that sets sampleRate with logging disabled.
run "log_sample_rate_zero_turns_the_request_logs_off" {
  command = apply

  variables {
    gitlab_gke_gateway = { log_sample_rate = 0 }
  }

  assert {
    condition     = yamldecode(kubectl_manifest.envoy_backend_policy["http"].yaml_body).spec.default.logging == { enabled = false }
    error_message = "log_sample_rate = 0 must set only logging.enabled = false."
  }
}

run "envoy_replicas_apply_without_the_gke_gateway" {
  command = apply

  variables {
    gitlab_gke_gateway                     = null
    gitlab_enable_shell_load_balancer      = false
    gke_proxy_only_subnet_cidr             = null
    gitlab_enable_gateway_certificate      = false
    gitlab_gateway_api_envoy_replicas      = 2
    gitlab_gateway_api_envoy_min_available = 1
  }

  assert {
    condition = (
      yamldecode(helm_release.gitlab.values[0]).gatewayApiResources.envoy.proxySpec.provider.kubernetes.envoyDeployment.replicas == 2 &&
      yamldecode(helm_release.gitlab.values[0]).gatewayApiResources.envoy.proxySpec.provider.kubernetes.envoyPDB.minAvailable == 1
    )
    error_message = "The Envoy replicas and PodDisruptionBudget must follow their inputs."
  }

  assert {
    condition = (
      !contains(keys(yamldecode(helm_release.gitlab.values[0]).gatewayApiResources), "gateway") &&
      !contains(keys(yamldecode(helm_release.gitlab.values[0]).gatewayApiResources.envoy.proxySpec.provider.kubernetes), "envoyService")
    )
    error_message = "Without the GKE Gateway the chart keeps its own listeners and Envoy Service."
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).gitlab["gitlab-shell"].gatewayRoute.enabled == false
    error_message = "The chart's GitLab Shell TCPRoute must be disabled whenever the chart's Envoy Gateway is installed."
  }

  assert {
    condition     = length(kubectl_manifest.gke_gateway) == 0 && length(kubectl_manifest.envoy_backend_service) == 0
    error_message = "Without gitlab_gke_gateway the module must not create the GKE Gateway."
  }
}

# Chart version gates

run "chart_10_3_0_is_the_first_supported_version" {
  command = plan

  variables {
    helm_chart_version = "10.3.0"
  }
}

run "chart_10_2_9_is_rejected" {
  command = plan

  variables {
    helm_chart_version = "10.2.9"
  }

  expect_failures = [terraform_data.gateway_api_checks]
}

run "external_tls_termination_is_rejected_on_chart_10_5_9" {
  command = plan

  variables {
    helm_chart_version = "10.5.9"
    gitlab_gke_gateway = { envoy_listener_mode = "external_tls_termination" }
  }

  expect_failures = [terraform_data.gateway_api_checks]
}

run "external_tls_termination_is_accepted_on_the_next_major" {
  command = plan

  variables {
    helm_chart_version = "11.0.0"
    gitlab_gke_gateway = { envoy_listener_mode = "external_tls_termination" }
  }
}

# Cross-input checks. Each run breaks one requirement of the valid deployment.

run "gke_load_balancers_reject_the_nginx_ingress" {
  command = plan

  variables {
    gitlab_install_ingress_nginx = true
  }

  expect_failures = [terraform_data.gateway_api_checks]
}

run "envoy_requires_the_gke_standard_channel" {
  command = plan

  variables {
    gke_gateway_api_channel = null
  }

  expect_failures = [terraform_data.gateway_api_checks]
}

run "shell_load_balancer_rejects_the_chart_gateway" {
  command = plan

  variables {
    gitlab_gke_gateway = null
  }

  expect_failures = [terraform_data.gateway_api_checks]
}

run "envoy_min_available_must_be_lower_than_the_replicas" {
  command = plan

  variables {
    gitlab_gateway_api_envoy_min_available = 1
  }

  expect_failures = [terraform_data.gateway_api_checks]
}

run "gke_gateway_requires_the_proxy_only_subnet" {
  command = plan

  variables {
    gke_proxy_only_subnet_cidr = null
  }

  expect_failures = [terraform_data.gateway_api_checks]
}

run "gke_gateway_requires_the_gateway_certificate" {
  command = plan

  variables {
    gitlab_enable_gateway_certificate = false
  }

  expect_failures = [terraform_data.gateway_api_checks]
}

run "gke_gateway_requires_the_chart_envoy_gateway" {
  command = plan

  variables {
    gitlab_gateway_api_install_envoy = false
  }

  expect_failures = [terraform_data.gateway_api_checks]
}

# Input validations

run "envoy_listener_mode_must_be_a_known_mode" {
  command = plan

  variables {
    gitlab_gke_gateway = { envoy_listener_mode = "https" }
  }

  expect_failures = [var.gitlab_gke_gateway]
}

run "log_sample_rate_must_be_between_0_and_1" {
  command = plan

  variables {
    gitlab_gke_gateway = { log_sample_rate = 1.5 }
  }

  expect_failures = [var.gitlab_gke_gateway]
}

run "gateway_api_channel_must_be_a_supported_channel" {
  command = plan

  variables {
    gke_gateway_api_channel = "CHANNEL_EXPERIMENTAL"
  }

  expect_failures = [var.gke_gateway_api_channel]
}
