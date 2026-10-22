param([string]$ExecutablePath = (Join-Path $PSScriptRoot '..\dist\HermesTray.exe'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Helpers.ps1')
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\HermesTray.ps1'))
$exe = [IO.Path]::GetFullPath($ExecutablePath)
if (-not (Test-Path $exe)) { throw 'Build HermesTray.exe first.' }
$work = Join-Path $env:TMPDIR ('HermesTray launcher tests ' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$fixture = Join-Path $work 'FakeHermes.exe'
Add-Type -Path (Join-Path $PSScriptRoot 'fixtures\FakeHermes.cs') -OutputAssembly $fixture -OutputType ConsoleApplication
$owned = [Collections.Generic.List[Diagnostics.Process]]::new()

function Listening([int]$Port) {
  return @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object Port -eq $Port).Count -gt 0
}

function Wait-Until([scriptblock]$Condition, [string]$Message) {
  $deadline = [DateTime]::UtcNow.AddSeconds(20)
  do { if (& $Condition) { return }; Start-Sleep -Milliseconds 100 } while ([DateTime]::UtcNow -lt $deadline)
  throw $Message
}
function Start-App([bool]$Packaged, [int]$Port, [string]$Mutex, [string]$Logs, [string]$HermesExecutable = $fixture) {
  $arguments = '-HermesPath "' + $HermesExecutable + '" -Port ' + $Port + ' -InstanceMutexName ' + $Mutex + ' -LogDirectory "' + $Logs + '"'
  if ($Packaged) { $p = Start-Process $exe -ArgumentList $arguments -PassThru }
  else { $p = Start-Process powershell.exe -ArgumentList ('-NoProfile -STA -WindowStyle Hidden -File "' + $source + '" ' + $arguments) -PassThru }
  $owned.Add($p); return $p
}
try {
  foreach ($packaged in @($false, $true)) {
    $port = Free-Port
    $mutex = 'Local\HermesTray.Tests.' + [Guid]::NewGuid().ToString('N')
    $logs = Join-Path $work ([Guid]::NewGuid().ToString('N'))
    $first = Start-App $packaged $port $mutex $logs
    Wait-Until { Listening $port } 'Server did not start through the real launcher.'
    $trayLog = Join-Path $logs 'tray.log'
    Wait-Until { (Test-Path $trayLog) -and ((Read-SharedLog $trayLog) -match 'Authenticated HTTP readiness verified') } 'Launcher never verified HTTP authentication.'
    $first.Refresh()
    if ($first.HasExited -or $first.MainWindowHandle -ne [IntPtr]::Zero) { throw 'Tray-only host must remain running without a main window.' }
    $childLog = Join-Path $logs 'server.log'
    Wait-Until { (Test-Path $childLog) -and ((Read-SharedLog $childLog) -match 'CHILD_PID=\d+') } 'Expected the actual fixture child process.'
    $childId = [int]([regex]::Match((Read-SharedLog $childLog), 'CHILD_PID=(\d+)').Groups[1].Value)
    $child = Get-Process -Id $childId -ErrorAction Stop
    $duplicate = Start-App (-not $packaged) $port $mutex $logs
    if (-not $duplicate.WaitForExit(10000) -or $duplicate.ExitCode -ne 0) { throw 'Second source/EXE instance was not rejected silently.' }
    if ($first.HasExited -or -not (Listening $port)) { throw 'Duplicate interfered with the owned server.' }
    $first.Kill(); $first.WaitForExit()
    Wait-Until { -not (Listening $port) } 'Force-killed tray host left the server listening.'
    Wait-Until { $child.Refresh(); $child.HasExited } 'Force-killed tray host left its descendant alive.'
    $child.Dispose()
    $replacement = Start-App $packaged $port $mutex $logs
    Wait-Until { Listening $port } 'Restart after forced termination failed.'
    $replacement.Kill(); $replacement.WaitForExit()
    Wait-Until { -not (Listening $port) } 'Replacement left the server running.'
    Write-Output ('PASS: ' + $(if ($packaged) { 'EXE' }else { 'script' }) + ' tray-only startup, source/EXE singleton, forced-exit tree cleanup, restart; paths with spaces.')
    $badLogs = Join-Path $work ('missing-' + [Guid]::NewGuid().ToString('N'))
    $bad = Start-App $packaged (Free-Port) ('Local\HermesTray.Tests.' + [Guid]::NewGuid().ToString('N')) $badLogs (Join-Path $work 'missing.exe')
    if (-not $bad.WaitForExit(15000) -or $bad.ExitCode -ne 2) { throw 'Missing-Hermes launcher must automatically exit with code 2.' }
    if ((Read-SharedLog (Join-Path $badLogs 'tray.log')) -notmatch 'HermesMissing') { throw 'Missing-Hermes launcher did not write an actionable diagnostic.' }
    if (Test-Path (Join-Path $badLogs 'server.log')) { throw 'Missing-Hermes launcher attempted to start a server.' }
    Write-Output ('PASS: ' + $(if ($packaged) { 'EXE' }else { 'script' }) + ' missing-Hermes notification path auto-exits with code 2, without starting a server.')
  }
}
finally {
  foreach ($p in $owned) { if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() }; $p.Dispose() }
  # Cleanup only fixture processes from this test's unique directory if an assertion failed.
  foreach ($p in @(Get-Process FakeHermes -ErrorAction SilentlyContinue)) {
    try { if ($p.Path -eq $fixture) { $p.Kill(); $p.WaitForExit() } }finally { $p.Dispose() }
  }
}
