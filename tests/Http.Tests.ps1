$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Helpers.ps1')
$work = Join-Path $env:TMPDIR ('HermesTray.Http.' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$fixture = Join-Path $work 'FakeHermes.exe'
Add-Type -Path (Join-Path $PSScriptRoot 'fixtures\FakeHermes.cs') -OutputAssembly $fixture -OutputType ConsoleApplication
$context = & (Join-Path $PSScriptRoot '..\HermesTray.ps1') -NoRun -HermesPath $fixture -LogDirectory $work
$context.Dispose()
$port = Free-Port
$previous = $env:HERMESTRAY_FIXTURE_MODE; $child = $null
try {
  $env:HERMESTRAY_FIXTURE_MODE = 'slow-body'
  $child = Start-Process $fixture -ArgumentList @('--child','--port',$port) -PassThru -WindowStyle Hidden
  $clock = [Diagnostics.Stopwatch]::StartNew()
  while (-not [HermesTray.Runtime.TrayApplication]::IsPortListening($port) -and $clock.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 20 }
  $clock.Restart()
  $result = [HermesTray.Runtime.StartupChecks]::CheckStatus($port, 200, [Threading.CancellationToken]::None)
  if ($result.Reason -ne 'Timeout' -or -not $result.Retry -or $clock.ElapsedMilliseconds -gt 2000) { throw 'A trickling response bypassed the total HTTP deadline.' }
  Write-Output 'PASS: HTTP timeout bounds the entire response, not just each read.'
} finally {
  if ($child) { if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit() }; $child.Dispose() }
  $env:HERMESTRAY_FIXTURE_MODE = $previous
}
