<#
.SYNOPSIS
  Stops what scripts/start-local.ps1 started: frontend, api-gateway (if started), then the
  microservices + collect-api (via stop-all.ps1). Docker containers are kept unless -Docker is given.
#>
param([switch]$Docker)

$backend = Split-Path -Parent $PSScriptRoot
$runDir = Join-Path $backend '.run'

foreach ($name in 'frontend', 'api-gateway') {
    $pidFile = Join-Path $runDir "$name.pid"
    if (Test-Path $pidFile) {
        $procId = [int](Get-Content $pidFile -Raw).Trim()
        if (Get-Process -Id $procId -ErrorAction SilentlyContinue) {
            taskkill /PID $procId /T /F | Out-Null
            Write-Host "stopped $name (pid $procId)"
        }
        Remove-Item $pidFile -Confirm:$false
    }
}

# Leftover node (ng serve) / gateway java on their ports, only if they belong to this project
foreach ($port in 4200, 8090) {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $conn) { continue }
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($conn.OwningProcess)"
    if (($port -eq 4200 -and $proc.Name -eq 'node.exe' -and $proc.CommandLine -match 'ng|angular') -or
        ($port -eq 8090 -and $proc.Name -eq 'java.exe' -and $proc.CommandLine -match 'ApiGatewayApplication')) {
        Stop-Process -Id $conn.OwningProcess -Force -Confirm:$false
        Write-Host "stopped leftover $($proc.Name) on port $port"
    }
}

& (Join-Path $PSScriptRoot 'stop-all.ps1')

if ($Docker) {
    Push-Location $backend
    try { docker compose down } finally { Pop-Location }
}
