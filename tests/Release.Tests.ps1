$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script = Join-Path $root 'Release.ps1'
$exe = Join-Path $root 'dist\HermesTray.exe'
$work = Join-Path $env:TMPDIR ('HermesTray.ReleaseTest.' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)

$tag = [regex]::Match([Diagnostics.FileVersionInfo]::GetVersionInfo($exe).Comments, 'v[0-9A-Za-z.-]+').Value
if (-not $tag) { throw 'Build output has no release identity.' }
powershell.exe -NoProfile -STA -File $script -Tag $tag -OutputDirectory $work
if ($LASTEXITCODE -ne 0) { throw 'Release packaging failed.' }
$zip = Join-Path $work ("HermesTray-$tag-windows-x64.zip")
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
try {
  if ($archive.Entries.Count -ne 1 -or $archive.Entries[0].FullName -cne 'HermesTray.exe') { throw 'ZIP must contain only HermesTray.exe at its root.' }
  $stream = $archive.Entries[0].Open()
  try {
    $actual = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash
    $expected = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    if ($actual -ne $expected) { throw 'Packaged executable differs from the build output.' }
  } finally { $stream.Dispose() }
} finally { $archive.Dispose() }
Write-Output 'PASS: release ZIP contains only the exact built executable at its root.'

# Deliberately mutate only the PE machine field; this fixture is never executed.
$bytes = [IO.File]::ReadAllBytes($exe)
$pe = [BitConverter]::ToInt32($bytes, 0x3c)
if ([BitConverter]::ToUInt16($bytes, $pe + 4) -ne 0x8664) { throw 'Build output is not AMD64.' }
$bytes[$pe + 4] = 0x4c; $bytes[$pe + 5] = 0x01
$fixture = Join-Path $work 'fixture-x86.exe'
[IO.File]::WriteAllBytes($fixture, $bytes)
function Assert-RejectedPackage([string]$tag, [string]$path, [string]$message) {
  $stderr = Join-Path $work ([Guid]::NewGuid().ToString('N') + '.stderr.txt')
  $processArgs = '-NoProfile -STA -File "' + $script + '" -Tag "' + $tag + '" -ExecutablePath "' + $path + '" -OutputDirectory "' + $work + '"'
  $process = Start-Process powershell.exe -ArgumentList $processArgs -RedirectStandardError $stderr -RedirectStandardOutput ($stderr + '.stdout.txt') -PassThru -WindowStyle Hidden
  try {
    [void]$process.Handle
    if (-not $process.WaitForExit(30000)) { throw 'Release validation timed out.' }
    if ($null -eq $process.ExitCode) { throw 'Release validation did not report an exit code.' }
    if ($process.ExitCode -eq 0) { throw "Invalid release input was incorrectly accepted: $tag" }
    if ([IO.File]::ReadAllText($stderr) -notlike "*$message*") { throw "Expected validation error: $message" }
  } finally { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }; $process.Dispose() }
}
Assert-RejectedPackage 'v0.2.1' $fixture 'Windows x64'
if ([IO.File]::Exists((Join-Path $work 'HermesTray-v0.2.1-windows-x64.zip'))) { throw 'Invalid architecture produced a release ZIP.' }
Write-Output 'PASS: non-x64 executables cannot be packaged as Windows x64.'

Assert-RejectedPackage 'not-a-version' $exe 'Invalid version tag'
if ([IO.File]::Exists((Join-Path $work 'HermesTray-not-a-version-windows-x64.zip'))) { throw 'Invalid tag produced a release ZIP.' }
Write-Output 'PASS: invalid release tags are rejected.'
Assert-RejectedPackage 'v99.98.97' $exe 'does not match'
Write-Output 'PASS: the archive tag cannot mislabel a different executable version.'
