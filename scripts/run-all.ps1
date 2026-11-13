<#
.SYNOPSIS
  Starts the 4 microservices and the debt-collection monolith (collect-api) from their built jars,
  then waits until every /actuator/health reports UP.

.DESCRIPTION
  Prerequisites (see scripts/README.md):
    - `mvn clean install` in backend/ (installs shared-kernel; the services run via spring-boot:run
      because the root POM does not repackage them into executable jars)
    - `mvn -DskipTests package` in backend/collect-api (executable collect-ai.jar)
    - docker compose up -d (in backend/): Postgres :5433 for the microservices + Mailpit (mail sink)
    - Native PostgreSQL :5432 with debt_collect_db / collect_user for the monolith
  Logs and PIDs go to backend/.run/. Stop everything with scripts/stop-all.ps1.
#>
param(
    [string]$ServiceToken = 'local-dev-service-token',
    [string]$TenantId = 'mercure',
    # Spring profile of the 4 microservices: loads application-<profile>.yml on top of application.yml
    [string]$SpringProfile = 'uat',
    # Spring profile of collect-api: 'dev' = PostgreSQL on the server (158.69.62.241), 'local' = native PostgreSQL :5432 + demo data
    [string]$CollectApiProfile = 'dev',
    [int]$TimeoutSeconds = 240,
    [string]$Mvn = $(if (Get-Command mvn -ErrorAction SilentlyContinue) { (Get-Command mvn).Source } else { Join-Path $env:USERPROFILE '.tools\apache-maven-3.9.11\bin\mvn.cmd' })
)

$ErrorActionPreference = 'Stop'
$backend = Split-Path -Parent $PSScriptRoot
$runDir = Join-Path $backend '.run'
New-Item -ItemType Directory -Force $runDir | Out-Null

$java = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\java.exe' } else { 'java' }

$apps = @(
    @{ Name = 'segmentation-service'; Port = 8092; Module = 'services/segmentation-service'; Env = @{ SPRING_PROFILES_ACTIVE = $SpringProfile } },
    @{ Name = 'case-service';         Port = 8091; Module = 'services/case-service'; Env = @{ SPRING_PROFILES_ACTIVE = $SpringProfile } },
    @{ Name = 'notification-service'; Port = 8095; Module = 'services/notification-service'; Env = @{ SPRING_PROFILES_ACTIVE = $SpringProfile } },
    @{ Name = 'workflow-service';     Port = 8094; Module = 'services/workflow-service';
       Env = @{ SPRING_PROFILES_ACTIVE = $SpringProfile; DEBT_COLLECTION_BASE_URL = 'http://localhost:9090'; DEBT_COLLECTION_SERVICE_TOKEN = $ServiceToken } },
    @{ Name = 'collect-api';          Port = 9090; Jar = 'collect-api\target\collect-ai.jar'; Args = @("--spring.profiles.active=$CollectApiProfile");
       Env = @{ INTEGRATION_SERVICE_TOKEN = $ServiceToken; INTEGRATION_TENANT_ID = $TenantId } }
)

$busy = $apps | Where-Object { Get-NetTCPConnection -LocalPort $_.Port -State Listen -ErrorAction SilentlyContinue }
if ($busy) {
    throw "Ports already in use: $(($busy | ForEach-Object { "$($_.Name):$($_.Port)" }) -join ', '). Run scripts/stop-all.ps1 or stop those processes first."
}

$pids = @{}
foreach ($app in $apps) {
    foreach ($k in $app.Env.Keys) { Set-Item "env:$k" $app.Env[$k] }
    $log = Join-Path $runDir "$($app.Name).log"
    $err = Join-Path $runDir "$($app.Name).err.log"
    if ($app.Jar) {
        $jar = Join-Path $backend $app.Jar
        if (-not (Test-Path $jar)) { throw "Missing $jar - build first." }
        $proc = Start-Process -FilePath $java -ArgumentList (@('-jar', "`"$jar`"") + $app.Args) `
            -RedirectStandardOutput $log -RedirectStandardError $err -WindowStyle Hidden -PassThru
    } else {
        $proc = Start-Process -FilePath $Mvn -WorkingDirectory $backend `
            -ArgumentList @('-B', '-q', '-pl', $app.Module, 'spring-boot:run') `
            -RedirectStandardOutput $log -RedirectStandardError $err -WindowStyle Hidden -PassThru
    }
    foreach ($k in $app.Env.Keys) { Remove-Item "env:$k" }
    $pids[$app.Name] = $proc.Id
    Write-Host ("started {0,-21} pid={1,-6} port={2}  log=.run\{0}.log" -f $app.Name, $proc.Id, $app.Port)
}
$pids | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $runDir 'pids.json')

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$pending = [System.Collections.ArrayList]@($apps)
while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    foreach ($app in @($pending)) {
        if (-not (Get-Process -Id $pids[$app.Name] -ErrorAction SilentlyContinue)) {
            throw "$($app.Name) exited during startup - see .run\$($app.Name).log"
        }
        try {
            $health = Invoke-RestMethod "http://localhost:$($app.Port)/actuator/health" -TimeoutSec 3
            if ($health.status -eq 'UP') {
                Write-Host ("UP      {0,-21} http://localhost:{1}" -f $app.Name, $app.Port)
                $pending.Remove($app)
            }
        } catch { }
    }
}
if ($pending.Count -gt 0) {
    throw "Not UP after $TimeoutSeconds s: $(($pending | ForEach-Object Name) -join ', ') - see backend\.run\*.log"
}
Write-Host "All services are UP. Next: scripts\smoke-e2e.ps1"
