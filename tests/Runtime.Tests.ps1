$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Helpers.ps1')
$source = Join-Path $PSScriptRoot '..\HermesTray.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
if ('NoRun' -notin @($ast.ParamBlock.Parameters.Name.VariablePath.UserPath)) { throw 'Tray-only runtime constructor is missing.' }

$scratch = $env:TMPDIR
if (-not $scratch) { throw 'Set TMPDIR to a test scratch directory.' }
$work = Join-Path $scratch ('HermesTray.Tests.' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$fixture = Join-Path $work 'FakeHermes.exe'
Add-Type -Path (Join-Path $PSScriptRoot 'fixtures\FakeHermes.cs') -OutputAssembly $fixture -OutputType ConsoleApplication

$context = $null; $external = $null
try {
  $port = Free-Port
  $context = & $source -NoRun -HermesPath $fixture -Port $port -LogDirectory $work
  if ($context -isnot [Windows.Forms.ApplicationContext]) { throw 'Expected a tray-only ApplicationContext.' }
  if ([Windows.Forms.Application]::OpenForms.Count -ne 0) { throw 'No forms may be created.' }
  if ($context.Menu.Items.Count -ne 1 -or $context.Menu.Items[0].Text -ne 'Exit') { throw 'Tray menu must contain only Exit.' }
  if (-not $context.Tray.Visible) { throw 'Tray must be visible.' }
  if ($context.Tray.Text -ne 'HermesTray - starting') { throw 'Startup tooltip must be in English.' }
  if ($context.Tray.Icon.Size -ne [Windows.Forms.SystemInformation]::SmallIconSize) { throw 'Tray icon must preserve native small-icon sizing.' }
  if ($context.Arguments -notlike 'serve --host 0.0.0.0*') { throw 'Requested command changed.' }
  $context.Start()
  Wait-Tray { $context.State -eq 'Running' -and $context.ActiveProcessCount -ge 2 } 'Owned server and its child did not start.'
  if ($context.Tray.Text -ne 'HermesTray - server running') { throw 'Running tooltip must be in English.' }
  $rootId = $context.ServerProcessId
  $context.Menu.Items[0].PerformClick()
  Wait-Tray { -not [HermesTray.Runtime.TrayApplication]::IsPortListening($port) } 'Exit left the server listening.'
  if ($context.Tray.Visible) { throw 'Exit left the tray icon visible.' }
  if (Get-Process -Id $rootId -ErrorAction SilentlyContinue) { throw 'Exit left the owned root process alive.' }
  $context.Dispose(); $context = $null
  Write-Output 'PASS: no forms, single Exit menu, requested command, owned root/child startup, Exit stops the tree.'

  # Never adopt or terminate a pre-existing listener, even on our target port.
  $external = Start-Process $fixture -ArgumentList @('--child', '--port', $port) -PassThru -WindowStyle Hidden
  Wait-Tray { [HermesTray.Runtime.TrayApplication]::IsPortListening($port) } 'External fixture did not start.'
  $context = & $source -NoRun -HermesPath $fixture -Port $port -LogDirectory $work
  $context.Start()
  if ($context.State -ne 'External' -or $context.ServerProcessId -ne 0) { throw 'Existing server must not be owned or replaced.' }
  if ($context.Tray.Text -ne 'HermesTray - port already in use') { throw 'Occupied-port tooltip must be in English.' }
  $context.Menu.Items[0].PerformClick()
  if ($external.HasExited -or -not [HermesTray.Runtime.TrayApplication]::IsPortListening($port)) { throw 'Exit terminated an external server.' }
  $context.Dispose(); $context = $null
  Write-Output 'PASS: pre-existing listener is preserved on startup and exit.'

  $context = & $source -NoRun -HermesPath (Join-Path $work 'missing.exe') -Port (Free-Port) -LogDirectory $work
  $context.Start()
  if ($context.State -ne 'Error' -or -not $context.LastError) { throw 'Missing executable must become a logged error, not open a dialog.' }
  if ($context.Tray.Text -ne 'HermesTray - error; check logs') { throw 'Error tooltip must be in English.' }
  $context.Menu.Items[0].PerformClick()
  Write-Output 'PASS: launch errors remain tray-only and Exit still works.'
}
finally {
  if ($context) { $context.Dispose() }
  if ($external) { if (-not $external.HasExited) { $external.Kill(); $external.WaitForExit() }; $external.Dispose() }
}
