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

# The SSH load balancer alone, without the GKE Gateway.
variables {
  project_id        = "test-project"
  certmanager_email = "test@example.com"
  domain            = "example.com"
  gitlab_log_level  = "info"

  helm_chart_version                = "10.5.6"
  gke_proxy_only_subnet_cidr        = "10.129.0.0/23"
  gitlab_install_ingress_nginx      = false
  gitlab_enable_ingress             = false
  gitlab_enable_shell_load_balancer = true
}

# On the first apply the Service does not exist at plan time, so its
# annotation is read during the apply. This run must stay the first: a state
# from an earlier run moves the read to the plan.
run "first_apply_stops_when_gke_has_not_reported_the_network_endpoint_groups" {
  command = apply

  override_data {
    target = data.kubernetes_resource.gitlab_shell_neg
    values = {
      object = { metadata = { annotations = {} } }
    }
  }

  expect_failures = [google_compute_region_backend_service.gitlab_shell]
}

# The second apply finds the annotation and creates the load balancer.
run "second_apply_creates_the_load_balancer" {
  command = apply

  override_data {
    target = data.kubernetes_resource.gitlab_shell_neg
    values = {
      object = {
        metadata = {
          annotations = {
            "cloud.google.com/neg-status" = "{\"network_endpoint_groups\":{\"22\":\"gitlab-shell\"},\"zones\":[\"europe-west1-b\"]}"
          }
        }
      }
    }
  }

  assert {
    condition     = length(google_compute_region_backend_service.gitlab_shell[0].backend) == 1
    error_message = "The backend service must use the network endpoint group of the zone GKE reports."
  }

  assert {
    condition     = length(google_compute_forwarding_rule.gitlab_shell) == 1 && length(kubectl_manifest.gke_gateway) == 0
    error_message = "The SSH load balancer must work without the GKE Gateway."
  }
}
