# GitLab behind a GKE regional Application Load Balancer and the chart's
# bundled Envoy Gateway. Every resource in this file is opt-in, so default
# inputs leave existing deployments unchanged.

locals {
  gke_gateway_enabled = var.gitlab_gke_gateway != null
  envoy_enabled       = var.gitlab_enable_gateway_api && var.gitlab_gateway_api_install_envoy
  # Name of the GitLab Helm release. The Kubernetes objects below use this
  # constant, not helm_release.gitlab.name, so that they do not wait for the
  # release: the load balancers are then ready as soon as the pods are.
  gitlab_release_name = "gitlab"
  # Either Google load balancer the module can put on the GitLab IP.
  gke_load_balancers_enabled = local.gke_gateway_enabled || var.gitlab_enable_shell_load_balancer

  helm_chart_version_parts = split(".", var.helm_chart_version)
  helm_chart_major         = try(tonumber(local.helm_chart_version_parts[0]), 0)
  helm_chart_minor         = try(tonumber(local.helm_chart_version_parts[1]), 0)
  # Chart 10.3 is the first release that uses only standard channel Gateway
  # API resources and lets the webservice ClientTrafficPolicy be overridden.
  helm_chart_supports_gke_gateway = local.helm_chart_major > 10 || (local.helm_chart_major == 10 && local.helm_chart_minor >= 3)
  # Chart 10.6 adds global.gatewayApi.externalTlsTermination.
  helm_chart_supports_external_tls_termination = local.helm_chart_major > 10 || (local.helm_chart_major == 10 && local.helm_chart_minor >= 6)

  gke_gateway_external_tls = local.gke_gateway_enabled && try(var.gitlab_gke_gateway.envoy_listener_mode, "http") == "external_tls_termination"
  # Envoy Gateway maps listener ports below 1024 to port + 10000. The http mode
  # serves GitLab on the port 80 listeners, external_tls_termination on 443.
  envoy_backend_target_port = local.gke_gateway_external_tls ? 10443 : 10080
}

# Cross-input checks. Variable validations cannot reference other inputs on
# the Terraform versions this module supports, so they live here.
resource "terraform_data" "gateway_api_checks" {
  count = local.gke_load_balancers_enabled || local.envoy_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = !local.gke_load_balancers_enabled || !var.gitlab_install_ingress_nginx
      error_message = "gitlab_gke_gateway and gitlab_enable_shell_load_balancer require gitlab_install_ingress_nginx = false: the NGINX Ingress holds the same IP on ports 22 to 443."
    }

    precondition {
      condition     = local.helm_chart_supports_gke_gateway
      error_message = "gitlab_gateway_api_install_envoy, gitlab_gke_gateway and gitlab_enable_shell_load_balancer require helm_chart_version 10.3 or later, got ${var.helm_chart_version}."
    }

    precondition {
      condition     = !local.gke_gateway_external_tls || local.helm_chart_supports_external_tls_termination
      error_message = "gitlab_gke_gateway.envoy_listener_mode = \"external_tls_termination\" requires helm_chart_version 10.6 or later, got ${var.helm_chart_version}."
    }

    # The module installs only the Envoy Gateway CRDs: the Gateway API CRDs
    # the chart's Envoy resources need must come from GKE.
    precondition {
      condition     = !local.envoy_enabled || var.gke_gateway_api_channel == "CHANNEL_STANDARD"
      error_message = "gitlab_gateway_api_install_envoy requires gke_gateway_api_channel = \"CHANNEL_STANDARD\": GKE supplies the Gateway API CRDs, and the module installs only the Envoy Gateway CRDs."
    }

    # Without the GKE Gateway the chart's own Gateway keeps the GitLab IP and
    # its SSH listener, which collides with the SSH load balancer on port 22.
    precondition {
      condition     = !var.gitlab_enable_shell_load_balancer || local.gke_gateway_enabled || !var.gitlab_enable_gateway_api
      error_message = "gitlab_enable_shell_load_balancer requires gitlab_gke_gateway when gitlab_enable_gateway_api is true: the chart's own Gateway would also listen on port 22 of the GitLab IP."
    }

    # Envoy runs one replica unless gitlab_gateway_api_envoy_replicas is set.
    precondition {
      condition     = var.gitlab_gateway_api_envoy_min_available == null ? true : var.gitlab_gateway_api_envoy_min_available < coalesce(var.gitlab_gateway_api_envoy_replicas, 1)
      error_message = "gitlab_gateway_api_envoy_min_available must be lower than gitlab_gateway_api_envoy_replicas, which is one replica when null: a PodDisruptionBudget that allows no eviction blocks node drains."
    }

    precondition {
      condition     = !local.gke_gateway_enabled || var.gke_proxy_only_subnet_cidr != null
      error_message = "gitlab_gke_gateway requires gke_proxy_only_subnet_cidr."
    }

    precondition {
      condition     = !var.gitlab_enable_shell_load_balancer || var.gke_proxy_only_subnet_cidr != null
      error_message = "gitlab_enable_shell_load_balancer requires gke_proxy_only_subnet_cidr: the SSH load balancer is a regional proxy Network Load Balancer."
    }

    precondition {
      condition     = !local.gke_gateway_enabled || var.gitlab_enable_gateway_certificate
      error_message = "gitlab_gke_gateway requires gitlab_enable_gateway_certificate = true."
    }

    precondition {
      condition     = !local.gke_gateway_enabled || local.envoy_enabled
      error_message = "gitlab_gke_gateway requires gitlab_enable_gateway_api = true and gitlab_gateway_api_install_envoy = true."
    }
  }
}

locals {
  gitlab_address_name = var.gitlab_address_name != "" ? var.gitlab_address_name : google_compute_address.gitlab[0].name

  # Workhorse sees "<client>, <load balancer IP>, <proxy-only address>" in
  # X-Forwarded-For and must skip both proxies to find the client.
  workhorse_trusted_cidrs = local.gke_gateway_enabled ? compact([var.gke_proxy_only_subnet_cidr, "${local.gitlab_address}/32"]) : []

  # The hosts the chart serves, as the chart names them by default.
  gitlab_host   = "gitlab.${local.domain}"
  kas_host      = var.gitlab_install_kas ? (local.kas_domain != "" ? local.kas_domain : "kas.${local.domain}") : ""
  registry_host = var.gitlab_enable_registry ? "registry.${local.domain}" : ""

  # Keyed by role, so the keys are known at plan time even when the domain
  # is derived from the GitLab IP.
  gateway_certificate_hosts = var.gitlab_enable_gateway_certificate ? merge(
    { gitlab = local.gitlab_host },
    var.gitlab_install_kas ? { kas = local.kas_host } : {},
    var.gitlab_enable_registry ? { registry = local.registry_host } : {},
  ) : {}
}

# Proxy-only subnet for the regional load balancers: the GKE Gateway and the
# GitLab Shell load balancer. The GKE Gateway controller creates the firewall
# rule that admits it to Envoy.
resource "google_compute_subnetwork" "proxy_only" {
  count = var.gke_proxy_only_subnet_cidr != null ? 1 : 0

  name          = "gitlab-proxy-only"
  ip_cidr_range = var.gke_proxy_only_subnet_cidr
  region        = var.region
  network       = google_compute_network.gitlab.id
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# Regional Google-managed certificate. Regional certificates only support DNS
# authorization, so each host needs a CNAME record from the output below.
resource "google_certificate_manager_dns_authorization" "gitlab" {
  for_each = local.gateway_certificate_hosts

  # Derived from the host only: a replaced authorization changes the CNAME
  # target and breaks the next renewal.
  name     = substr("gitlab-${replace(each.value, ".", "-")}", 0, 63)
  location = var.region
  type     = "PER_PROJECT_RECORD"
  domain   = each.value

  depends_on = [module.project_services.project_id]
}

# One certificate per host: enabling KAS or the registry adds a certificate
# and leaves the active ones untouched, so existing hosts keep serving HTTPS
# while the new host waits for its DNS authorization record.
resource "google_certificate_manager_certificate" "gitlab" {
  for_each = local.gateway_certificate_hosts

  # Derived from the host, so a host change creates the new certificate
  # before the Gateway stops using the old one.
  name        = substr("gitlab-gw-${replace(each.value, ".", "-")}", 0, 63)
  location    = var.region
  description = "GitLab GKE Gateway certificate for ${each.value}"

  managed {
    domains            = [each.value]
    dns_authorizations = [google_certificate_manager_dns_authorization.gitlab[each.key].id]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Envoy Gateway CRDs, taken from the configured GitLab chart version.
locals {
  # The CRD render needs no real value: these are the fewest values that pass
  # the chart's configuration checks. They are constants, so the render and
  # the CRD keys are known at plan time, also on a new deployment, and they do
  # not depend on the release values.
  envoy_crds_render_values = yamlencode({
    global = {
      gatewayApi = { enabled = true, installEnvoy = true }
      psql       = { host = "192.0.2.2", password = { secret = "placeholder" } }
      redis      = { host = "192.0.2.3" }
      appConfig  = { object_store = { enabled = true, connection = { secret = "placeholder" } } }
    }
    "certmanager-issuer" = { email = "placeholder@example.com" }
    registry             = { storage = { secret = "placeholder", key = "config" } }
  })

  envoy_crd_documents = local.envoy_enabled ? flatten([
    for file in data.helm_template.envoy_crds[0].crds : [
      for doc in split("\n---", file) : doc if trimspace(trimprefix(trimspace(doc), "---")) != ""
    ]
  ]) : []

  envoy_crds = {
    for doc in local.envoy_crd_documents : yamldecode(doc).metadata.name => doc
    if try(yamldecode(doc).kind, "") == "CustomResourceDefinition" && try(yamldecode(doc).spec.group, "") == "gateway.envoyproxy.io"
  }
}

data "helm_template" "envoy_crds" {
  count = local.envoy_enabled ? 1 : 0

  name         = local.gitlab_release_name
  namespace    = var.gitlab_namespace
  repository   = "https://charts.gitlab.io"
  chart        = "gitlab"
  version      = var.helm_chart_version
  include_crds = true

  values = [local.envoy_crds_render_values]

  set = [
    {
      name  = "envoy-gateway.crds.enabled"
      value = "true"
    },
  ]
}

resource "kubectl_manifest" "envoy_crds" {
  for_each = local.envoy_crds

  yaml_body = each.value
  # Server-side apply has no size limit on the last-applied annotation, and
  # force takes ownership from a release that installed the CRDs earlier.
  server_side_apply = true
  force_conflicts   = true
  # Never delete a CRD. When Envoy is turned off, Terraform destroys these
  # instances before it updates the release, and deleting a CRD deletes every
  # object of its kind, which breaks that update. The CRDs stay in the cluster,
  # as with Helm. Do not use create_before_destroy to reorder the two steps:
  # Terraform extends it to everything the CRDs depend on, such as the cluster
  # and the database, in every deployment.
  apply_only = true
}

# GKE Gateway in front of Envoy.
locals {
  gke_gateway_name = "gitlab-gke"
  # Gateway created by the chart for Envoy Gateway, see gitlab.gatewayApi.gateway.name.default.
  envoy_gateway_name = "${local.gitlab_release_name}-gw"

  # Two Services on the same Envoy port: the chart gives every HTTP listener
  # port 80, and a Service port has a single appProtocol. The load balancer
  # uses HTTP/1.1 for KAS WebSocket and HTTP/2 for KAS gRPC.
  envoy_backends = local.gke_gateway_enabled ? {
    http = { name = "gitlab-envoy-http", app_protocol = null }
    h2c  = { name = "gitlab-envoy-h2c", app_protocol = "kubernetes.io/h2c" }
  } : {}

  # GCPBackendPolicy takes the sample rate in millionths of the requests
  # (1000000 logs all of them). Null when log_sample_rate is not set.
  gke_gateway_log_sample_rate_millionths = try(floor(var.gitlab_gke_gateway.log_sample_rate * 1000000), null)
}

resource "kubectl_manifest" "envoy_backend_service" {
  for_each = local.envoy_backends

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = each.value.name
      namespace = var.gitlab_namespace
    }
    spec = {
      type = "ClusterIP"
      selector = {
        "app.kubernetes.io/name"                         = "envoy"
        "app.kubernetes.io/component"                    = "proxy"
        "gateway.envoyproxy.io/owning-gateway-name"      = local.envoy_gateway_name
        "gateway.envoyproxy.io/owning-gateway-namespace" = var.gitlab_namespace
      }
      ports = [merge(
        {
          name       = "http"
          port       = 80
          protocol   = "TCP"
          targetPort = local.envoy_backend_target_port
        },
        each.value.app_protocol != null ? { appProtocol = each.value.app_protocol } : {}
      )]
    }
  })
  server_side_apply = true

  depends_on = [
    terraform_data.gateway_api_checks,
    kubernetes_namespace.gitlab_namespace,
  ]
}

resource "kubectl_manifest" "envoy_backend_health_check" {
  for_each = local.envoy_backends

  yaml_body = yamlencode({
    apiVersion = "networking.gke.io/v1"
    kind       = "HealthCheckPolicy"
    metadata = {
      name      = each.value.name
      namespace = var.gitlab_namespace
    }
    spec = {
      default = {
        config = {
          type = "HTTP"
          httpHealthCheck = {
            port        = 19003
            requestPath = "/ready"
          }
        }
      }
      targetRef = {
        group = ""
        kind  = "Service"
        name  = each.value.name
      }
    }
  })
  server_side_apply = true

  depends_on = [kubectl_manifest.envoy_backend_service]
}

resource "kubectl_manifest" "envoy_backend_policy" {
  for_each = local.envoy_backends

  yaml_body = yamlencode({
    apiVersion = "networking.gke.io/v1"
    kind       = "GCPBackendPolicy"
    metadata = {
      name      = each.value.name
      namespace = var.gitlab_namespace
    }
    spec = {
      default = merge(
        { timeoutSec = var.gitlab_gke_gateway.backend_timeout_sec },
        var.gitlab_gke_gateway.cloud_armor_policy_name != null ? { securityPolicy = var.gitlab_gke_gateway.cloud_armor_policy_name } : {},
        # GKE rejects the whole policy when sampleRate is set with logging
        # disabled, so it is left out then.
        local.gke_gateway_log_sample_rate_millionths != null ? {
          logging = merge(
            { enabled = local.gke_gateway_log_sample_rate_millionths > 0 },
            local.gke_gateway_log_sample_rate_millionths > 0 ? { sampleRate = local.gke_gateway_log_sample_rate_millionths } : {}
          )
        } : {}
      )
      targetRef = {
        group = ""
        kind  = "Service"
        name  = each.value.name
      }
    }
  })
  server_side_apply = true
  # On delete, wait until GKE has removed the load balancer resources and
  # released the object. The subnet, the address and the Cloud Armor policy
  # they use are deleted next.
  wait = true

  depends_on = [kubectl_manifest.envoy_backend_service]
}

resource "kubectl_manifest" "gke_gateway" {
  count = local.gke_gateway_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = local.gke_gateway_name
      namespace = var.gitlab_namespace
    }
    spec = {
      gatewayClassName = "gke-l7-regional-external-managed"
      addresses = [{
        type  = "NamedAddress"
        value = local.gitlab_address_name
      }]
      listeners = [
        {
          name     = "https"
          protocol = "HTTPS"
          port     = 443
          tls = {
            mode = "Terminate"
            options = {
              "networking.gke.io/cert-manager-certs" = join(", ", [for cert in google_certificate_manager_certificate.gitlab : cert.name])
            }
          }
        },
        {
          name     = "http"
          protocol = "HTTP"
          port     = 80
        },
      ]
    }
  })
  server_side_apply = true
  # On delete, wait until GKE has removed the load balancer resources and
  # released the object. The subnet, the address and the Cloud Armor policy
  # they use are deleted next.
  wait = true

  depends_on = [
    terraform_data.gateway_api_checks,
    google_compute_subnetwork.proxy_only,
    kubernetes_namespace.gitlab_namespace,
  ]
}

locals {
  # Route specs are encoded to YAML so routes of different shapes fit in one map.
  gke_gateway_routes = local.gke_gateway_enabled ? tomap(merge(
    {
      http-redirect = yamlencode({
        parentRefs = [{ name = local.gke_gateway_name, sectionName = "http" }]
        rules = [{
          filters = [{
            type            = "RequestRedirect"
            requestRedirect = { scheme = "https", statusCode = 301 }
          }]
        }]
      })
      web = yamlencode({
        parentRefs = [{ name = local.gke_gateway_name, sectionName = "https" }]
        hostnames  = compact([local.gitlab_host, local.registry_host])
        rules = [{
          backendRefs = [{ name = local.envoy_backends.http.name, port = 80 }]
        }]
      })
    },
    var.gitlab_install_kas ? {
      # WebSocket upgrades need HTTP/1.1, gRPC needs HTTP/2.
      kas = yamlencode({
        parentRefs = [{ name = local.gke_gateway_name, sectionName = "https" }]
        hostnames  = [local.kas_host]
        rules = [
          {
            matches     = [{ headers = [{ name = "Upgrade", value = "websocket" }] }]
            backendRefs = [{ name = local.envoy_backends.http.name, port = 80 }]
          },
          {
            backendRefs = [{ name = local.envoy_backends.h2c.name, port = 80 }]
          },
        ]
      })
    } : {}
  )) : tomap({})
}

resource "kubectl_manifest" "gke_gateway_routes" {
  for_each = local.gke_gateway_routes

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "${local.gke_gateway_name}-${each.key}"
      namespace = var.gitlab_namespace
    }
    spec = yamldecode(each.value)
  })
  server_side_apply = true

  depends_on = [
    kubectl_manifest.gke_gateway,
    kubectl_manifest.envoy_backend_service,
  ]
}

# GitLab Shell on its own regional external proxy Network Load Balancer,
# sharing the GitLab IP with the GKE Gateway on a different port. Terraform
# creates the load balancer: a LoadBalancer Service would carry the GitLab IP
# in its status, the nodes would then handle every pod connection to that IP
# themselves, and pods could not reach the Gateway on ports 443 and 80.
locals {
  shell_neg_service_name = "gitlab-shell-neg"
  shell_neg_name         = "gitlab-shell"
  shell_container_port   = 2222

  # Service accounts of every node that can run GitLab Shell: the cluster one,
  # also used by auto-provisioned pools, and those set on additional pools.
  shell_node_service_accounts = compact(distinct(concat(
    [module.gke.service_account],
    [for pool in var.gke_additional_node_pools : lookup(pool, "service_account", "")],
  )))

  # GKE writes the zones of the network endpoint groups on the Service.
  shell_neg_status = try(jsondecode(data.kubernetes_resource.gitlab_shell_neg[0].object.metadata.annotations["cloud.google.com/neg-status"]), {})
  shell_neg_zones  = toset(try(local.shell_neg_status.zones, []))
}

# ClusterIP Service whose only job is to make GKE create one standalone zonal
# network endpoint group of the GitLab Shell pods in every zone with nodes.
resource "kubectl_manifest" "gitlab_shell_load_balancer" {
  count = var.gitlab_enable_shell_load_balancer ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = local.shell_neg_service_name
      namespace = var.gitlab_namespace
      annotations = {
        "cloud.google.com/neg" = jsonencode({
          exposed_ports = { "22" = { name = local.shell_neg_name } }
        })
      }
    }
    spec = {
      type = "ClusterIP"
      selector = {
        app     = "gitlab-shell"
        release = local.gitlab_release_name
      }
      ports = [{
        name       = "ssh"
        port       = 22
        protocol   = "TCP"
        targetPort = local.shell_container_port
      }]
    }
  })
  server_side_apply = true
  # An upgrade from the LoadBalancer Service of release 3.0.0 replaces the
  # object: wait until GKE has removed its load balancer and released port 22
  # of the GitLab IP.
  wait = true

  depends_on = [
    terraform_data.gateway_api_checks,
    kubernetes_namespace.gitlab_namespace,
  ]
}

# GKE creates the network endpoint groups shortly after the Service.
resource "time_sleep" "gitlab_shell_neg" {
  count = var.gitlab_enable_shell_load_balancer ? 1 : 0

  create_duration = "60s"

  triggers = {
    service_uid = kubectl_manifest.gitlab_shell_load_balancer[0].uid
  }
}

data "kubernetes_resource" "gitlab_shell_neg" {
  count = var.gitlab_enable_shell_load_balancer ? 1 : 0

  api_version = "v1"
  kind        = "Service"

  metadata {
    name      = local.shell_neg_service_name
    namespace = var.gitlab_namespace
  }

  depends_on = [time_sleep.gitlab_shell_neg]
}

resource "google_compute_region_health_check" "gitlab_shell" {
  count = var.gitlab_enable_shell_load_balancer ? 1 : 0

  name               = "gitlab-shell"
  region             = var.region
  check_interval_sec = 10
  timeout_sec        = 5

  tcp_health_check {
    port_specification = "USE_SERVING_PORT"
  }

  depends_on = [module.project_services.project_id]
}

resource "google_compute_region_backend_service" "gitlab_shell" {
  count = var.gitlab_enable_shell_load_balancer ? 1 : 0

  name                  = "gitlab-shell"
  region                = var.region
  protocol              = "TCP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  health_checks         = [google_compute_region_health_check.gitlab_shell[0].id]
  # On a proxy Network Load Balancer this is the idle timeout of a connection.
  timeout_sec = var.gitlab_shell_load_balancer_idle_timeout_sec
  # Time a pod that leaves the load balancer has to finish its Git operations.
  connection_draining_timeout_sec = 30

  # The groups are referenced by name: GKE owns them, and a data source would
  # fail the plan before the Service exists. A zone that gets its first node
  # later is added by the next apply.
  dynamic "backend" {
    for_each = local.shell_neg_zones

    content {
      group          = "https://www.googleapis.com/compute/v1/projects/${var.project_id}/zones/${backend.value}/networkEndpointGroups/${local.shell_neg_name}"
      balancing_mode = "CONNECTION"
      # Balancing target, not a limit.
      max_connections_per_endpoint = 100
      capacity_scaler              = 1
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.shell_neg_zones) > 0
      error_message = "GKE has not reported the GitLab Shell network endpoint groups on the ${local.shell_neg_service_name} Service yet. Apply again."
    }
  }
}

resource "google_compute_region_target_tcp_proxy" "gitlab_shell" {
  count = var.gitlab_enable_shell_load_balancer ? 1 : 0

  name            = "gitlab-shell"
  region          = var.region
  backend_service = google_compute_region_backend_service.gitlab_shell[0].id
  # OpenSSH, the chart's default SSH daemon, does not read the PROXY protocol.
  proxy_header = "NONE"
}

resource "google_compute_forwarding_rule" "gitlab_shell" {
  count = var.gitlab_enable_shell_load_balancer ? 1 : 0

  name                  = "gitlab-shell"
  region                = var.region
  load_balancing_scheme = "EXTERNAL_MANAGED"
  network_tier          = "PREMIUM"
  ip_protocol           = "TCP"
  port_range            = "22"
  ip_address            = local.gitlab_address
  network               = google_compute_network.gitlab.id
  target                = google_compute_region_target_tcp_proxy.gitlab_shell[0].id

  depends_on = [
    google_compute_subnetwork.proxy_only,
    # A release that removes the NGINX Ingress frees port 22 of the GitLab IP.
    helm_release.gitlab,
  ]
}

# The load balancer proxies connect from the proxy-only subnet, the health
# check probes from the Google ranges.
resource "google_compute_firewall" "gitlab_shell_load_balancer" {
  count = var.gitlab_enable_shell_load_balancer ? 1 : 0

  name          = "gitlab-shell-load-balancer"
  description   = "GitLab Shell load balancer and its health checks to the GKE nodes"
  network       = google_compute_network.gitlab.name
  direction     = "INGRESS"
  source_ranges = compact([var.gke_proxy_only_subnet_cidr, "35.191.0.0/16", "130.211.0.0/22"])

  target_service_accounts = local.shell_node_service_accounts

  allow {
    protocol = "tcp"
    ports    = [tostring(local.shell_container_port)]
  }

  depends_on = [terraform_data.gateway_api_checks]
}
