# Laboratorio CI/CD: Gravitee APIM + GitHub Actions

Cada merge a `dev` crea o actualiza la API **Usuarios** en Gravitee, junto con su plan API Key y su política de Rate Limiting. El mismo script sirve para las dos cosas: si la API no existe la crea, y si ya existe la actualiza.

```
feature/creation ──PR──► dev  ──►  GitHub Actions  ──►  Gravitee: crea API + plan (5 req/min), despliega, inicia y publica
feature/update   ──PR──► dev  ──►  GitHub Actions  ──►  Gravitee: actualiza el plan (10 req/min) y redespliega
dev              ──PR──► main     (opcional: dejar main como la versión estable)
```

## Estructura del repo

```
.github/workflows/gravitee-cicd.yml   Pipeline: valida en el PR y despliega al hacer merge en dev
gravitee/api.json                     Definición de la API (sale de tu export, ya limpia)
gravitee/plan.json                    Plan API Key + flow con la política rate-limit
scripts/deploy-api.sh                 Script idempotente: crear o actualizar
scripts/delete-api.sh                 Borra la API para repetir la demo desde cero (manual)
demo/probar-rate-limit.ps1            Manda N peticiones y muestra 200 / 429 (PowerShell)
demo/probar-rate-limit.sh             Lo mismo para Git Bash / Linux
```

---

## 1. Conceptos mínimos de GitHub Actions

| Concepto | Qué es en este lab |
|---|---|
| **Workflow** | El archivo `.github/workflows/gravitee-cicd.yml`. GitHub lo detecta solo por estar en esa carpeta. |
| **Trigger (`on:`)** | `pull_request` hacia `dev` → solo valida. `push` a `dev` (lo que pasa al hacer merge del PR) → valida y despliega. |
| **Job / steps** | `validate` revisa los JSON; `deploy` corre `scripts/deploy-api.sh`. `deploy` solo corre si `validate` pasó. |
| **Runner** | Una máquina Ubuntu temporal de GitHub que ya trae `curl` y `jq`. Por eso el script es bash y no PowerShell. |
| **Secrets / Variables** | Donde guardas el token y los IDs para no escribirlos en el código. |

---

## 2. Configurar el repositorio en GitHub

1. Crea un repo vacío en GitHub (sin README, para no tener conflictos con el primer push).
2. Ve a **Settings → Secrets and variables → Actions**:
   - Pestaña **Secrets** → *New repository secret*:
     - `GRAVITEE_TOKEN` = tu token personal de Gravitee
   - Pestaña **Variables** → *New repository variable*:
     - `GRAVITEE_MGMT` = `https://org-crediobanco.us.6c4248.api.gravitee.io`
     - `GRAVITEE_ENV` = `e2f7036e-0f7d-4f82-b703-6e0f7d6f82d9`
3. En **Settings → General → Pull Requests**, deja habilitado **Allow merge commits** y úsalo al hacer merge (ver la nota de la sección 9).

> El token **nunca** va en un archivo del repo. GitHub lo enmascara (`***`) en los logs.

---

## 3. Crear las ramas y subir el código

Desde la carpeta del laboratorio (PowerShell o Git Bash):

```bash
git init -b main
git add .github scripts demo README.md .gitignore
git commit -m "chore: pipeline CI/CD para Gravitee"
git remote add origin https://github.com/<tu-usuario>/<tu-repo>.git
git push -u origin main

git checkout -b dev
git push -u origin dev
```

Fíjate que **la carpeta `gravitee/` todavía no se sube**: llega en la rama de creación, para que ese PR muestre exactamente la API que se va a crear.

---

## 4. Demo 1: crear la API (rate limit 5/min)

```bash
git checkout -b feature/creation
git add gravitee
git commit -m "feat: API Usuarios con rate limit de 5 peticiones/min"
git push -u origin feature/creation
```

1. En GitHub, abre un **Pull Request** `feature/creation → dev`.
2. En el PR verás el check **Validar definición** corriendo. Ábrelo: el *Summary* muestra "Rate limit en este commit: 5 peticiones / 1 MINUTES". En este paso todavía no se toca Gravitee.
3. Haz **Merge pull request** (merge commit).
4. Ve a la pestaña **Actions**: se ejecuta el workflow en `dev` con el job **Crear / actualizar API en Gravitee**. En su log verás cada paso (`La API no existe: creándola...`, `Publicando plan...`, etc.) y en el *Summary* una tabla con el API ID y el rate limit.
5. Verifica en la consola de Gravitee: API *Usuarios* iniciada, publicada, con el plan *APIKEY Usuarios* publicado y la política Rate Limiting en el flow del plan.

### Suscripción manual (no la hace el pipeline)

1. En el Developer Portal (o en la consola), suscribe tu aplicación al plan **APIKEY Usuarios**.
2. El plan tiene `validation: MANUAL`, así que **acepta la suscripción** en la consola: *API → Consumers → Subscriptions*.
3. Copia la API key generada.

### Probar el límite

La URL es la del **gateway** (no la del Management API) más el context path `/v1/users/`. La encuentras en la consola: *API → Entrypoints*, o en el portal.

```powershell
.\demo\probar-rate-limit.ps1 -Url "https://<tu-gateway>/v1/users/" -ApiKey "<api-key>" -Requests 6
```

Resultado esperado:

```
Peticion  1: HTTP 200  (limite: 5, restantes: 4)
...
Peticion  5: HTTP 200  (limite: 5, restantes: 0)
Peticion  6: HTTP 429  (limite: 5, restantes: 0)
Resumen: 5 OK (200) | 1 bloqueadas (429) | 0 otras
```

> Las cabeceras `X-Rate-Limit-*` aparecen porque en `plan.json` activé `"addHeaders": true` (en tu export estaba en `false`). Así la demo se ve más clara.

---

## 5. Demo 2: actualizar la API (rate limit 10/min)

La rama de update debe salir de `dev` **después** del merge anterior:

```bash
git checkout dev
git pull
git checkout -b feature/update
```

Edita `gravitee/plan.json` y cambia **solo esta línea**:

```diff
-              "limit": 5,
+              "limit": 10,
```

```bash
git commit -am "feat: subir rate limit a 10 peticiones/min"
git push -u origin feature/update
```

1. Abre el PR `feature/update → dev`. El diff es de una sola línea, y el check de validación ya muestra "10 peticiones / 1 MINUTES".
2. Haz merge. En **Actions** el log ahora dice `La API ya existe (ID ...): actualizándola...` y `Actualizando plan existente ...`.
3. **Espera a que termine la ventana de 1 minuto** de la prueba anterior y lanza 11 peticiones con **la misma API key** (la suscripción sigue viva porque el plan se actualiza, no se recrea):

```powershell
.\demo\probar-rate-limit.ps1 -Url "https://<tu-gateway>/v1/users/" -ApiKey "<api-key>" -Requests 11
```

Esperado: 10 × `200` y 1 × `429`, con `limite: 10`.

4. (Opcional) PR `dev → main` para dejar `main` como la versión estable.

---

## 6. ¿Cómo sabe el script si tiene que crear o actualizar?

`scripts/deploy-api.sh` hace lo mismo que tú hiciste a mano con el CLI, pero decide cada paso según lo que ya existe:

| Paso | Si NO existe | Si YA existe |
|---|---|---|
| Buscar API por `name` | `GET /apis` (todas las páginas) | ← igual |
| API | `POST /apis` | `GET /apis/{id}` + merge con `api.json` → `PUT /apis/{id}` |
| Plan (buscado por `name`) | `POST /apis/{id}/plans` | `PUT /apis/{id}/plans/{planId}` (mismo ID) |
| Publicar plan | `POST .../plans/{planId}/_publish` | solo si está en `STAGING` |
| Desplegar | `POST /apis/{id}/deployments` | `POST /apis/{id}/deployments` (**siempre**: sin esto el gateway no ve el cambio) |
| Iniciar | `POST /apis/{id}/_start` | solo si no está `STARTED` |
| Publicar en portal | `PATCH /apis/{id}` `{"lifecycleState":"PUBLISHED"}` | solo si no está `PUBLISHED` |

Puntos clave:

- **La identidad es el `name`** de `api.json` y de `plan.json`. Si cambias el nombre, el script creará una API o un plan nuevos.
- **El plan se actualiza en lugar de recrearse.** Así la suscripción y la API key que creaste a mano siguen funcionando después del update.
- El `PUT` de la API necesita el objeto completo. Por eso el script parte de lo que devuelve el `GET` y le sobrescribe lo que hay en el repo.
- En el `PUT` del plan se quitan `mode` y `security.type`, porque no se pueden cambiar en un plan existente.
- Si cualquier llamada devuelve un código que no es 2xx, el script se detiene y muestra el error de Gravitee en el log del job.

### Probar el script en tu máquina (opcional)

Con Git Bash (trae `curl`; `jq` se instala aparte, p. ej. `winget install jqlang.jq`):

```bash
export GRAVITEE_MGMT="https://org-crediobanco.us.6c4248.api.gravitee.io"
export GRAVITEE_ENV="e2f7036e-0f7d-4f82-b703-6e0f7d6f82d9"
export GRAVITEE_TOKEN="<token>"
bash scripts/deploy-api.sh
```

---

## 7. Repetir la demo desde cero

```bash
bash scripts/delete-api.sh     # detiene la API, cierra planes/suscripciones y la borra (pide confirmación)
```

Después puedes volver a ejecutar el workflow en **Actions → Gravitee CI/CD → Run workflow** (elige la rama **dev**) y se creará de nuevo.

---

## 8. Problemas comunes

| Síntoma | Causa probable |
|---|---|
| `HTTP 401` en el primer paso | Token vencido o mal copiado en el secret `GRAVITEE_TOKEN`. |
| `HTTP 400` al crear, con un mensaje sobre el path | Ya hay otra API usando `/v1/users/` (con otro nombre). Bórrala o cambia el path. |
| `Hay 2 APIs v4 llamadas 'Usuarios'` | Quedaron duplicadas de pruebas anteriores; deja solo una. |
| El workflow no se ejecutó al hacer merge | El merge no tocó `gravitee/`, `scripts/` ni el workflow (filtro `paths`), o el merge no fue hacia `dev`. |
| *Run workflow* falla en `main` | En `main` no existe `gravitee/`. Ejecútalo eligiendo la rama `dev`. |
| La 6.ª petición no da 429 | Pasó más de un minuto entre peticiones, o usaste una API key distinta (el contador es por suscripción). |
| Errores 5xx o respuestas raras del backend | Beeceptor gratis tiene un límite diario de peticiones. Los 429 del gateway no llegan al backend. |
| Después del update sigue cortando en 5 | Revisa que el job `deploy` terminó en verde (el paso `deployments` es el que lleva el cambio al gateway) y espera a que pase la ventana anterior. |

## 9. Nota sobre los merges

Usa **Create a merge commit**. Si haces *Squash and merge* del PR de creación y `feature/update` se creó antes de ese merge, el PR de update mostrará cambios duplicados. Crear `feature/update` desde `dev` actualizado (sección 5) evita el problema con cualquier tipo de merge.
