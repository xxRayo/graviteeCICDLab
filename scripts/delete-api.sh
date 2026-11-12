#!/usr/bin/env bash
# =============================================================================
# delete-api.sh — Borra la API del laboratorio para poder repetir la demo
# desde cero (detiene la API, cierra sus planes y la elimina).
# Usa las mismas variables que deploy-api.sh. Ejecútalo a mano, no desde CI.
# =============================================================================
set -euo pipefail
shopt -s inherit_errexit
: "${GRAVITEE_MGMT:?}"; : "${GRAVITEE_ENV:?}"; : "${GRAVITEE_TOKEN:?}"
API_FILE="${API_FILE:-gravitee/api.json}"
BASE="${GRAVITEE_MGMT%/}/management/v2/environments/${GRAVITEE_ENV}"
AUTH=(-H "Authorization: Bearer ${GRAVITEE_TOKEN}")
NAME="$(jq -r .name "$API_FILE")"

ID="$(curl -sS -f "${AUTH[@]}" "${BASE}/apis?perPage=100" \
      | jq -r --arg n "$NAME" '[.data[] | select(.name==$n and .definitionVersion=="V4")] | first | .id // empty')"
[[ -n "$ID" ]] || { echo "No existe ninguna API v4 llamada '$NAME'"; exit 0; }

read -r -p "Se va a BORRAR la API '$NAME' ($ID) y cerrar sus planes y suscripciones. ¿Continuar? [s/N] " ok
[[ "$ok" == "s" || "$ok" == "S" ]] || { echo "Cancelado"; exit 0; }

echo "Deteniendo..."; curl -sS -o /dev/null -X POST "${AUTH[@]}" "${BASE}/apis/${ID}/_stop" || true
echo "Borrando...";   curl -sS -f -X DELETE "${AUTH[@]}" "${BASE}/apis/${ID}?closePlans=true" && echo "API borrada"
