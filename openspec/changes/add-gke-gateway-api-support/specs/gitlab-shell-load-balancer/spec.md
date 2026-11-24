# Spec Delta

## Purpose

Exposes GitLab Shell (git over SSH) on its own regional proxy Network Load Balancer that shares the GitLab IP, because the GKE Gateway carries only HTTP traffic.

## ADDED Requirements

### Requirement: SSH on its own load balancer

When the consumer enables the SSH load balancer, the module SHALL expose GitLab Shell on TCP port 22 of the GitLab IP through a regional external proxy Network Load Balancer whose backends are network endpoint groups of the GitLab Shell pods.

#### Scenario: Git over SSH

- **WHEN** the SSH load balancer is enabled and a user runs `git clone git@<gitlab host>:<group>/<project>.git`
- **THEN** the clone succeeds over port 22 on the GitLab IP

### Requirement: Shared IP with HTTPS

The SSH load balancer and the GKE Gateway SHALL use the same GitLab IP at the same time, on different ports, so clone URLs and DNS records do not change.

#### Scenario: Both enabled

- **WHEN** the SSH load balancer and the GKE Gateway are both enabled
- **THEN** port 22 on the GitLab IP serves SSH and port 443 serves HTTPS

### Requirement: GitLab IP reachable from the cluster

The module SHALL NOT create a Kubernetes Service that holds the GitLab IP, so pods in the GitLab cluster reach every port of the GitLab IP through the Google load balancers.

#### Scenario: CI job in the GitLab cluster

- **WHEN** the SSH load balancer and the GKE Gateway are both enabled and a pod in the GitLab cluster connects to the GitLab host
- **THEN** HTTPS on port 443 and SSH on port 22 both answer

### Requirement: Idle SSH connections

The module SHALL let the consumer set the idle timeout of the SSH load balancer, with a default of 3600 seconds.

#### Scenario: Default timeout

- **WHEN** the SSH load balancer is enabled and the timeout input is not set
- **THEN** the load balancer keeps a connection that carries no data open for 3600 seconds

### Requirement: No TCP route required

The module SHALL NOT rely on a Gateway API `TCPRoute` for SSH, and the GitLab release SHALL NOT render one when the SSH load balancer is enabled.

#### Scenario: Release on GKE-managed CRDs

- **WHEN** the SSH load balancer is enabled on a cluster whose Gateway API CRDs do not serve `TCPRoute`
- **THEN** the GitLab release installs without errors about a missing `TCPRoute` kind
