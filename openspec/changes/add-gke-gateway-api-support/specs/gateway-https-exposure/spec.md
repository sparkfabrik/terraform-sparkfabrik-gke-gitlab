# Spec Delta

## Purpose

Exposes GitLab HTTPS traffic through a GKE regional Application Load Balancer in front of the chart's bundled Envoy Gateway, so a Cloud Armor policy can protect it, while deployments that do not opt in keep the NGINX Ingress unchanged.

## ADDED Requirements

### Requirement: Default inputs leave existing deployments unchanged

With every new input at its default, the module SHALL produce no changes for a deployment created by the previous release, and SHALL NOT create any Gateway API, Certificate Manager, proxy-only subnet or Envoy CRD resource.

#### Scenario: Upgrade with default inputs

- **WHEN** a consumer upgrades from the previous module release without setting any new input
- **THEN** `terraform plan` reports no changes to existing resources and no new resources

### Requirement: Gateway API on the cluster

The module SHALL let the consumer enable the GKE Gateway API standard channel on the cluster. It SHALL NOT offer the experimental channel.

#### Scenario: Standard channel enabled

- **WHEN** the consumer enables Gateway API on the cluster
- **THEN** the cluster's Gateway API configuration is the standard channel

#### Scenario: Experimental channel rejected

- **WHEN** the consumer sets the channel input to a value other than standard or disabled
- **THEN** `terraform plan` fails with a validation error

### Requirement: Proxy-only subnet

When the consumer provides a proxy-only subnet CIDR, the module SHALL create an active regional managed proxy subnet in the GitLab VPC and region. The module SHALL NOT create firewall rules for it, because the GKE Gateway controller creates the rule that admits the subnet and Google health checks.

#### Scenario: Subnet created

- **WHEN** the consumer sets a proxy-only subnet CIDR
- **THEN** the VPC has an active regional managed proxy subnet with that CIDR

#### Scenario: Load balancer traffic admitted

- **WHEN** the GKE Gateway is created on the GitLab VPC
- **THEN** a firewall rule created by GKE admits the proxy-only subnet and the Google health check ranges, and the Envoy backends report healthy

### Requirement: Regional load balancer in front of Envoy

When the consumer enables the GKE Gateway, the module SHALL create a Gateway of class `gke-l7-regional-external-managed` that listens for HTTPS on port 443 at the existing GitLab IP and routes all GitLab HTTPS hosts to the bundled Envoy Gateway.

#### Scenario: HTTPS served on the GitLab IP

- **WHEN** the GKE Gateway is enabled and the certificate is active
- **THEN** HTTPS requests to the GitLab host and the KAS host on the GitLab IP reach GitLab through the load balancer and Envoy

### Requirement: HTTP redirected to HTTPS

When the GKE Gateway is enabled, plain HTTP requests on port 80 at the GitLab IP SHALL receive a redirect to the same URL over HTTPS.

#### Scenario: HTTP request

- **WHEN** a client requests `http://<gitlab host>/explore`
- **THEN** the response redirects to `https://<gitlab host>/explore`

### Requirement: Backend health check and timeout

The load balancer SHALL check Envoy health on path `/ready`, port `19003`, and SHALL apply the backend timeout set by the consumer, defaulting to 3600 seconds.

#### Scenario: Envoy pods healthy

- **WHEN** the Envoy pods are ready
- **THEN** the load balancer reports the Envoy backends as healthy

#### Scenario: Default backend timeout

- **WHEN** the consumer enables the GKE Gateway without setting a backend timeout
- **THEN** the load balancer backend timeout is 3600 seconds

#### Scenario: Custom backend timeout

- **WHEN** the consumer sets a backend timeout
- **THEN** the load balancer backend uses that timeout

### Requirement: Cloud Armor policy attachment

The module SHALL attach a regional Cloud Armor security policy, passed by name, to the Envoy backend. It SHALL NOT create or change the policy. When no policy name is given, the load balancer SHALL serve traffic without a policy.

#### Scenario: Policy attached

- **WHEN** the consumer passes the name of a regional policy in the same project and region
- **THEN** requests matching a deny rule in that policy receive the rule's deny status and other requests reach GitLab

#### Scenario: No policy

- **WHEN** the consumer passes no policy name
- **THEN** the load balancer serves GitLab without a security policy

### Requirement: Regional certificate for served hosts

When the consumer enables the gateway certificate, the module SHALL create one regional Google-managed Certificate Manager certificate covering exactly the hosts GitLab serves: the GitLab host, the KAS host when KAS is installed, and the registry host when the registry is enabled. The Gateway SHALL use it for TLS.

#### Scenario: Certificate created while NGINX serves traffic

- **WHEN** the consumer enables the gateway certificate and keeps the NGINX Ingress enabled
- **THEN** the apply creates the certificate and NGINX keeps serving traffic

#### Scenario: Hosts follow enabled components

- **WHEN** KAS is installed and the registry is disabled
- **THEN** the certificate covers the GitLab host and the KAS host, and no other names

### Requirement: DNS authorization records output

The module SHALL create one DNS authorization per certificate host and SHALL output, per host, the CNAME record name, type and value that the DNS owner must create. The output SHALL remain stable across applies unless an authorization is replaced.

#### Scenario: Records published

- **WHEN** the gateway certificate is enabled
- **THEN** the module output lists one CNAME record per certificate host

#### Scenario: Certificate becomes active before traffic moves

- **WHEN** the DNS owner creates the output records while DNS for the GitLab hosts still points elsewhere
- **THEN** the certificate becomes active without traffic reaching the load balancer

### Requirement: Encoded slashes preserved

Requests SHALL reach GitLab with URL-encoded slashes (`%2F`) in the path unchanged.

#### Scenario: Project path in API request

- **WHEN** a client requests `/api/v4/projects/group%2Fproject`
- **THEN** GitLab receives the path with `%2F` unchanged and no redirect is returned

### Requirement: Real client IP and protocol

GitLab SHALL see the original client IP and the HTTPS scheme for requests that arrive through the load balancer.

#### Scenario: Client IP recorded

- **WHEN** a client makes a request through the load balancer
- **THEN** GitLab records the client's public IP, not a proxy-only subnet or load balancer address

#### Scenario: HTTPS scheme preserved

- **WHEN** a client makes an HTTPS request through the load balancer
- **THEN** GitLab treats the request as HTTPS and generates `https` URLs

### Requirement: KAS WebSocket and gRPC

The load balancer SHALL carry KAS WebSocket upgrades over HTTP/1.1 and KAS gRPC over HTTP/2 on the same KAS host.

#### Scenario: Agent connects

- **WHEN** a GitLab agent connects to the KAS host over WebSocket
- **THEN** the connection upgrades and stays open

#### Scenario: gRPC call

- **WHEN** a client makes a gRPC call to the KAS host
- **THEN** the call completes with `grpc-status: 0`

### Requirement: Conflicting configuration rejected

The module SHALL reject configurations where the GKE Gateway or the SSH load balancer is enabled together with the NGINX Ingress, or with a GitLab chart version earlier than 10.3, or where the GKE Gateway is enabled without Gateway API on the cluster, the proxy-only subnet, the gateway certificate or the chart's Envoy Gateway.

#### Scenario: NGINX still enabled

- **WHEN** the consumer enables the GKE Gateway and keeps the NGINX Ingress enabled
- **THEN** `terraform plan` fails with an error naming both inputs

#### Scenario: Chart too old

- **WHEN** the consumer enables the GKE Gateway with a chart version earlier than 10.3
- **THEN** `terraform plan` fails with an error stating the minimum chart version

### Requirement: Chart Ingresses can be turned off

The chart's Ingress resources SHALL follow a module input that defaults to enabled, so a deployment behind the GKE Gateway can stop rendering Ingresses that no controller serves.

#### Scenario: Ingresses disabled

- **WHEN** the consumer sets the Ingress input to `false`
- **THEN** the GitLab release renders no Ingress resources and cert-manager creates no certificates for them

#### Scenario: Ingresses by default

- **WHEN** the consumer does not set the Ingress input
- **THEN** the GitLab release renders its Ingress resources as before

### Requirement: cert-manager on Ingresses follows its input

The chart's Ingress cert-manager integration SHALL follow `gitlab_enable_certmanager`.

#### Scenario: cert-manager disabled

- **WHEN** the consumer sets `gitlab_enable_certmanager` to `false`
- **THEN** the chart does not configure cert-manager for Ingresses
