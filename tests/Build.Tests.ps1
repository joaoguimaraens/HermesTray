$ErrorActionPreference = 'Stop'
$work = Join-Path $env:TMPDIR ('HermesTray.BuildTest.' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$module = Join-Path $work 'EmptyCompiler.psm1'
# A compiler fixture returning without creating output must never certify an old EXE.
[IO.File]::WriteAllText($module, 'function Invoke-PS2EXE { param([string]$InputFile,[string]$OutputFile) }; Export-ModuleMember -Function Invoke-PS2EXE')
$old = Join-Path $work 'HermesTray.exe'
[IO.File]::WriteAllText($old, 'old executable sentinel')
$stdout = Join-Path $work 'stdout.txt'; $stderr = Join-Path $work 'stderr.txt'
$arguments = '-NoProfile -STA -File "' + (Join-Path $PSScriptRoot '..\Build.ps1') + '" -ModulePath "' + $module + '" -OutputDirectory "' + $work + '"'
$process = Start-Process powershell.exe -ArgumentList $arguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
try {
  if (-not $process.WaitForExit(30000)) { throw 'Compiler fixture timed out.' }
  if ($process.ExitCode -eq 0) { throw 'Build falsely reported success using an existing executable.' }
  if ([IO.File]::ReadAllText($stderr) -notlike '*no fresh executable*') { throw 'Expected a fresh-output verification failure.' }
}
finally { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }; $process.Dispose() }
if ([IO.File]::ReadAllText($old) -ne 'old executable sentinel') { throw 'Failed compilation overwrote the existing executable.' }
Write-Output 'PASS: failed/empty compiler cannot report success or overwrite a previous executable.'

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$licensePath = Join-Path $root 'LICENSE'
if (-not [IO.File]::Exists($licensePath)) { throw 'Repository LICENSE is missing.' }
$dist = Join-Path $root 'dist'
$entries = @([IO.Directory]::GetFileSystemEntries($dist))
if ($entries.Count -ne 1 -or [IO.Path]::GetFileName($entries[0]) -ne 'HermesTray.exe') { throw 'dist must contain only HermesTray.exe.' }
# Loading resources does not execute the application or start the server.
$assembly = [Reflection.Assembly]::LoadFile((Join-Path $dist 'HermesTray.exe'))
$resources = @($assembly.GetManifestResourceNames() | Where-Object { $_.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase) })
if ($resources.Count -ne 1) { throw 'Embedded application script was not found.' }
$stream = $assembly.GetManifestResourceStream($resources[0])
$reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
try {
  $embedded = $reader.ReadToEnd()
  if (-not $embedded.Contains([IO.File]::ReadAllText($licensePath))) { throw 'The executable does not include the complete MIT notice.' }
  if (-not $embedded.Contains([IO.File]::ReadAllText((Join-Path $root 'THIRD-PARTY-NOTICES.txt')))) { throw 'Third-party notices were not embedded in full.' }
  if (-not $embedded.Contains('Copyright (c) 2025 Nous Research')) { throw 'The upstream icon copyright was not retained.' }
} finally { $reader.Dispose(); $stream.Dispose() }
Write-Output 'PASS: dist contains one executable with the complete repository LICENSE embedded.'
