#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Host-side nft rules to allow Docker subnet forwarding on systems with
# a restrictive `inet filter forward` policy=drop (e.g. CCC Gateway
# topology on this workstation). Without these, container outbound
# traffic reaches the bridge but is silently dropped before reaching
# the external NIC (verified via tcpdump — SYNs never egress).
#
# Applies the minimum four accepts needed:
#   10.88.0.0/16  — Docker compose user-defined bridges (mesh/test)
#   172.17.0.0/16 — Docker default bridge (docker0)
#
# NOT persistent across reboot. Re-run after `systemctl restart
# nftables` or a full boot. For permanent install, append to
# /etc/nftables.conf or a systemd dropin.
set -eu
log() { printf '[host-nft-docker-forward] %s\n' "$*" >&2; }

command -v nft >/dev/null || { log "nft not installed"; exit 1; }

# Idempotent insert — nft doesn't dedupe, so remove old copies first.
existing=$(nft -a list chain inet filter forward 2>/dev/null | grep -E 'ip saddr (10\.88\.0\.0/16|172\.17\.0\.0/16)|ip daddr (10\.88\.0\.0/16|172\.17\.0\.0/16)' | awk '{print $NF}' | tr -d '#')
for h in $existing; do
  nft delete rule inet filter forward handle "$h" 2>/dev/null || true
done

nft insert rule inet filter forward ip saddr 10.88.0.0/16 accept
nft insert rule inet filter forward ip saddr 172.17.0.0/16 accept
nft insert rule inet filter forward ip daddr 10.88.0.0/16 ct state new accept
nft insert rule inet filter forward ip daddr 172.17.0.0/16 ct state new accept

log "installed — verify with: nft list chain inet filter forward | head"
