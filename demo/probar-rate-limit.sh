#!/usr/bin/env bash
# Igual que probar-rate-limit.ps1 pero para Git Bash / Linux / macOS
# Uso: ./demo/probar-rate-limit.sh "https://<tu-gateway>/v1/users/" "<api-key>" 6
set -uo pipefail
URL="${1:?URL del gateway}"; KEY="${2:?API key}"; N="${3:-6}"
for i in $(seq 1 "$N"); do
  h="$(curl -s -o /dev/null -D - -H "X-Gravitee-Api-Key: $KEY" "$URL")"
  code="$(grep -m1 -oE '^HTTP/[^ ]+ [0-9]{3}' <<<"$h" | awk '{print $2}')"
  rem="$(grep -im1 '^x-rate-limit-remaining:' <<<"$h" | awk '{print $2}' | tr -d '\r')"
  printf 'Peticion %2d: HTTP %s  (restantes: %s)\n' "$i" "$code" "${rem:--}"
done
