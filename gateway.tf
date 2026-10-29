# GitLab behind a GKE regional Application Load Balancer and the chart's
# bundled Envoy Gateway. Every resource in this file is opt-in, so default
# inputs leave existing deployments unchanged.

locals {
  gke_gateway_enabled = var.gitlab_gke_gateway != null
  envoy_enabled       = var.gitlab_enable_gateway_api && var.gitlab_gateway_api_install_envoy

  helm_chart_version_parts = split(".", var.helm_chart_version)
  helm_chart_major         = try(tonumber(local.helm_chart_version_parts[0]), 0)
  helm_chart_minor         = try(tonumber(local.helm_chart_version_parts[1]), 0)
  # Chart 10.3 is the first release that uses only standard channel Gateway
  # API resources and lets the webservice ClientTrafficPolicy be overridden.
  helm_chart_supports_gke_gateway = local.helm_chart_major > 10 || (local.helm_chart_major == 10 && local.helm_chart_minor >= 3)
}

# Cross-input checks. Variable validations cannot reference other inputs on
# the Terraform versions this module supports, so they live here.
resource "terraform_data" "gateway_api_checks" {
  count = local.gke_gateway_enabled || var.gitlab_shell_load_balancer ? 1 : 0

  lifecycle {
    precondition {
      condition     = !var.gitlab_install_ingress_nginx
      error_message = "gitlab_gke_gateway and gitlab_shell_load_balancer require gitlab_install_ingress_nginx = false: the NGINX Ingress holds the same IP on ports 22 to 443."
    }

    precondition {
      condition     = local.helm_chart_supports_gke_gateway
      error_message = "gitlab_gke_gateway and gitlab_shell_load_balancer require helm_chart_version 10.3 or later, got ${var.helm_chart_version}."
    }

    precondition {
      condition     = !local.gke_gateway_enabled || var.gke_gateway_api_channel == "CHANNEL_STANDARD"
      error_message = "gitlab_gke_gateway requires gke_gateway_api_channel = \"CHANNEL_STANDARD\"."
    }

    precondition {
      condition     = !local.gke_gateway_enabled || var.gitlab_proxy_only_subnet_cidr != null
      error_message = "gitlab_gke_gateway requires gitlab_proxy_only_subnet_cidr."
    }

    precondition {
      condition     = !local.gke_gateway_enabled || var.gitlab_gateway_certificate_enabled
      error_message = "gitlab_gke_gateway requires gitlab_gateway_certificate_enabled = true."
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
  workhorse_trusted_cidrs = local.gke_gateway_enabled ? compact([var.gitlab_proxy_only_subnet_cidr, "${local.gitlab_address}/32"]) : []

  # The hosts the chart serves, as the chart names them by default.
  gitlab_host   = "gitlab.${local.domain}"
  kas_host      = var.gitlab_install_kas ? (local.kas_domain != "" ? local.kas_domain : "kas.${local.domain}") : ""
  registry_host = var.gitlab_enable_registry ? "registry.${local.domain}" : ""

  # Keyed by role, so the keys are known at plan time even when the domain
  # is derived from the GitLab IP.
  gateway_certificate_hosts = var.gitlab_gateway_certificate_enabled ? merge(
    { gitlab = local.gitlab_host },
    var.gitlab_install_kas ? { kas = local.kas_host } : {},
    var.gitlab_enable_registry ? { registry = local.registry_host } : {},
  ) : {}
}

# Proxy-only subnet for the regional Application Load Balancer. The GKE
# Gateway controller creates the firewall rule that admits it.
resource "google_compute_subnetwork" "proxy_only" {
  count = var.gitlab_proxy_only_subnet_cidr != null ? 1 : 0

  name          = "gitlab-proxy-only"
  ip_cidr_range = var.gitlab_proxy_only_subnet_cidr
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
}

resource "google_certificate_manager_certificate" "gitlab" {
  count = var.gitlab_gateway_certificate_enabled ? 1 : 0

  # The host list is part of the name, so a host change creates the new
  # certificate before the Gateway stops using the old one.
  name        = "gitlab-gateway-${substr(sha1(join(",", values(local.gateway_certificate_hosts))), 0, 8)}"
  location    = var.region
  description = "GitLab GKE Gateway certificate"

  managed {
    domains            = values(local.gateway_certificate_hosts)
    dns_authorizations = [for role in keys(local.gateway_certificate_hosts) : google_certificate_manager_dns_authorization.gitlab[role].id]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Envoy Gateway CRDs, taken from the configured GitLab chart version.
locals {
  # The CRD render only needs values that pass the chart's configuration
  # checks. Values that stay unknown until apply on a new deployment are
  # replaced, so the render and the CRD keys are known at plan time.
  envoy_crds_render_values = templatefile("${path.module}/values.yaml", merge(local.gitlab_release_helm_values_vars, {
    DOMAIN                  = "example.com"
    KAS_DOMAIN              = ""
    INGRESS_IP              = "192.0.2.1"
    DB_PRIVATE_IP           = "192.0.2.2"
    REDIS_PRIVATE_IP        = "192.0.2.3"
    WORKHORSE_TRUSTED_CIDRS = []
    ARTIFACTS_BCKT          = "placeholder"
    BACKUP_BCKT             = "placeholder"
    DEP_PROXY_BCKT          = "placeholder"
    EXT_DIFF_BCKT           = "placeholder"
    LFS_BCKT                = "placeholder"
    PACKAGES_BCKT           = "placeholder"
    REGISTRY_BCKT           = "placeholder"
    RUNNER_CACHE_BCKT       = "placeholder"
    TERRAFORM_BCKT          = "placeholder"
    BACKUP_TMP_BCKT         = "placeholder"
    UPLOADS_BCKT            = "placeholder"
  }))

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

  name         = "gitlab"
  namespace    = var.gitlab_namespace
  repository   = "https://charts.gitlab.io"
  chart        = "gitlab"
  version      = var.helm_chart_version
  include_crds = true

  values = [local.envoy_crds_render_values]

  set {
    name  = "envoy-gateway.crds.enabled"
    value = "true"
  }
}

resource "kubectl_manifest" "envoy_crds" {
  for_each = local.envoy_crds

  yaml_body = each.value
  # Server-side apply has no size limit on the last-applied annotation, and
  # force takes ownership from a release that installed the CRDs earlier.
  server_side_apply = true
  force_conflicts   = true
}

# GKE Gateway in front of Envoy.
locals {
  gke_gateway_name = "gitlab-gke"
  # Gateway created by the chart for Envoy Gateway, see gitlab.gatewayApi.gateway.name.default.
  envoy_gateway_name = "${helm_release.gitlab.name}-gw"

  # Two Services on the same Envoy port: the chart gives every HTTP listener
  # port 80, and a Service port has a single appProtocol. The load balancer
  # uses HTTP/1.1 for KAS WebSocket and HTTP/2 for KAS gRPC.
  envoy_backends = local.gke_gateway_enabled ? {
    http = { name = "gitlab-envoy-http", app_protocol = null }
    h2c  = { name = "gitlab-envoy-h2c", app_protocol = "kubernetes.io/h2c" }
  } : {}
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
          targetPort = 10080 # Envoy Gateway maps listener ports below 1024 to port + 10000
        },
        each.value.app_protocol != null ? { appProtocol = each.value.app_protocol } : {}
      )]
    }
  })
  server_side_apply = true
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
        var.gitlab_gke_gateway.security_policy != null ? { securityPolicy = var.gitlab_gke_gateway.security_policy } : {}
      )
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
              "networking.gke.io/cert-manager-certs" = google_certificate_manager_certificate.gitlab[0].name
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

  depends_on = [
    terraform_data.gateway_api_checks,
    google_compute_subnetwork.proxy_only,
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

  depends_on = [kubectl_manifest.gke_gateway]
}

# GitLab Shell on its own regional L4 load balancer, sharing the GitLab IP
# with the GKE Gateway on a different port.
resource "kubectl_manifest" "gitlab_shell_load_balancer" {
  count = var.gitlab_shell_load_balancer ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "gitlab-shell-lb"
      namespace = var.gitlab_namespace
      annotations = {
        "networking.gke.io/load-balancer-ip-addresses" = local.gitlab_address_name
        "cloud.google.com/network-tier"                = "Premium"
      }
    }
    spec = {
      type              = "LoadBalancer"
      loadBalancerClass = "networking.gke.io/l4-regional-external"
      selector = {
        app     = "gitlab-shell"
        release = helm_release.gitlab.name
      }
      ports = [{
        name       = "ssh"
        port       = 22
        protocol   = "TCP"
        targetPort = 2222
      }]
    }
  })
  server_side_apply = true

  depends_on = [terraform_data.gateway_api_checks]
}
