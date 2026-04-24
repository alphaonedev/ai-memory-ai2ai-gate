#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Ephemeral TLS material generator for the local Docker mesh. Mirrors
# the DO workflow's "Generate ephemeral TLS material" step
# (.github/workflows/a2a-gate.yml:254-320) but writes into
# docker/tls/node-{1..4}/ instead of SCP'ing to droplets.
#
# Produces, per node:
#   ca.pem           — campaign-ephemeral self-signed root CA (1-day validity)
#   server.pem       — per-node server cert with SAN = container bridge IP
#   server.key       — per-node server private key
#   client.pem       — a single gate-client cert shared across nodes
#   client.key       — matching private key
#   allowlist.txt    — sha256 fingerprints of all server certs + the client
#                      cert (consumed by ai-memory --mtls-allowlist)
#
# Idempotent: safe to re-run. Deletes prior material first so cert
# fingerprints don't persist across rounds.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TLS_DIR="$HERE/tls"
log() { printf '[gen-tls %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# Container-bridge IPs for the 4 nodes. These are the SANs the ai-memory
# serve certs need. Must match docker-compose.openclaw.yml.
declare -A NODE_IP=(
  [1]="10.88.1.11"
  [2]="10.88.1.12"
  [3]="10.88.1.13"
  [4]="10.88.1.14"
)

log "wiping prior tls/ material"
rm -rf "$TLS_DIR"
mkdir -p "$TLS_DIR/ca" "$TLS_DIR/client"
for n in 1 2 3 4; do mkdir -p "$TLS_DIR/node-$n"; done

log "generating ephemeral CA (1-day validity)"
openssl genrsa -out "$TLS_DIR/ca/ca.key" 4096 2>/dev/null
openssl req -x509 -new -nodes -key "$TLS_DIR/ca/ca.key" -sha256 -days 1 \
  -subj "/CN=a2a-gate-local-docker-ephemeral-ca" \
  -out "$TLS_DIR/ca/ca.pem" 2>/dev/null

log "generating per-node server certs"
for n in 1 2 3 4; do
  ip="${NODE_IP[$n]}"
  host="node-$n"
  openssl genrsa -out "$TLS_DIR/node-$n/server.key" 2048 2>/dev/null
  openssl req -new -key "$TLS_DIR/node-$n/server.key" \
    -subj "/CN=a2a-local-docker-node-$n" \
    -out "$TLS_DIR/node-$n/server.csr" 2>/dev/null
  # SAN covers: bridge IP, 127.0.0.1 loopback, and both the hostname
  # ("node-N" via docker DNS) AND the compose container_name ("a2a-node-N")
  # so containers can reach each other by either form.
  printf 'subjectAltName = IP:%s, IP:127.0.0.1, DNS:%s, DNS:a2a-%s, DNS:localhost\nextendedKeyUsage = serverAuth, clientAuth\n' \
    "$ip" "$host" "$host" > "$TLS_DIR/node-$n/v3.ext"
  openssl x509 -req -in "$TLS_DIR/node-$n/server.csr" \
    -CA "$TLS_DIR/ca/ca.pem" -CAkey "$TLS_DIR/ca/ca.key" -CAcreateserial \
    -out "$TLS_DIR/node-$n/server.pem" -days 1 -sha256 \
    -extfile "$TLS_DIR/node-$n/v3.ext" 2>/dev/null
  rm -f "$TLS_DIR/node-$n/server.csr" "$TLS_DIR/node-$n/v3.ext"
done

log "generating shared gate client cert"
openssl genrsa -out "$TLS_DIR/client/client.key" 2048 2>/dev/null
openssl req -new -key "$TLS_DIR/client/client.key" \
  -subj "/CN=a2a-local-docker-gate-client" \
  -out "$TLS_DIR/client/client.csr" 2>/dev/null
printf 'extendedKeyUsage = clientAuth\n' > "$TLS_DIR/client/v3.ext"
openssl x509 -req -in "$TLS_DIR/client/client.csr" \
  -CA "$TLS_DIR/ca/ca.pem" -CAkey "$TLS_DIR/ca/ca.key" -CAcreateserial \
  -out "$TLS_DIR/client/client.pem" -days 1 -sha256 \
  -extfile "$TLS_DIR/client/v3.ext" 2>/dev/null
rm -f "$TLS_DIR/client/client.csr" "$TLS_DIR/client/v3.ext"

log "building mtls fingerprint allowlist (label comments on separate lines)"
ALLOW="$TLS_DIR/allowlist.txt"
{
  echo "# a2a-local-docker ephemeral allowlist (regenerated per round)"
  echo "# Node server certs + gate client cert."
  for n in 1 2 3 4; do
    fpr=$(openssl x509 -in "$TLS_DIR/node-$n/server.pem" -noout -fingerprint -sha256 \
      | sed -e 's/^.*=//' -e 's/://g' | tr 'A-Z' 'a-z')
    echo "# node-$n"
    echo "sha256:$fpr"
  done
  fpr=$(openssl x509 -in "$TLS_DIR/client/client.pem" -noout -fingerprint -sha256 \
    | sed -e 's/^.*=//' -e 's/://g' | tr 'A-Z' 'a-z')
  echo "# gate-client"
  echo "sha256:$fpr"
} > "$ALLOW"

log "distributing per-node bundles"
for n in 1 2 3 4; do
  # Every node gets: its own server cert + key, the CA, the client cert
  # (for loopback HTTPS probes), and the mtls allowlist.
  cp "$TLS_DIR/ca/ca.pem"          "$TLS_DIR/node-$n/"
  cp "$TLS_DIR/client/client.pem"  "$TLS_DIR/node-$n/"
  cp "$TLS_DIR/client/client.key"  "$TLS_DIR/node-$n/"
  cp "$ALLOW"                      "$TLS_DIR/node-$n/allowlist.txt"
  chmod 600 "$TLS_DIR/node-$n/server.key" "$TLS_DIR/node-$n/client.key"
done

log "done — $TLS_DIR populated"
ls -la "$TLS_DIR/node-1"
