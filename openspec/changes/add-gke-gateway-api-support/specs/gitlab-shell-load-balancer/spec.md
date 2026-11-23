# Spec Delta

## Purpose

Exposes GitLab Shell (git over SSH) on its own regional L4 load balancer that shares the GitLab IP, because the GKE Gateway carries only HTTP traffic.

## ADDED Requirements

### Requirement: SSH on its own load balancer

When the consumer enables the SSH load balancer, the module SHALL expose GitLab Shell on TCP port 22 through a regional external L4 `LoadBalancer` Service that uses the GitLab IP.

#### Scenario: Git over SSH

- **WHEN** the SSH load balancer is enabled and a user runs `git clone git@<gitlab host>:<group>/<project>.git`
- **THEN** the clone succeeds over port 22 on the GitLab IP

### Requirement: Shared IP with HTTPS

The SSH load balancer and the GKE Gateway SHALL use the same GitLab IP at the same time, on different ports, so clone URLs and DNS records do not change.

#### Scenario: Both enabled

- **WHEN** the SSH load balancer and the GKE Gateway are both enabled
- **THEN** port 22 on the GitLab IP serves SSH and port 443 serves HTTPS

### Requirement: No TCP route required

The module SHALL NOT rely on a Gateway API `TCPRoute` for SSH, and the GitLab release SHALL NOT render one when the SSH load balancer is enabled.

#### Scenario: Release on GKE-managed CRDs

- **WHEN** the SSH load balancer is enabled on a cluster whose Gateway API CRDs do not serve `TCPRoute`
- **THEN** the GitLab release installs without errors about a missing `TCPRoute` kind
