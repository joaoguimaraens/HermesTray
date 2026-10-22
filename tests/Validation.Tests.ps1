$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Helpers.ps1')
$source = Join-Path $PSScriptRoot '..\HermesTray.ps1'
$work = Join-Path $env:TMPDIR ('HermesTray.Validation.' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)

$context = & $source -NoRun -HermesPath (Join-Path $work 'missing.exe') -Port (Free-Port) -LogDirectory $work
try {
  if (-not $context.GetType().GetProperty('IsClosed')) { throw 'Fatal prerequisite failures do not automatically close the app.' }
  $context.FailureNoticeMilliseconds = 100
  $context.Start()
  Wait-Tray { $context.IsClosed } 'Missing Hermes left a resident tray process.'
  if ($context.ResultCode -ne 2 -or $context.FailureCode -ne 'HermesMissing') { throw 'Missing executable must have a specific diagnostic and exit code.' }
  if ($context.ServerProcessId -ne 0) { throw 'Missing Hermes must not launch a server.' }
  if ($context.Tray.Visible) { throw 'Fatal prerequisite failure left the tray icon visible.' }
  if ([Windows.Forms.Application]::OpenForms.Count -ne 0) { throw 'Validation must not open a form.' }
  Write-Output 'PASS: missing Hermes fails before launch, reports a safe diagnostic and automatically exits.'
}
finally { $context.Dispose() }

$fixture = Join-Path $work 'FakeHermes.exe'
Add-Type -Path (Join-Path $PSScriptRoot 'fixtures\FakeHermes.cs') -OutputAssembly $fixture -OutputType ConsoleApplication
$previousMode = $env:HERMESTRAY_FIXTURE_MODE
try {
  foreach ($mode in @('version-fail', 'wrong-version', 'help-fail', 'unsupported-serve', 'hang-version')) {
    $env:HERMESTRAY_FIXTURE_MODE = $mode
    $logs = Join-Path $work $mode
    $context = & $source -NoRun -HermesPath $fixture -Port (Free-Port) -LogDirectory $logs
    try {
      if (-not $context.GetType().GetProperty('CliTimeoutMilliseconds')) { throw 'Bounded CLI preflight is missing.' }
      $context.CliTimeoutMilliseconds = 300
      $context.FailureNoticeMilliseconds = 100
      $context.Start()
      Wait-Tray { $context.IsClosed } ('CLI failure did not exit: ' + $mode)
      if ($context.ResultCode -ne 3 -or $context.ServerProcessId -ne 0) { throw 'CLI preflight failure must not launch the server.' }
      if ($mode -eq 'hang-version' -and $context.FailureCode -ne 'CliTimeout') { throw 'Hanging CLI must be classified as a timeout.' }
      if ([IO.Directory]::GetFiles($logs, '.probe-*.log').Length -ne 0) { throw 'CLI probe output was not removed.' }
      if ([IO.File]::ReadAllText((Join-Path $logs 'tray.log')).Contains('DO_NOT_LOG_SENSITIVE_MARKER')) { throw 'CLI output leaked into validation logs.' }
      Write-Output ('PASS: ' + $mode + ' is rejected before server launch with bounded cleanup.')
    }
    finally { $context.Dispose() }
  }
  $env:HERMESTRAY_FIXTURE_MODE = 'hang-version'
  $context = & $source -NoRun -HermesPath $fixture -Port (Free-Port) -LogDirectory (Join-Path $work 'cancelled')
  try {
    $context.Start()
    Wait-Tray { @(Get-Process FakeHermes -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $fixture }).Count -gt 0 } 'Hanging CLI probe did not start.'
    $context.Menu.Items[0].PerformClick()
    Wait-Tray { @(Get-Process FakeHermes -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $fixture }).Count -eq 0 } 'Exit left a CLI probe running.'
    if (-not $context.IsClosed -or $context.ResultCode -ne 0) { throw 'User cancellation must be a normal exit.' }
    Write-Output 'PASS: Exit remains available during CLI validation and cancels the owned probe.'
  }
  finally { $context.Dispose() }
}
finally { $env:HERMESTRAY_FIXTURE_MODE = $previousMode }
