<#
.SYNOPSIS
  Envía N peticiones a la API en el gateway y muestra el código HTTP de cada una
  y las cabeceras de rate limit, para demostrar el límite configurado.

.EXAMPLE
  # Demo 1 (límite 5/min): 6 peticiones -> 5 x 200 y 1 x 429
  .\demo\probar-rate-limit.ps1 -Url "https://<tu-gateway>/v1/users/" -ApiKey "<api-key>" -Requests 6

.EXAMPLE
  # Demo 2 (límite 10/min): 11 peticiones -> 10 x 200 y 1 x 429
  .\demo\probar-rate-limit.ps1 -Url "https://<tu-gateway>/v1/users/" -ApiKey "<api-key>" -Requests 11
#>
param(
  [Parameter(Mandatory = $true)] [string] $Url,
  [Parameter(Mandatory = $true)] [string] $ApiKey,
  [int] $Requests = 6
)

$ok = 0; $limited = 0; $other = 0

for ($i = 1; $i -le $Requests; $i++) {
  # -D - imprime las cabeceras de respuesta; -o NUL descarta el body
  $headers = curl.exe -s -o NUL -D - -H "X-Gravitee-Api-Key: $ApiKey" $Url

  $status = ($headers | Select-String -Pattern '^HTTP/\S+\s+(\d{3})' | Select-Object -First 1).Matches.Groups[1].Value
  $limit  = ($headers | Select-String -Pattern '^x-rate-limit-limit:\s*(\S+)'     | Select-Object -First 1).Matches.Groups[1].Value
  $remain = ($headers | Select-String -Pattern '^x-rate-limit-remaining:\s*(\S+)' | Select-Object -First 1).Matches.Groups[1].Value

  switch ($status) {
    '200'   { $ok++;      $color = 'Green' }
    '429'   { $limited++; $color = 'Red' }
    default { $other++;   $color = 'Yellow' }
  }

  $extra = if ($limit) { "  (limite: $limit, restantes: $remain)" } else { "" }
  Write-Host ("Peticion {0,2}: HTTP {1}{2}" -f $i, $status, $extra) -ForegroundColor $color
}

Write-Host ""
Write-Host "Resumen: $ok OK (200) | $limited bloqueadas (429) | $other otras"
