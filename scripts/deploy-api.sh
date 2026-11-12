#!/usr/bin/env bash
# =============================================================================
# deploy-api.sh — Crea o actualiza una API v4 en Gravitee APIM (idempotente)
#
# Primera ejecución (la API no existe):
#   crear API -> crear plan -> publicar plan -> desplegar -> iniciar -> publicar en portal
# Siguientes ejecuciones (la API ya existe):
#   actualizar API -> actualizar plan (mismo ID, las suscripciones siguen vivas)
#   -> desplegar (para que el gateway tome los cambios)
#
# La API se identifica por su "name" en gravitee/api.json, y el plan por su
# "name" en gravitee/plan.json. No cambies esos nombres entre ejecuciones.
#
# Variables de entorno requeridas:
#   GRAVITEE_MGMT   URL del Management API, p. ej. https://org-xxx.us.xxxx.api.gravitee.io
#   GRAVITEE_ENV    ID del environment
#   GRAVITEE_TOKEN  Token personal de Gravitee
# Opcionales:
#   API_FILE (gravitee/api.json)  PLAN_FILE (gravitee/plan.json)
#   DEPLOY_LABEL (máx. 32 caracteres; se recorta)
# =============================================================================
set -euo pipefail
shopt -s inherit_errexit   # que un error HTTP dentro de $(...) también detenga el script

: "${GRAVITEE_MGMT:?Falta la variable GRAVITEE_MGMT}"
: "${GRAVITEE_ENV:?Falta la variable GRAVITEE_ENV}"
: "${GRAVITEE_TOKEN:?Falta la variable GRAVITEE_TOKEN}"

API_FILE="${API_FILE:-gravitee/api.json}"
PLAN_FILE="${PLAN_FILE:-gravitee/plan.json}"
DEPLOY_LABEL="${DEPLOY_LABEL:-Deploy desde CI}"

BASE="${GRAVITEE_MGMT%/}/management/v2/environments/${GRAVITEE_ENV}"

log()  { echo "==> $*"; }
fail() { echo "::error::$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# call METODO RUTA [BODY_JSON]
# Hace la petición al Management API, imprime el body de la respuesta y falla
# (mostrando el error de Gravitee) si el código HTTP no es 2xx.
# -----------------------------------------------------------------------------
call() {
  local method="$1" path="$2" body="${3:-}"
  local tmp code
  tmp="$(mktemp)"
  local args=(-sS -o "$tmp" -w '%{http_code}' -X "$method" "${BASE}${path}"
              -H "Authorization: Bearer ${GRAVITEE_TOKEN}"
              -H "Accept: application/json")
  if [[ -n "$body" ]]; then
    code="$(curl "${args[@]}" -H "Content-Type: application/json" --data-binary @- <<<"$body")" \
      || { rm -f "$tmp"; fail "curl no pudo conectar: $method $path"; }
  else
    code="$(curl "${args[@]}")" \
      || { rm -f "$tmp"; fail "curl no pudo conectar: $method $path"; }
  fi
  if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
    echo "::error::$method $path -> HTTP $code" >&2
    cat "$tmp" >&2; echo >&2
    rm -f "$tmp"
    exit 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

# -----------------------------------------------------------------------------
# 0. Validar archivos de definición
# -----------------------------------------------------------------------------
[[ -f "$API_FILE"  ]] || fail "No existe $API_FILE"
[[ -f "$PLAN_FILE" ]] || fail "No existe $PLAN_FILE"
jq empty "$API_FILE"  || fail "$API_FILE no es JSON válido"
jq empty "$PLAN_FILE" || fail "$PLAN_FILE no es JSON válido"

API_NAME="$(jq -r '.name' "$API_FILE")"
PLAN_NAME="$(jq -r '.name' "$PLAN_FILE")"
RATE="$(jq -r '[.flows[]?.request[]? | select(.policy=="rate-limit") | .configuration.rate
               | "\(.limit) peticiones / \(.periodTime) \(.periodTimeUnit)"] | first // "sin rate limit"' "$PLAN_FILE")"

log "API: '$API_NAME' | Plan: '$PLAN_NAME' | Rate limit: $RATE"

# -----------------------------------------------------------------------------
# 1. ¿Existe ya la API? (búsqueda por nombre, recorriendo todas las páginas)
# -----------------------------------------------------------------------------
find_api_ids() {
  local page=1 page_count=1 resp
  while (( page <= page_count )); do
    resp="$(call GET "/apis?page=${page}&perPage=100")"
    jq -r --arg n "$API_NAME" '.data[]? | select(.name == $n and .definitionVersion == "V4") | .id' <<<"$resp"
    page_count="$(jq -r '.pagination.pageCount // 1' <<<"$resp")"
    page=$(( page + 1 ))
  done
}

ids="$(find_api_ids)"
FOUND=()
[[ -n "$ids" ]] && mapfile -t FOUND <<<"$ids"
(( ${#FOUND[@]} > 1 )) && fail "Hay ${#FOUND[@]} APIs v4 llamadas '$API_NAME' (${FOUND[*]}). Deja solo una."

if (( ${#FOUND[@]} == 0 )); then
  # ---------------------------------------------------------------------------
  # 2a. Crear API  (POST /apis) -> queda en estado STOPPED
  # ---------------------------------------------------------------------------
  ACTION="CREADA"
  log "La API no existe: creándola..."
  resp="$(call POST "/apis" "$(cat "$API_FILE")")"
  API_ID="$(jq -r '.id' <<<"$resp")"
  [[ -n "$API_ID" && "$API_ID" != "null" ]] || fail "No se obtuvo el ID de la API creada"
  log "API creada con ID $API_ID"
else
  # ---------------------------------------------------------------------------
  # 2b. Actualizar API  (GET actual + merge con api.json -> PUT /apis/{id})
  #     El PUT necesita el objeto completo; por eso se parte de lo que devuelve
  #     el GET y se sobrescribe con lo que hay en el repo.
  # ---------------------------------------------------------------------------
  ACTION="ACTUALIZADA"
  API_ID="${FOUND[0]}"
  log "La API ya existe (ID $API_ID): actualizándola..."
  current="$(call GET "/apis/${API_ID}")"
  merged="$(jq -n --argjson cur "$current" --slurpfile want "$API_FILE" '$cur * $want[0]')"
  call PUT "/apis/${API_ID}" "$merged" >/dev/null
  log "Definición de la API actualizada"
fi

# -----------------------------------------------------------------------------
# 3. Plan: crear o actualizar (búsqueda por nombre entre STAGING y PUBLISHED)
# -----------------------------------------------------------------------------
plans="$(call GET "/apis/${API_ID}/plans?statuses=STAGING,PUBLISHED&perPage=100")"
PLAN_ID="$(jq -r --arg n "$PLAN_NAME" '[.data[]? | select(.name == $n)] | first | .id // empty' <<<"$plans")"

if [[ -z "$PLAN_ID" ]]; then
  log "Creando plan '$PLAN_NAME'..."
  resp="$(call POST "/apis/${API_ID}/plans" "$(cat "$PLAN_FILE")")"
  PLAN_ID="$(jq -r '.id' <<<"$resp")"
  PLAN_STATUS="$(jq -r '.status // "STAGING"' <<<"$resp")"
  log "Plan creado con ID $PLAN_ID"
else
  PLAN_STATUS="$(jq -r --arg id "$PLAN_ID" '.data[] | select(.id == $id) | .status' <<<"$plans")"
  log "Actualizando plan existente $PLAN_ID (estado $PLAN_STATUS)..."
  # En un update no se puede cambiar el tipo de seguridad ni el mode:
  # se envía solo la configuración de seguridad y los flows (rate limit).
  update_body="$(jq 'del(.mode) | .security = {configuration: (.security.configuration // {})}' "$PLAN_FILE")"
  call PUT "/apis/${API_ID}/plans/${PLAN_ID}" "$update_body" >/dev/null
  log "Plan actualizado"
fi

if [[ "$PLAN_STATUS" == "STAGING" ]]; then
  log "Publicando plan..."
  call POST "/apis/${API_ID}/plans/${PLAN_ID}/_publish" >/dev/null
fi

# -----------------------------------------------------------------------------
# 4. Desplegar: sin esto el gateway sigue usando la definición anterior
# -----------------------------------------------------------------------------
label="$(jq -n --arg l "$DEPLOY_LABEL" '{deploymentLabel: ($l | .[0:32])}')"
log "Desplegando en el gateway..."
call POST "/apis/${API_ID}/deployments" "$label" >/dev/null

# -----------------------------------------------------------------------------
# 5. Iniciar (si está detenida) y publicar en el Developer Portal (si no lo está)
# -----------------------------------------------------------------------------
api="$(call GET "/apis/${API_ID}")"
STATE="$(jq -r '.state' <<<"$api")"
LIFECYCLE="$(jq -r '.lifecycleState' <<<"$api")"

if [[ "$STATE" != "STARTED" ]]; then
  log "Iniciando la API (estado actual: $STATE)..."
  call POST "/apis/${API_ID}/_start" >/dev/null
fi

if [[ "$LIFECYCLE" != "PUBLISHED" ]]; then
  log "Publicando la API en el Developer Portal (estado actual: $LIFECYCLE)..."
  call PATCH "/apis/${API_ID}" '{"lifecycleState":"PUBLISHED"}' >/dev/null
fi

# -----------------------------------------------------------------------------
# 6. Resumen (en el log y, si corre en GitHub Actions, en el Summary del job)
# -----------------------------------------------------------------------------
CONTEXT_PATH="$(jq -r '.listeners[0].paths[0].path' "$API_FILE")"
log "Listo: API $ACTION | ID $API_ID | Plan $PLAN_ID | Rate limit $RATE | Path $CONTEXT_PATH"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Gravitee: API **$API_NAME** $ACTION"
    echo ""
    echo "| Campo | Valor |"
    echo "|---|---|"
    echo "| API ID | \`$API_ID\` |"
    echo "| Plan | $PLAN_NAME (\`$PLAN_ID\`) |"
    echo "| Rate limit | **$RATE** |"
    echo "| Context path | \`$CONTEXT_PATH\` |"
    echo "| Deployment | $(jq -r '.deploymentLabel' <<<"$label") |"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "api_id=$API_ID"   >> "$GITHUB_OUTPUT"
  echo "plan_id=$PLAN_ID" >> "$GITHUB_OUTPUT"
fi
