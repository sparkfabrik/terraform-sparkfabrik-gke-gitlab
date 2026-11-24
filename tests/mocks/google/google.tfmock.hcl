# Mock values the module validates or decodes. Everything else is generated.

# The Cloud SQL instance checks the format of its private network.
mock_resource "google_compute_network" {
  defaults = {
    self_link = "projects/test-project/global/networks/gitlab"
  }
}

# The module base64-decodes the key into Kubernetes secrets.
mock_resource "google_service_account_key" {
  defaults = {
    private_key = "e30="
  }
}

# The GitLab Shell forwarding rule takes the network tier of the address, and
# the provider checks its value.
mock_resource "google_compute_address" {
  defaults = {
    network_tier = "PREMIUM"
  }
}
