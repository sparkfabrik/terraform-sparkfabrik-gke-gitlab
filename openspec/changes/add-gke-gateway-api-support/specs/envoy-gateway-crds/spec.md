# Spec Delta

## Purpose

Keeps the Envoy Gateway CRDs that the GitLab chart's bundled Envoy Gateway needs installed and current on GKE clusters, where GKE manages the Gateway API CRDs and rejects the chart's own bundle.

## ADDED Requirements

### Requirement: Envoy CRDs installed when Envoy is bundled

When the GitLab chart's Envoy Gateway is installed through the module, the module SHALL install every `gateway.envoyproxy.io` CRD shipped with the configured GitLab chart version before installing or upgrading the GitLab release.

#### Scenario: First install

- **WHEN** a consumer enables the bundled Envoy Gateway on a cluster with no Envoy CRDs
- **THEN** all Envoy Gateway CRDs from the configured chart version exist before the GitLab release is installed, and the release installs without missing-kind errors

### Requirement: CRD versions follow the chart version

The installed Envoy CRDs SHALL match the Envoy Gateway version bundled by the configured GitLab chart version, without a module release being required for a chart upgrade.

#### Scenario: Chart upgrade bumps Envoy

- **WHEN** the consumer raises the GitLab chart version to one bundling a newer Envoy Gateway
- **THEN** the same apply updates the Envoy CRDs to that version before the GitLab release upgrades

### Requirement: Gateway API CRDs left to GKE

The module SHALL NOT install, update or delete any `gateway.networking.k8s.io` CRD, and the GitLab release SHALL NOT install the chart's bundled CRDs.

#### Scenario: GKE admission policy respected

- **WHEN** the bundled Envoy Gateway is enabled on a cluster with GKE-managed Gateway API CRDs
- **THEN** the apply completes without any request denied by the GKE Gateway API admission policy

### Requirement: CRDs applied without size limits

The module SHALL apply the Envoy CRDs with server-side apply, so the size of a CRD or of the full set never blocks the install.

#### Scenario: Large CRD

- **WHEN** the module installs the `envoyproxies` CRD, which exceeds 1 MiB
- **THEN** the install succeeds

### Requirement: Safe removal order

When the consumer disables the bundled Envoy Gateway, the module SHALL remove the GitLab release's Envoy resources before deleting the Envoy CRDs.

#### Scenario: Feature disabled

- **WHEN** the consumer disables the bundled Envoy Gateway
- **THEN** the apply completes without errors about CRDs deleted while resources still use them
