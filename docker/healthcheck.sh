#!/usr/bin/env sh
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Docker healthcheck wrapper that speaks the right scheme + TLS flags
# for the container's TLS_MODE. Avoids encoding tls_mode-specific
# curl args into the compose file.
set -e

TLS_MODE="${TLS_MODE:-off}"
FLAGS="-fsS"
URL="http://127.0.0.1:9077/api/v1/health"
if [ "$TLS_MODE" != "off" ]; then
  URL="https://localhost:9077/api/v1/health"
  FLAGS="$FLAGS --cacert /etc/ai-memory-a2a/tls/ca.pem --resolve localhost:9077:127.0.0.1"
  if [ "$TLS_MODE" = "mtls" ]; then
    FLAGS="$FLAGS --cert /etc/ai-memory-a2a/tls/client.pem --key /etc/ai-memory-a2a/tls/client.key"
  fi
fi
# shellcheck disable=SC2086
curl $FLAGS "$URL" | grep -q '"ok"'
