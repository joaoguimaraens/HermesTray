$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Helpers.ps1')
$work = Join-Path $env:TMPDIR ('HermesTray.Monitor.' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$fixture = Join-Path $work 'FakeHermes.exe'
Add-Type -Path (Join-Path $PSScriptRoot 'fixtures\FakeHermes.cs') -OutputAssembly $fixture -OutputType ConsoleApplication

$previous = $env:HERMESTRAY_FIXTURE_MODE; $context = $null; $child = $null
try {
  $env:HERMESTRAY_FIXTURE_MODE = 'linger-wrapper'
  $port = Free-Port
  $context = & (Join-Path $PSScriptRoot '..\HermesTray.ps1') -NoRun -HermesPath $fixture -Port $port -LogDirectory $work
  $context.FailureNoticeMilliseconds = 100
  $context.UnavailableTimeoutMilliseconds = 1000
  $context.Start()
  Wait-Tray { $context.State -eq 'Running' } 'Backend never became ready.'
  $text = Read-SharedLog (Join-Path $work 'server.log')
  $childId = [int]([regex]::Match($text, 'CHILD_PID=(\d+)').Groups[1].Value)
  $child = Get-Process -Id $childId
  if ($child.Path -ne $fixture) { throw 'Refusing to stop a foreign process.' }
  $child.Kill(); $child.WaitForExit()
  Wait-Tray { $context.IsClosed } 'A surviving wrapper left the tray falsely reporting a running server.'
  if ($context.ResultCode -ne 5 -or $context.AuthenticationVerified) { throw 'Listener loss must clear readiness and fail safely.' }
  if (Get-Process -Id $context.ServerProcessId -ErrorAction SilentlyContinue) { throw 'Listener loss left the wrapper alive.' }
  Write-Output 'PASS: post-readiness listener loss clears readiness and stops the owned wrapper.'
  $context.Dispose(); $context = $null
  $context = & (Join-Path $PSScriptRoot '..\HermesTray.ps1') -NoRun -HermesPath $fixture -Port $port -LogDirectory $work -BindAddress '127.0.0.1'
  if ($context.Arguments -notlike 'serve --host 127.0.0.1*') { throw 'An explicit bind address was ignored.' }
  $context.Start()
  Wait-Tray { $context.State -eq 'Running' -or $context.IsClosed } 'Custom bind never completed.'
  if ($context.State -ne 'Running') { throw 'Loopback-bound backend failed ownership/status checks.' }
  Write-Output 'PASS: explicit IPv4 bind is passed to Hermes and used for readiness.'
} finally {
  if ($context) { $context.Dispose() }; if ($child) { $child.Dispose() }
  $env:HERMESTRAY_FIXTURE_MODE = $previous
}
