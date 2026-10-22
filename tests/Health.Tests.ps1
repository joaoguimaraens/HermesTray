$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Helpers.ps1')
$work = Join-Path $env:TMPDIR ('HermesTray.Health.' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$fixture = Join-Path $work 'FakeHermes.exe'
Add-Type -Path (Join-Path $PSScriptRoot 'fixtures\FakeHermes.cs') -OutputAssembly $fixture -OutputType ConsoleApplication
$previousControl = $env:HERMESTRAY_FIXTURE_CONTROL
$previousMode = $env:HERMESTRAY_FIXTURE_MODE
$context = $null
try {
  $env:HERMESTRAY_FIXTURE_MODE = ''
  $env:HERMESTRAY_FIXTURE_CONTROL = Join-Path $work 'control.txt'
  [IO.File]::WriteAllText($env:HERMESTRAY_FIXTURE_CONTROL, '')
  $port = Free-Port
  $context = & (Join-Path $PSScriptRoot '..\HermesTray.ps1') -NoRun -HermesPath $fixture -Port $port -LogDirectory $work
  if ($context.HttpTimeoutMilliseconds -ne 5000 -or $context.UnavailableTimeoutMilliseconds -ne 30000) { throw 'Health monitoring defaults changed.' }
  $context.FailureNoticeMilliseconds = 100
  $context.Start()
  Wait-Tray { $context.State -eq 'Running' } 'Fixture did not become ready.'
  [IO.File]::WriteAllText($env:HERMESTRAY_FIXTURE_CONTROL, 'http-error')
  Wait-Tray { $context.State -eq 'Degraded' } 'HTTP failure did not degrade health.'
  $clock = [Diagnostics.Stopwatch]::StartNew()
  while ($clock.ElapsedMilliseconds -lt 4000) {
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 30
  }
  if ($context.IsClosed -or $context.ResultCode -ne 0 -or $context.State -ne 'Degraded') { throw 'Transient failure still closes the server after three seconds.' }
  if ($context.AuthenticationVerified) { throw 'Degraded health still claims verified readiness.' }
  [IO.File]::WriteAllText($env:HERMESTRAY_FIXTURE_CONTROL, '')
  Wait-Tray { $context.State -eq 'Running' } 'Health did not recover.'
  if (-not $context.AuthenticationVerified) { throw 'Recovery did not verify authentication.' }
  if ((Read-SharedLog (Join-Path $work 'tray.log')) -notlike '*Health check failed: HTTP 503.*') { throw 'HTTP failure reason was not logged.' }
  Write-Output 'PASS: transient HTTP failures survive the old deadline and recover authenticated readiness.'
  $context.UnavailableTimeoutMilliseconds = 1000
  [IO.File]::WriteAllText($env:HERMESTRAY_FIXTURE_CONTROL, 'http-error')
  Wait-Tray { $context.IsClosed } 'Persistent failure did not close the server.'
  if ($context.FailureCode -ne 'ServerUnavailable') { throw 'Persistent failure had the wrong classification.' }
  Wait-Tray { -not [HermesTray.Runtime.TrayApplication]::IsPortListening($port) } 'Failure left the owned server alive.'
  Write-Output 'PASS: persistent unavailability stops the owned server after the configured grace period.'
  $result = [HermesTray.Runtime.StartupChecks]::CheckStatus($port, 5000, [Threading.CancellationToken]::None)
  if (-not $result.Retry -or $result.Reason -ne 'Transport ConnectFailure') { throw ('Connection refusal was not classified safely: ' + $result.Reason) }
  Write-Output 'PASS: connection refusal has a diagnostic category without response details.'
} finally {
  if ($context) { $context.Dispose() }
  $env:HERMESTRAY_FIXTURE_CONTROL = $previousControl
  $env:HERMESTRAY_FIXTURE_MODE = $previousMode
}
