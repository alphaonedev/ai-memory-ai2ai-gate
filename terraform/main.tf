# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# a2a-gate Terraform module — provisions a 4-node VPC on DigitalOcean
# for the AI-to-AI integration gate:
#
#   node-1: OpenClaw agent (ai:alice)
#   node-2: Hermes agent (ai:bob)
#   node-3: OpenClaw agent (ai:charlie)
#   node-4: ai-memory serve (authoritative store)
#
# VPC CIDR is 10.260.0.0/24 — intentionally distinct from the
# ship-gate's 10.250.0.0/24 so concurrent campaigns across accounts
# don't conflict.

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
  description = "SHA-256 fingerprint of the SSH key (already registered with DO) that the runner will use for control-plane access."
}

variable "campaign_id" {
  type        = string
  description = "Unique identifier for this campaign run. Used as the droplet-name prefix."
}

variable "region" {
  type    = string
  default = "nyc3"
}

variable "agent_droplet_size" {
  type        = string
  default     = "s-2vcpu-4gb"
  description = "Size for the three agent droplets (node-1/2/3). Bump to s-4vcpu-16gb when exercising scenario 8 (auto-tagging) so Ollama + Gemma 4 E2B fit."
}

variable "memory_droplet_size" {
  type        = string
  default     = "s-2vcpu-4gb"
  description = "Size for the authoritative ai-memory droplet (node-4)."
}

variable "ai_memory_git_ref" {
  type        = string
  default     = "release/v0.6.0"
  description = "ai-memory-mcp git ref to validate."
}

provider "digitalocean" {
  token = var.do_token
}

resource "digitalocean_vpc" "a2a" {
  name     = "aim-a2a-${var.campaign_id}"
  region   = var.region
  ip_range = "10.260.0.0/24"
}

resource "digitalocean_droplet" "agent_node" {
  for_each = {
    "node-1" = { agent = "openclaw", agent_id = "ai:alice" },
    "node-2" = { agent = "hermes", agent_id = "ai:bob" },
    "node-3" = { agent = "openclaw", agent_id = "ai:charlie" },
  }

  name     = "aim-a2a-${var.campaign_id}-${each.key}"
  image    = "ubuntu-24-04-x64"
  region   = var.region
  size     = var.agent_droplet_size
  vpc_uuid = digitalocean_vpc.a2a.id
  ssh_keys = [var.ssh_key_fingerprint]

  tags = [
    "ai-memory-a2a-gate",
    "campaign-${var.campaign_id}",
    "agent-${each.value.agent}",
  ]
}

resource "digitalocean_droplet" "memory_node" {
  name     = "aim-a2a-${var.campaign_id}-node-4"
  image    = "ubuntu-24-04-x64"
  region   = var.region
  size     = var.memory_droplet_size
  vpc_uuid = digitalocean_vpc.a2a.id
  ssh_keys = [var.ssh_key_fingerprint]

  tags = [
    "ai-memory-a2a-gate",
    "campaign-${var.campaign_id}",
    "memory-authoritative",
  ]
}

resource "digitalocean_firewall" "a2a" {
  name = "aim-a2a-${var.campaign_id}"

  droplet_ids = concat(
    [for d in digitalocean_droplet.agent_node : d.id],
    [digitalocean_droplet.memory_node.id],
  )

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # ai-memory HTTP on port 9077 — VPC-only. Agents reach node-4
  # across the private network; nothing outside the VPC talks to
  # 9077.
  inbound_rule {
    protocol         = "tcp"
    port_range       = "9077"
    source_addresses = ["10.260.0.0/24"]
  }

  # ICMP for diagnostics inside the VPC.
  inbound_rule {
    protocol         = "icmp"
    source_addresses = ["10.260.0.0/24"]
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
      agent = (
        name == "node-2" ? "hermes" : "openclaw"
      )
      public  = d.ipv4_address
      private = d.ipv4_address_private
    }
  }
}

output "memory_node" {
  value = {
    public  = digitalocean_droplet.memory_node.ipv4_address
    private = digitalocean_droplet.memory_node.ipv4_address_private
  }
}

output "vpc_id" {
  value = digitalocean_vpc.a2a.id
}
