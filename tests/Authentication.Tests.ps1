$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Helpers.ps1')
$source = Join-Path $PSScriptRoot '..\HermesTray.ps1'
$work = Join-Path $env:TMPDIR ('HermesTray.AuthTests.' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$fixture = Join-Path $work 'FakeHermes.exe'
Add-Type -Path (Join-Path $PSScriptRoot 'fixtures\FakeHermes.cs') -OutputAssembly $fixture -OutputType ConsoleApplication

$previous = $env:HERMESTRAY_FIXTURE_MODE
try {
  foreach ($case in @(
      @{Mode = 'unauth'; Code = 4 }, @{Mode = 'no-provider'; Code = 4 },
      @{Mode = 'bad-json'; Code = 7 }, @{Mode = 'bad-types'; Code = 7 }, @{Mode = 'redirect'; Code = 7 },
      @{Mode = 'tcp-only'; Code = 6 }, @{Mode = 'http-error'; Code = 6 },
      @{Mode = 'auth-refused'; Code = 4 }, @{Mode = 'early-exit'; Code = 5 }
    )) {
    $env:HERMESTRAY_FIXTURE_MODE = $case.Mode
    $port = Free-Port; $logs = Join-Path $work $case.Mode
    $context = & $source -NoRun -HermesPath $fixture -Port $port -LogDirectory $logs
    try {
      if (-not $context.GetType().GetProperty('StartupTimeoutMilliseconds')) { throw 'Authenticated HTTP readiness validation is missing.' }
      $context.FailureNoticeMilliseconds = 100
      $context.StartupTimeoutMilliseconds = 2500
      $context.HttpTimeoutMilliseconds = 250
      $context.Start()
      Wait-Tray { $context.IsClosed -or $context.State -eq 'Running' } ('No bounded outcome: ' + $case.Mode)
      if (-not $context.IsClosed) { throw ('Unsafe/incompatible backend was accepted: ' + $case.Mode) }
      if ($context.ResultCode -ne $case.Code) { throw ('Wrong failure code for ' + $case.Mode + ': ' + $context.ResultCode + ' ' + $context.FailureCode) }
      Wait-Tray { -not [HermesTray.Runtime.TrayApplication]::IsPortListening($port) } 'Failure left the owned server listening.'
      if ($context.Tray.Visible) { throw 'Failure left a resident tray icon.' }
      foreach ($log in [IO.Directory]::GetFiles($logs, '*.log')) {
        if ([IO.File]::ReadAllText($log).Contains('DO_NOT_LOG_SENSITIVE_MARKER')) { throw 'HTTP response or CLI output leaked into logs.' }
      }
      Write-Output ('PASS: ' + $case.Mode + ' rejected, owned server stopped, app closed; no response-body logging.')
    }
    finally { $context.Dispose() }
  }
  foreach ($mode in @('', 'oauth')) {
    $env:HERMESTRAY_FIXTURE_MODE = $mode
    $port = Free-Port
    $context = & $source -NoRun -HermesPath $fixture -Port $port -LogDirectory (Join-Path $work ('valid-' + [Guid]::NewGuid().ToString('N')))
    try {
      $context.Start()
      Wait-Tray { $context.State -eq 'Running' -or $context.IsClosed } 'Valid authenticated backend did not become ready.'
      if ($context.State -ne 'Running' -or $context.ResultCode -ne 0 -or -not $context.AuthenticationVerified) { throw 'Valid password/OAuth authentication was rejected.' }
      $context.Menu.Items[0].PerformClick()
      Wait-Tray { -not [HermesTray.Runtime.TrayApplication]::IsPortListening($port) } 'Exit left an authenticated backend alive.'
      Write-Output ('PASS: authenticated backend accepted (' + $(if ($mode) { $mode }else { 'basic' }) + ').')
    }
    finally { $context.Dispose() }
  }
  # An unrelated process can claim the port after preflight; never probe or kill it.
  $env:HERMESTRAY_FIXTURE_MODE = 'no-listener'
  $port = Free-Port; $external = $null
  $externalLog = Join-Path $work 'external-listener.log'
  $context = & $source -NoRun -HermesPath $fixture -Port $port -LogDirectory (Join-Path $work 'port-race')
  try {
    $context.FailureNoticeMilliseconds = 100
    $context.Start()
    Wait-Tray { $context.State -eq 'Starting' } 'Owned no-listener fixture did not start.'
    $external = Start-Process $fixture -ArgumentList @('--child', '--port', $port) -RedirectStandardOutput $externalLog -PassThru -WindowStyle Hidden
    Wait-Tray { $context.IsClosed } 'Foreign port ownership was not rejected.'
    if ($context.FailureCode -ne 'UnownedListener' -or $context.ResultCode -ne 7) { throw 'Expected an ownership-validation failure.' }
    if ($external.HasExited -or -not [HermesTray.Runtime.TrayApplication]::IsPortListening($port)) { throw 'Foreign listener was terminated.' }
    if ((Read-SharedLog $externalLog).Contains('FIXTURE_STATUS_REQUEST')) { throw 'HTTP validation contacted an external process.' }
    Write-Output 'PASS: port-ownership race rejected without probing or stopping the external server.'
  }
  finally {
    $context.Dispose()
    if ($external) { if (-not $external.HasExited) { $external.Kill(); $external.WaitForExit() }; $external.Dispose() }
  }
  # Old stderr must not misclassify a later, unrelated server failure.
  $sharedLogs = Join-Path $work 'reused-logs'
  foreach ($case in @(@{Mode = 'auth-refused'; Code = 4 }, @{Mode = 'early-exit'; Code = 5 })) {
    $env:HERMESTRAY_FIXTURE_MODE = $case.Mode
    $context = & $source -NoRun -HermesPath $fixture -Port (Free-Port) -LogDirectory $sharedLogs
    try {
      $context.FailureNoticeMilliseconds = 100; $context.Start()
      Wait-Tray { $context.IsClosed } 'Reused-log case did not terminate.'
      if ($context.ResultCode -ne $case.Code) { throw 'Historical server output changed the current failure classification.' }
    }
    finally { $context.Dispose() }
  }
  Write-Output 'PASS: diagnostics only inspect the current server launch, not stale authentication errors.'
}
finally { $env:HERMESTRAY_FIXTURE_MODE = $previous }
