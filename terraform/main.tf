# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# a2a-gate Terraform module — provisions a 4-node VPC on DigitalOcean
# for the AI-to-AI integration gate.
#
# Each campaign runs ONE homogeneous agent group: every agent droplet
# runs the SAME framework (either all OpenClaw or all Hermes). This
# isolates framework-specific regressions — an OpenClaw-only campaign
# that fails while a Hermes-only campaign passes points at the
# OpenClaw MCP client implementation, not at ai-memory.
#
# Topology per campaign (4 droplets):
#   node-1: agent (ai:alice)   — agent_type={ironclaw|hermes|openclaw-legacy}
#   node-2: agent (ai:bob)     — agent_type={ironclaw|hermes|openclaw-legacy}
#   node-3: agent (ai:charlie) — agent_type={ironclaw|hermes|openclaw-legacy}
#   node-4: ai-memory serve authoritative
#
# Two campaigns per release = 8 droplets total, two separate runs:
#   a2a-openclaw-<release>-rN  → 4 droplets, all OpenClaw agents
#   a2a-hermes-<release>-rN    → 4 droplets, all Hermes agents
#
# VPC CIDRs partitioned by agent_type (see local.vpc_cidr below) so
# concurrent campaigns don't collide. All distinct from ship-gate's
# 10.250.0.0/24.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

variable "do_token" {
  type        = string
  sensitive   = true
  description = "DigitalOcean API token."
}

variable "ssh_key_fingerprint" {
  type        = string
  description = "SHA-256 fingerprint of the SSH key (already registered with DO)."
}

variable "campaign_id" {
  type        = string
  description = "Unique identifier for this campaign run. Droplet names include this."
}

variable "agent_type" {
  type        = string
  description = "Agent framework for every agent droplet in this campaign. Must be ironclaw, hermes, or (legacy) openclaw."
  validation {
    condition     = contains(["ironclaw", "hermes", "openclaw"], var.agent_type)
    error_message = "agent_type must be \"ironclaw\", \"hermes\", or \"openclaw\" (legacy)."
  }
}

variable "region" {
  type    = string
  default = "nyc3"
}

variable "agent_droplet_size" {
  type        = string
  default     = "s-2vcpu-4gb"
  description = "Size for the three agent droplets. Bump to s-4vcpu-16gb for scenario 8 (Ollama auto-tagging)."
}

variable "memory_droplet_size" {
  type        = string
  default     = "s-2vcpu-4gb"
  description = "Size for node-4 (ai-memory authoritative store)."
}

variable "ai_memory_git_ref" {
  type        = string
  default     = "v0.6.0"
  description = "ai-memory-mcp release to validate against."
}

variable "tls_mode" {
  type        = string
  default     = "off"
  description = "Transport mode (off|tls|mtls). Participates in VPC CIDR allocation so N same-agent_type campaigns with different tls_mode can be in-flight simultaneously without VPC collision."
  validation {
    condition     = contains(["off", "tls", "mtls"], var.tls_mode)
    error_message = "tls_mode must be \"off\", \"tls\", or \"mtls\"."
  }
}

provider "digitalocean" {
  token = var.do_token
}

locals {
  # Per-(agent_type × tls_mode) VPC CIDR. DO rejects a VPC create when
  # its IP range overlaps ANY existing VPC in the account, including
  # DO's own region-default VPCs. We observed 10.252.0.0/24 colliding
  # with nyc3's default VPC (default-subnet-for-vpc-6241e85f) on
  # 2026-04-22, meaning hermes runs would have failed independent of
  # any sibling campaign activity.
  #
  # Move all CIDRs into 10.10-13.x.0/24 — far from DO's typical
  # default VPC ranges (10.108.x, 10.124.x, 10.252.x seen in practice)
  # AND far from ship-gate's 10.250.0.0/24.
  # Second octet = 10 + agent_type index (10 ironclaw, 11 hermes,
  # 12 openclaw, 13 mixed). Third octet = tls_mode index
  # (0 off, 1 tls, 2 mtls).
  vpc_cidr = {
    "ironclaw|off"  = "10.10.0.0/24"
    "ironclaw|tls"  = "10.10.1.0/24"
    "ironclaw|mtls" = "10.10.2.0/24"
    "hermes|off"    = "10.11.0.0/24"
    "hermes|tls"    = "10.11.1.0/24"
    "hermes|mtls"   = "10.11.2.0/24"
    "openclaw|off"  = "10.12.0.0/24"
    "openclaw|tls"  = "10.12.1.0/24"
    "openclaw|mtls" = "10.12.2.0/24"
    "mixed|off"     = "10.13.0.0/24"
    "mixed|tls"     = "10.13.1.0/24"
    "mixed|mtls"    = "10.13.2.0/24"
  }
  cidr_key = "${var.agent_type}|${var.tls_mode}"
}

resource "digitalocean_vpc" "a2a" {
  # Include tls_mode in the VPC name to make the mapping visible in DO's
  # UI and so two same-agent_type campaigns never collide on name either.
  name     = "aim-a2a-${var.agent_type}-${var.tls_mode}-${var.campaign_id}"
  region   = var.region
  ip_range = lookup(local.vpc_cidr, local.cidr_key, "10.251.0.0/24")
}

# Three agent droplets — all the same agent_type. Distinct agent_ids
# assigned deterministically: node-1 → ai:alice, node-2 → ai:bob,
# node-3 → ai:charlie. Three distinct IDs remain a hard requirement
# because scenarios 6 (contradiction) and 7 (scoping) need an
# uninvolved third party; same-framework-three-agents still
# satisfies that.
resource "digitalocean_droplet" "agent_node" {
  for_each = toset(["node-1", "node-2", "node-3"])

  name     = "aim-a2a-${var.agent_type}-${var.campaign_id}-${each.key}"
  image    = "ubuntu-24-04-x64"
  region   = var.region
  size     = var.agent_droplet_size
  vpc_uuid = digitalocean_vpc.a2a.id
  ssh_keys = [var.ssh_key_fingerprint]

  tags = [
    "ai-memory-a2a-gate",
    "agent-group-${var.agent_type}",
    "campaign-${replace(var.campaign_id, ".", "-")}",
  ]
}

resource "digitalocean_droplet" "memory_node" {
  name     = "aim-a2a-${var.agent_type}-${var.campaign_id}-node-4"
  image    = "ubuntu-24-04-x64"
  region   = var.region
  size     = var.memory_droplet_size
  vpc_uuid = digitalocean_vpc.a2a.id
  ssh_keys = [var.ssh_key_fingerprint]

  tags = [
    "ai-memory-a2a-gate",
    "agent-group-${var.agent_type}",
    "campaign-${replace(var.campaign_id, ".", "-")}",
    "memory-authoritative",
  ]
}

resource "digitalocean_firewall" "a2a" {
  name = "aim-a2a-${var.agent_type}-${var.campaign_id}"

  droplet_ids = concat(
    [for d in digitalocean_droplet.agent_node : d.id],
    [digitalocean_droplet.memory_node.id],
  )

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "9077"
    source_addresses = [digitalocean_vpc.a2a.ip_range]
  }

  inbound_rule {
    protocol         = "icmp"
    source_addresses = [digitalocean_vpc.a2a.ip_range]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "all"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "udp"
    port_range            = "all"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

output "agents" {
  value = {
    for name, d in digitalocean_droplet.agent_node :
    name => {
      agent_id = (
        name == "node-1" ? "ai:alice" :
        name == "node-2" ? "ai:bob" :
        "ai:charlie"
      )
      agent_type = var.agent_type
      public     = d.ipv4_address
      private    = d.ipv4_address_private
    }
  }
}

output "memory_node" {
  value = {
    public  = digitalocean_droplet.memory_node.ipv4_address
    private = digitalocean_droplet.memory_node.ipv4_address_private
  }
}

output "agent_type" {
  value = var.agent_type
}

output "vpc_id" {
  value = digitalocean_vpc.a2a.id
}
