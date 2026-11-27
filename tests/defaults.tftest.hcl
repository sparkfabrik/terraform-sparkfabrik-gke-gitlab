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

variables {
  project_id        = "test-project"
  certmanager_email = "test@example.com"
  domain            = "example.com"
  gitlab_log_level  = "info"
}

# Default inputs keep the NGINX Ingress path and create no Gateway resource.
run "defaults_keep_the_nginx_ingress_path" {
  command = apply

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).global.ingress.enabled == true
    error_message = "global.ingress.enabled must be true by default."
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).global.ingress.configureCertmanager == true
    error_message = "global.ingress.configureCertmanager must be true by default."
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).installCertmanager == true
    error_message = "installCertmanager must be true by default."
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0])["nginx-ingress"].enabled == true
    error_message = "nginx-ingress must be enabled by default."
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).global.gatewayApi.enabled == false
    error_message = "global.gatewayApi.enabled must be false by default."
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).global.hosts.externalIP == google_compute_address.gitlab[0].address
    error_message = "global.hosts.externalIP must be the GitLab IP by default."
  }

  assert {
    condition = alltrue([
      for key in ["gatewayApiResources", "envoy-gateway"] : !contains(keys(yamldecode(helm_release.gitlab.values[0])), key)
    ])
    error_message = "Default inputs must not render gatewayApiResources or envoy-gateway."
  }

  assert {
    condition     = !contains(keys(yamldecode(helm_release.gitlab.values[0]).gitlab["gitlab-shell"]), "gatewayRoute")
    error_message = "Default inputs must not override the GitLab Shell gateway route."
  }

  assert {
    condition = (
      length(terraform_data.gateway_api_checks) == 0 &&
      length(terraform_data.ingress_nginx_checks) == 0 &&
      length(data.helm_template.envoy_crds) == 0 &&
      length(kubectl_manifest.envoy_crds) == 0 &&
      length(kubectl_manifest.gke_gateway) == 0 &&
      length(kubectl_manifest.gke_gateway_routes) == 0 &&
      length(kubectl_manifest.envoy_backend_service) == 0 &&
      length(kubectl_manifest.envoy_backend_policy) == 0 &&
      length(kubectl_manifest.gitlab_shell_load_balancer) == 0 &&
      length(google_compute_subnetwork.proxy_only) == 0 &&
      length(google_certificate_manager_certificate.gitlab) == 0
    )
    error_message = "Default inputs must not create any Gateway resource."
  }
}

run "ingress_certmanager_follows_gitlab_enable_certmanager" {
  command = apply

  variables {
    gitlab_enable_certmanager = false
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).global.ingress.configureCertmanager == false
    error_message = "global.ingress.configureCertmanager must follow gitlab_enable_certmanager."
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).installCertmanager == false
    error_message = "installCertmanager must follow gitlab_enable_certmanager."
  }
}

# A cert-manager installed outside the chart keeps issuing the Ingress certificates.
run "ingress_certmanager_can_stay_on_without_the_chart_certmanager" {
  command = apply

  variables {
    gitlab_enable_certmanager            = false
    gitlab_ingress_configure_certmanager = true
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).global.ingress.configureCertmanager == true
    error_message = "gitlab_ingress_configure_certmanager = true must set global.ingress.configureCertmanager."
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).installCertmanager == false
    error_message = "installCertmanager must follow gitlab_enable_certmanager."
  }
}

run "ingress_certmanager_can_be_turned_off_alone" {
  command = apply

  variables {
    gitlab_ingress_configure_certmanager = false
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).global.ingress.configureCertmanager == false
    error_message = "gitlab_ingress_configure_certmanager = false must clear global.ingress.configureCertmanager."
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).installCertmanager == true
    error_message = "installCertmanager must follow gitlab_enable_certmanager."
  }
}

# Ingress TLS and the chart's self-signed certificate Job

run "ingress_tls_is_enabled_by_default" {
  command = apply

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).global.ingress.tls.enabled == true
    error_message = "global.ingress.tls.enabled must be true by default."
  }
}

# With TLS on and configureCertmanager off, the chart's shared-secrets hook
# creates a self-signed wildcard certificate that nothing uses.
run "ingress_tls_follows_gitlab_enable_ingress" {
  command = apply

  variables {
    gitlab_enable_ingress     = false
    gitlab_enable_certmanager = false
    certmanager_email         = null
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0]).global.ingress.tls.enabled == false
    error_message = "global.ingress.tls.enabled must follow gitlab_enable_ingress."
  }
}

# certmanager_email

run "certmanager_email_is_rendered_when_set" {
  command = apply

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0])["certmanager-issuer"].email == "test@example.com"
    error_message = "certmanager-issuer.email must follow certmanager_email."
  }
}

run "certmanager_email_is_optional_without_certmanager" {
  command = apply

  variables {
    gitlab_enable_certmanager = false
    certmanager_email         = null
  }

  assert {
    condition     = !can(yamldecode(helm_release.gitlab.values[0])["certmanager-issuer"])
    error_message = "certmanager-issuer must be left out of the values when certmanager_email is null."
  }
}

run "certmanager_email_is_still_rendered_without_certmanager" {
  command = apply

  variables {
    gitlab_enable_certmanager = false
  }

  assert {
    condition     = yamldecode(helm_release.gitlab.values[0])["certmanager-issuer"].email == "test@example.com"
    error_message = "certmanager-issuer.email must follow certmanager_email when cert-manager is off."
  }
}

run "certmanager_email_is_required_by_default" {
  command = plan

  variables {
    certmanager_email = null
  }

  expect_failures = [helm_release.gitlab]
}

run "certmanager_email_must_not_be_empty" {
  command = plan

  variables {
    certmanager_email = ""
  }

  expect_failures = [helm_release.gitlab]
}

run "certmanager_email_must_not_be_blank" {
  command = plan

  variables {
    certmanager_email = "   "
  }

  expect_failures = [helm_release.gitlab]
}

# A blank email counts as not set, so it never reaches the values as a null.
run "blank_certmanager_email_is_left_out_without_certmanager" {
  command = apply

  variables {
    gitlab_enable_certmanager = false
    certmanager_email         = "   "
  }

  assert {
    condition     = !can(yamldecode(helm_release.gitlab.values[0])["certmanager-issuer"])
    error_message = "certmanager-issuer must be left out of the values when certmanager_email is blank."
  }
}

run "certmanager_email_is_required_with_an_external_certmanager" {
  command = plan

  variables {
    gitlab_enable_certmanager            = false
    gitlab_ingress_configure_certmanager = true
    certmanager_email                    = null
  }

  expect_failures = [helm_release.gitlab]
}

# The chart's Gateway API Issuer needs the email too.
run "certmanager_email_is_required_for_the_gateway_api_certificates" {
  command = plan

  variables {
    gitlab_enable_certmanager                = false
    gitlab_gateway_api_configure_certmanager = true
    certmanager_email                        = null
  }

  expect_failures = [helm_release.gitlab]
}

# NGINX Ingress controller replicas and PodDisruptionBudget

run "nginx_replicas_and_min_available_follow_their_inputs" {
  command = apply

  variables {
    gitlab_ingress_nginx_replicas      = 3
    gitlab_ingress_nginx_min_available = 2
  }

  assert {
    condition = (
      yamldecode(helm_release.gitlab.values[0])["nginx-ingress"].controller.replicaCount == 3 &&
      yamldecode(helm_release.gitlab.values[0])["nginx-ingress"].controller.minAvailable == 2
    )
    error_message = "The NGINX controller replicas and PodDisruptionBudget must follow their inputs."
  }
}

run "nginx_min_available_must_be_lower_than_the_replicas" {
  command = plan

  variables {
    gitlab_ingress_nginx_replicas      = 1
    gitlab_ingress_nginx_min_available = 1
  }

  expect_failures = [terraform_data.ingress_nginx_checks]
}

# The chart runs two controller replicas by default.
run "nginx_min_available_must_be_lower_than_the_default_replicas" {
  command = plan

  variables {
    gitlab_ingress_nginx_min_available = 2
  }

  expect_failures = [terraform_data.ingress_nginx_checks]
}

run "nginx_min_available_is_not_checked_without_the_nginx_ingress" {
  command = plan

  variables {
    gitlab_install_ingress_nginx       = false
    gitlab_ingress_nginx_min_available = 2
  }
}
