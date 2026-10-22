$ErrorActionPreference = 'Stop'
$work = Join-Path $env:TMPDIR ('HermesTray.Logging.' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$fixture = Join-Path $work 'FakeHermes.exe'
Add-Type -Path (Join-Path $PSScriptRoot 'fixtures\FakeHermes.cs') -OutputAssembly $fixture -OutputType ConsoleApplication
$context = & (Join-Path $PSScriptRoot '..\HermesTray.ps1') -NoRun -HermesPath $fixture -LogDirectory $work
$context.Dispose()
$path = Join-Path $work 'flood.log'
$process = [HermesTray.Runtime.OwnedProcess]::new($fixture, '--flood', $path)
try {
  $clock = [Diagnostics.Stopwatch]::StartNew()
  while ($process.ActiveProcessCount -gt 0 -and $clock.Elapsed.TotalSeconds -lt 20) { Start-Sleep -Milliseconds 30 }
  if ($process.ActiveProcessCount -gt 0) { throw 'Output capture blocked the child.' }
} finally { $process.Dispose() }
$files = @([IO.Directory]::GetFiles($work, 'flood.log*'))
if ($files.Count -gt 3 -or $files.Count -lt 2) { throw 'Expected bounded output with at most two backups.' }
foreach ($file in $files) { if ([IO.FileInfo]::new($file).Length -gt 1048576) { throw 'Server output exceeded its per-file limit.' } }
Write-Output 'PASS: server output remains bounded while the child continues writing.'

$blockedBackup = Join-Path $work 'blocked.log.2'
[IO.File]::WriteAllText($blockedBackup, 'read-only rotation fixture')
[IO.File]::SetAttributes($blockedBackup, [IO.FileAttributes]::ReadOnly)
$process = $null
try {
  $process = [HermesTray.Runtime.OwnedProcess]::new($fixture, '--flood', (Join-Path $work 'blocked.log'))
  $clock.Restart()
  while ($process.ActiveProcessCount -gt 0 -and $clock.Elapsed.TotalSeconds -lt 20) { Start-Sleep -Milliseconds 30 }
  if ($process.ActiveProcessCount -gt 0) { throw 'A failed log sink blocked the child.' }
  $process.Dispose()
  if (-not $process.OutputFailed) { throw 'Rotation failure was not reported to the supervisor.' }
  Write-Output 'PASS: failed log rotation is reported without blocking the child or cleanup.'
} finally {
  if ($process) { $process.Dispose() }
  [IO.File]::SetAttributes($blockedBackup, [IO.FileAttributes]::Normal)
}
