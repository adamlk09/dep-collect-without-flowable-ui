<#
.SYNOPSIS
  Runs the WHOLE project from Docker images (adamlk/* on Docker Hub): 2 Postgres, Mailpit, the 4 microservices,
  collect-api, api-gateway and the frontend. No Maven, no Node.js, no local Postgres needed - only Docker Desktop.

.DESCRIPTION
  Uses the per-service variable files in .\env\ (local test values). Containers share the network "collect-net".
  Published on the host: frontend 8080, api-gateway 8090, collect-api 9090, Mailpit UI 8025.
  Data is kept in Docker volumes (mercure-micro-data, mercure-collect-data) between runs.

.EXAMPLE
  .\run-docker.ps1            # pull + start everything
  .\run-docker.ps1 -NoPull    # use the images already on this machine
  .\run-docker.ps1 -Stop      # stop and remove the containers (keeps the data volumes)
  .\run-docker.ps1 -Stop -Purge   # also delete the data volumes
#>
param(
    [string]$Hub = 'adamlk',
    [string]$Tag = 'latest',
    [switch]$NoPull,
    [switch]$Server,   # microservices use the remote databases from env-server\*.env (no local postgres-micro)
    [switch]$Stop,
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$net = 'collect-net'
$containers = 'new-frontend', 'api-gateway', 'workflow-service', 'collect-api', 'case-service',
              'notification-service', 'segmentation-service', 'mailpit', 'postgres-collect', 'postgres-micro'

# Runs a docker command; stderr progress is not an error, only the exit code is.
function Dk {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & docker @args 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    [pscustomobject]@{ Code = $code; Out = ($out -join "`n") }
}
function Step($m) { Write-Host "`n== $m" -ForegroundColor Cyan }

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'docker not found - install Docker Desktop.' }
if ((Dk info).Code -ne 0) { throw 'Docker is not running - start Docker Desktop.' }

if ($Stop) {
    Step 'Stopping containers'
    foreach ($c in $containers) { if ((Dk rm -f $c).Code -eq 0) { Write-Host "removed $c" } }
    Dk network rm $net | Out-Null
    if ($Purge) { Dk volume rm mercure-micro-data mercure-collect-data | Out-Null; Write-Host 'data volumes deleted' }
    return
}

# --- ports -------------------------------------------------------------------------------------------
foreach ($p in 8080, 8090, 9090, 8025) {
    if (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) {
        $mine = (Dk ps --filter "publish=$p" --format '{{.Names}}').Out
        if (-not $mine) { throw "Port $p is already used by another program (maybe scripts\start-local.ps1 - run stop-local.ps1 first)." }
    }
}

# --- clean previous run, network ---------------------------------------------------------------------
Step 'Preparing'
foreach ($c in $containers) { Dk rm -f $c | Out-Null }
if ((Dk network inspect $net).Code -ne 0) { Dk network create $net | Out-Null }

# --- databases ---------------------------------------------------------------------------------------
Step 'Databases (Postgres) and Mailpit'
if (-not $Server) {
    $r = Dk run -d --name postgres-micro --network $net -v mercure-micro-data:/var/lib/postgresql/data `
        -e POSTGRES_USER=collector -e POSTGRES_PASSWORD=collector postgres:17-alpine
    if ($r.Code -ne 0) { throw "postgres-micro: $($r.Out)" }
}
$r = Dk run -d --name postgres-collect --network $net -v mercure-collect-data:/var/lib/postgresql/data `
    -e POSTGRES_DB=debt_collect_db -e POSTGRES_USER=collect_user -e POSTGRES_PASSWORD=collect_pass postgres:16
if ($r.Code -ne 0) { throw "postgres-collect: $($r.Out)" }
$r = Dk run -d --name mailpit --network $net -p 8025:8025 axllent/mailpit:v1.31.3
if ($r.Code -ne 0) { throw "mailpit: $($r.Out)" }

$pgList = @(, @('postgres-collect', 'collect_user', 'debt_collect_db'))
if (-not $Server) { $pgList = @(, @('postgres-micro', 'collector', 'postgres')) + $pgList }
foreach ($pg in $pgList) {
    $deadline = (Get-Date).AddSeconds(90)
    do { Start-Sleep -Seconds 2; $ready = (Dk exec $pg[0] pg_isready -U $pg[1] -d $pg[2]).Code -eq 0 } while (-not $ready -and (Get-Date) -lt $deadline)
    if (-not $ready) { throw "$($pg[0]) not ready after 90 s." }
    Write-Host "$($pg[0]) ready"
}
if (-not $Server) { foreach ($db in 'case_service', 'notification_service', 'workflow_service', 'segmentation_service') {
    $exists = (Dk exec postgres-micro psql -U collector -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname='$db'").Out
    if ($exists -notmatch '1') { Dk exec postgres-micro psql -U collector -d postgres -c "CREATE DATABASE $db;" | Out-Null; Write-Host "created database $db" }
} }

# --- application images --------------------------------------------------------------------------------
Step 'Application images'
$apps = @(
    @{ Name = 'segmentation-service'; Port = $null },
    @{ Name = 'notification-service'; Port = $null },
    @{ Name = 'case-service';         Port = $null },
    @{ Name = 'collect-api';          Port = '9090:9090' },
    @{ Name = 'workflow-service';     Port = $null },
    @{ Name = 'api-gateway';          Port = '8090:8090' },
    @{ Name = 'new-frontend';         Port = '8080:8080' }
)
$failed = @()
$envDir = if ($Server) { 'env-server' } else { 'env' }
if ($Server -and -not (Test-Path $envDir)) { throw 'env-server\ not found (it holds the server database credentials and is not in Git).' }
foreach ($a in $apps) {
    $image = "$Hub/$($a.Name):$Tag"
    if (-not $NoPull) {
        $p = Dk pull $image
        if ($p.Code -ne 0) {
            # fall back to an image already present locally
            if ((Dk image inspect $image).Code -ne 0) { Write-Warning "$image cannot be pulled and is not on this machine - skipped."; $failed += $a.Name; continue }
            Write-Warning "pull failed for $image - using the local copy."
        }
    }
    $dockerArgs = @('run', '-d', '--name', $a.Name, '--network', $net, '--restart', 'unless-stopped', '--env-file', "$envDir\$($a.Name).env")
    if ($a.Port) { $dockerArgs += @('-p', $a.Port) }
    $dockerArgs += $image
    $r = Dk @dockerArgs
    if ($r.Code -ne 0) { Write-Warning "$($a.Name): $($r.Out)"; $failed += $a.Name } else { Write-Host "started $($a.Name)" }
}

# --- wait for the entry points -------------------------------------------------------------------------
Step 'Waiting for the application (first start: a few minutes)'
function Wait-Http($url, $seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        try { Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 3 | Out-Null; return $true } catch { Start-Sleep -Seconds 3 }
    }
    return $false
}
foreach ($t in @(@('collect-api', 'http://localhost:9090/actuator/health'), @('api-gateway', 'http://localhost:8090/actuator/health'), @('new-frontend', 'http://localhost:8080'))) {
    if ($failed -contains $t[0]) { continue }
    if (Wait-Http $t[1] 300) { Write-Host "UP   $($t[0])  $($t[1])" } else { Write-Warning "$($t[0]) not answering after 300 s - docker logs $($t[0])" }
}

Step 'Done'
Write-Host @'
Application   http://localhost:8080
api-gateway   http://localhost:8090
collect-api   http://localhost:9090
Mailpit UI    http://localhost:8025
Logs:  docker logs <name>     Status: docker ps
Stop:  .\run-docker.ps1 -Stop
'@
if ($failed.Count -gt 0) { Write-Warning "Not started: $($failed -join ', ')" }
