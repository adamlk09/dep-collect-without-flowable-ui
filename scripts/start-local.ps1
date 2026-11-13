<#
.SYNOPSIS
  Starts the whole project locally: Docker infra, the 4 microservices, collect-api, optionally the
  api-gateway, and the Angular frontend (new-frontend).

.DESCRIPTION
  1. docker compose up -d (Postgres :5433, Mailpit :1035/:8035, Flowable UI :8096)
  2. builds the jars if missing (mvn install + collect-api package), unless -SkipBuild
  3. scripts/run-all.ps1: segmentation 8092, case 8091, notification 8095, workflow 8094, collect-api 9090
  4. -WithGateway: api-gateway on 8090
  5. frontend on http://localhost:4200  (-Frontend mock | api | none)

  Prerequisites: Docker Desktop running, Java 21, Maven, Node.js, and the native PostgreSQL 17 on :5432
  (database debt_collect_db, user collect_user / collect_pass) used by collect-api.
  Logs and PIDs: backend\.run\. Stop everything with scripts\stop-local.ps1.

.EXAMPLE
  .\scripts\start-local.ps1
  .\scripts\start-local.ps1 -Frontend api -WithGateway
#>
param(
    [ValidateSet('mock', 'api', 'none')][string]$Frontend = 'mock',
    [switch]$WithGateway,
    [switch]$SkipBuild,
    [string]$CollectApiProfile = 'dev',   # 'dev' = collect-api on the server database, 'local' = native PostgreSQL :5432
    [string]$SpringProfile = 'uat',   # profile of the 4 microservices (application-<profile>.yml)
    [int]$TimeoutSeconds = 600,
    [string]$Mvn = $(if (Get-Command mvn -ErrorAction SilentlyContinue) { (Get-Command mvn).Source } else { Join-Path $env:USERPROFILE '.tools\apache-maven-3.9.11\bin\mvn.cmd' })
)

$ErrorActionPreference = 'Stop'
$backend = Split-Path -Parent $PSScriptRoot
$root = Split-Path -Parent $backend
$frontendDir = Join-Path $root 'new-frontend'
$runDir = Join-Path $backend '.run'
New-Item -ItemType Directory -Force $runDir | Out-Null

function Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }

function Wait-Http($url, $seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        try { Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 3 | Out-Null; return $true } catch { Start-Sleep -Seconds 3 }
    }
    return $false
}

# --- 0. Prerequisites -------------------------------------------------------------------------------
Step 'Checking prerequisites'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'docker not found - install/start Docker Desktop.' }
docker info *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker is not running - start Docker Desktop.' }
if (-not (Test-Path $Mvn)) { throw "Maven not found ($Mvn). Install it or pass -Mvn <path to mvn.cmd>." }
if ($Frontend -ne 'none' -and -not (Get-Command npm -ErrorAction SilentlyContinue)) { throw 'npm not found - install Node.js.' }
if (-not (Get-NetTCPConnection -LocalPort 5432 -State Listen -ErrorAction SilentlyContinue)) {
    Write-Warning 'Nothing listens on :5432 - collect-api needs PostgreSQL (debt_collect_db / collect_user) there.'
}

# --- 1. Docker infra --------------------------------------------------------------------------------
Step 'Docker infra (Postgres :5433, Mailpit, Flowable UI)'
Push-Location $backend
try {
    # docker writes progress to stderr: don't let $ErrorActionPreference='Stop' treat it as a failure
    $ErrorActionPreference = 'Continue'
    docker compose up -d 2>&1 | ForEach-Object { "$_" }
    $composeExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($composeExit -ne 0) { throw 'docker compose up failed.' }
} finally { Pop-Location }
$deadline = (Get-Date).AddSeconds(90)
do {
    $health = docker inspect --format '{{.State.Health.Status}}' (docker compose -f (Join-Path $backend 'compose.yaml') ps -q postgres) 2>$null
    if ($health -eq 'healthy') { break }
    Start-Sleep -Seconds 3
} while ((Get-Date) -lt $deadline)
if ($health -ne 'healthy') { throw 'Postgres (:5433) did not become healthy in 90 s - check docker compose logs postgres.' }
Write-Host 'Postgres :5433 healthy'

# --- 2. Build (only when needed) -------------------------------------------------------------------
$jar = Join-Path $backend 'collect-api\target\collect-ai.jar'
if (-not $SkipBuild -and -not (Test-Path $jar)) {
    Step 'Building (mvn install, collect-api package)'
    Push-Location $backend
    try {
        & $Mvn -B -q install -DskipTests
        if ($LASTEXITCODE -ne 0) { throw 'mvn install failed.' }
        Push-Location (Join-Path $backend 'collect-api')
        try {
            & $Mvn -B -q -DskipTests package
            if ($LASTEXITCODE -ne 0) { throw 'collect-api package failed.' }
        } finally { Pop-Location }
    } finally { Pop-Location }
}

# --- 3. Microservices + collect-api ----------------------------------------------------------------
Step 'Microservices + collect-api (slow machines: up to several minutes)'
& (Join-Path $PSScriptRoot 'run-all.ps1') -TimeoutSeconds $TimeoutSeconds -Mvn $Mvn -SpringProfile $SpringProfile -CollectApiProfile $CollectApiProfile

# --- 4. api-gateway (optional) ----------------------------------------------------------------------
if ($WithGateway) {
    Step 'api-gateway :8090'
    if (Get-NetTCPConnection -LocalPort 8090 -State Listen -ErrorAction SilentlyContinue) {
        Write-Host 'Port 8090 already in use - gateway left as is.'
    } else {
        $env:COLLECT_API_URL = 'http://localhost:9090'
        $env:SEGMENTATION_SERVICE_URL = 'http://localhost:8092'
        $env:WORKFLOW_SERVICE_URL = 'http://localhost:8094'
        $env:NOTIFICATION_SERVICE_URL = 'http://localhost:8095'
        $gw = Start-Process -FilePath $Mvn -WorkingDirectory $backend `
            -ArgumentList @('-B', '-q', '-pl', 'services/api-gateway', 'spring-boot:run') `
            -RedirectStandardOutput (Join-Path $runDir 'api-gateway.log') `
            -RedirectStandardError (Join-Path $runDir 'api-gateway.err.log') -WindowStyle Hidden -PassThru
        $gw.Id | Set-Content (Join-Path $runDir 'api-gateway.pid')
        if (Wait-Http 'http://localhost:8090/actuator/health' 240) { Write-Host 'UP      api-gateway           http://localhost:8090' }
        else { Write-Warning 'api-gateway not UP after 240 s - see .run\api-gateway.log' }
    }
}

# --- 5. Frontend -------------------------------------------------------------------------------------
if ($Frontend -ne 'none') {
    Step "Frontend ($Frontend) http://localhost:4200"
    if (Get-NetTCPConnection -LocalPort 4200 -State Listen -ErrorAction SilentlyContinue) {
        Write-Host 'Port 4200 already in use - frontend left as is.'
    } else {
        if (-not (Test-Path (Join-Path $frontendDir 'node_modules'))) {
            Write-Host 'Installing npm dependencies (first run)...'
            Push-Location $frontendDir
            try { npm install; if ($LASTEXITCODE -ne 0) { throw 'npm install failed.' } } finally { Pop-Location }
        }
        $script = if ($Frontend -eq 'api') { 'start:api' } else { 'start' }
        $log = Join-Path $runDir 'frontend.log'
        $fe = Start-Process -FilePath 'cmd.exe' -WorkingDirectory $frontendDir `
            -ArgumentList @('/c', "npm run $script > `"$log`" 2>&1") -WindowStyle Hidden -PassThru
        $fe.Id | Set-Content (Join-Path $runDir 'frontend.pid')
        if (Wait-Http 'http://localhost:4200' 300) { Write-Host 'UP      frontend              http://localhost:4200' }
        else { Write-Warning 'frontend not answering after 300 s - see .run\frontend.log' }
        if ($Frontend -eq 'api') {
            Write-Host 'Note: "api" mode uses apiBaseUrl from new-frontend\src\environments\environment.api.ts (set it to http://localhost:9090 for the local backend).'
        }
    }
}

Step 'Done'
Write-Host @'
Frontend        http://localhost:4200
collect-api     http://localhost:9090   (admin / Admin@1234, X-Tenant-Id: mercure)
case-service    http://localhost:8091   segmentation 8092   workflow 8094   notification 8095
Mailpit UI      http://localhost:8035   Flowable UI http://localhost:8096/flowable-ui (admin / test)
Stop everything: .\scripts\stop-local.ps1
'@
