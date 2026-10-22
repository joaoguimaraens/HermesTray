$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$work = Join-Path $env:TMPDIR ('HermesTray.Process.' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$fixture = Join-Path $work 'FakeHermes.exe'
Add-Type -Path (Join-Path $PSScriptRoot 'fixtures\FakeHermes.cs') -OutputAssembly $fixture -OutputType ConsoleApplication
$hostScript = Join-Path $work 'atomic-host.ps1'
$marker = Join-Path $work 'created.pid'
# Widen the existing post-creation seam only in a disposable child host.
$hostCode = @'
param($Runtime, $Fixture, $Marker)
$ErrorActionPreference = 'Stop'
$code = [IO.File]::ReadAllText($Runtime)
$seam = 'process = pi.process; ProcessId = (int)pi.processId;'
if (-not $code.Contains($seam)) { throw 'Atomic creation test seam changed.' }
$env:HERMESTRAY_ATOMIC_MARKER = $Marker
$code = $code.Replace($seam, $seam + ' File.WriteAllText(Environment.GetEnvironmentVariable("HERMESTRAY_ATOMIC_MARKER"), ProcessId.ToString()); Thread.Sleep(Timeout.Infinite);')
Add-Type -TypeDefinition $code -ReferencedAssemblies @('System','System.Core','System.Windows.Forms','System.Drawing','System.Web.Extensions')
$owned = [HermesTray.Runtime.OwnedProcess]::new($Fixture, '--version', $Marker + '.log')
$owned.Dispose()
'@
[IO.File]::WriteAllText($hostScript, $hostCode)
$processArgs = '-NoProfile -STA -File "' + $hostScript + '" -Runtime "' + (Join-Path $root 'src\Runtime.cs') + '" -Fixture "' + $fixture + '" -Marker "' + $marker + '"'
$hostProcess = Start-Process powershell.exe -ArgumentList $processArgs -RedirectStandardError (Join-Path $work 'host.stderr') -PassThru -WindowStyle Hidden
$child = $null
try {
  [void]$hostProcess.Handle
  $clock = [Diagnostics.Stopwatch]::StartNew()
  while (-not [IO.File]::Exists($marker) -and $clock.Elapsed.TotalSeconds -lt 20) { Start-Sleep -Milliseconds 30 }
  if (-not [IO.File]::Exists($marker)) { throw ('Child was not created: ' + [IO.File]::ReadAllText((Join-Path $work 'host.stderr'))) }
  $child = Get-Process -Id ([int][IO.File]::ReadAllText($marker))
  [void]$child.Handle
  $hostProcess.Kill(); $hostProcess.WaitForExit()
  if (-not $child.WaitForExit(5000)) { throw 'Host termination before ResumeThread left an unowned suspended process.' }
  Write-Output 'PASS: a process is already in the kill-on-close job when CreateProcess returns.'
} finally {
  if (-not $hostProcess.HasExited) { $hostProcess.Kill(); $hostProcess.WaitForExit() }; $hostProcess.Dispose()
  if ($child) { if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit() }; $child.Dispose() }
}
