#requires -Version 5.1
param([string]$HermesPath, [string]$ExecutablePath)
$ErrorActionPreference = 'Stop'
if (-not $HermesPath) { $HermesPath = (Get-Command hermes.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source }
if (-not $ExecutablePath) { $ExecutablePath = Join-Path $PSScriptRoot '..\dist\HermesTray.exe' }
if (-not $env:TMPDIR) { throw 'Set TMPDIR to a writable scratch directory.' }
$work = Join-Path $env:TMPDIR ('HermesTray.RealSmoke.' + [Guid]::NewGuid().ToString('N'))
$isolatedHome = Join-Path $work 'home'; $logs = Join-Path $work 'logs'
[void][IO.Directory]::CreateDirectory($isolatedHome)
$keys = @('HERMES_HOME','HERMES_PROFILE','HERMES_DASHBOARD_BASIC_AUTH_USERNAME','HERMES_DASHBOARD_BASIC_AUTH_PASSWORD','HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH','HERMES_DASHBOARD_BASIC_AUTH_SECRET')
$previous = @{}; foreach ($key in $keys) { $previous[$key] = [Environment]::GetEnvironmentVariable($key) }
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
$process = $null
function Read-Shared([string]$path) {
  if (-not [IO.File]::Exists($path)) { return '' }
  $stream = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
  $reader = [IO.StreamReader]::new($stream)
  try { return $reader.ReadToEnd() } finally { $reader.Dispose(); $stream.Dispose() }
}
try {
  # Temporary credentials only, inherited by this test's owned backend, never printed.
  $env:HERMES_HOME = $isolatedHome; $env:HERMES_PROFILE = ''
  $env:HERMES_DASHBOARD_BASIC_AUTH_USERNAME = 'hermestray-smoke'
  $env:HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH = ''
  $password = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
  $env:HERMES_DASHBOARD_BASIC_AUTH_PASSWORD = $password
  $env:HERMES_DASHBOARD_BASIC_AUTH_SECRET = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
  $mutex = 'Local\HermesTray.RealSmoke.' + [Guid]::NewGuid().ToString('N')
  $processArgs = '-HermesPath "' + $HermesPath + '" -Port ' + $port + ' -InstanceMutexName ' + $mutex + ' -LogDirectory "' + $logs + '"'
  $process = Start-Process -FilePath $ExecutablePath -ArgumentList $processArgs -PassThru
  [void]$process.Handle
  $clock = [Diagnostics.Stopwatch]::StartNew()
  do {
    $text = Read-Shared (Join-Path $logs 'tray.log')
    if ($text.Contains('Authenticated HTTP readiness verified')) { break }
    if ($process.HasExited) { throw "Real Hermes startup failed. Inspect local logs: $logs" }
    Start-Sleep -Milliseconds 100
  } while ($clock.Elapsed.TotalSeconds -lt 90)
  if (-not $text.Contains('Authenticated HTTP readiness verified')) { throw "Real Hermes readiness timed out. Logs: $logs" }
  $url = 'http://127.0.0.1:' + $port
  $status = Invoke-RestMethod -Uri ($url + '/api/status') -TimeoutSec 5
  if (-not $status.auth_required -or 'basic' -notin $status.auth_providers) { throw 'The real backend did not require the temporary password provider.' }
  $bad = @{ provider = 'basic'; username = 'hermestray-smoke'; password = 'deliberately-wrong' } | ConvertTo-Json
  $refused = $false
  try { Invoke-WebRequest -UseBasicParsing -Uri ($url + '/auth/password-login') -Method Post -ContentType 'application/json' -Body $bad -TimeoutSec 5 | Out-Null }
  catch { if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401) { $refused = $true } else { throw } }
  if (-not $refused) { throw 'A wrong password was accepted by the real backend.' }
  $body = @{ provider = 'basic'; username = 'hermestray-smoke'; password = $password } | ConvertTo-Json
  $login = Invoke-RestMethod -Uri ($url + '/auth/password-login') -Method Post -ContentType 'application/json' -Body $body -SessionVariable session -TimeoutSec 5
  if (-not $login.ok) { throw 'The temporary password login failed.' }
  $identity = Invoke-WebRequest -UseBasicParsing -Uri ($url + '/api/auth/me') -WebSession $session -TimeoutSec 5
  if ($identity.StatusCode -ne 200) { throw 'The authenticated session was not recognized.' }
  Write-Output ("PASS: real Hermes {0}: EXE startup, required basic auth, rejected wrong password, accepted correct password and verified session." -f $status.version)
} finally {
  if ($process) { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }; $process.Dispose() }
  foreach ($key in $keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) }
}
$clock.Restart()
while (@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object Port -eq $port).Count -gt 0 -and $clock.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 50 }
if (@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object Port -eq $port).Count -gt 0) { throw 'Real smoke cleanup left its backend listener alive.' }
Write-Output 'PASS: real backend cleanup; temporary HERMES_HOME used, existing profiles unchanged.'
