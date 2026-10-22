#requires -Version 5.1
param(
  [Parameter(Mandatory = $true)]
  [string]$Tag,
  [string]$ExecutablePath,
  [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\Version.ps1')
$releaseVersion = Get-HermesTrayVersion $Tag
# Resolve defaults in the body: advanced scripts bind before PSScriptRoot is set in Windows PowerShell 5.1.
if (-not $ExecutablePath) { $ExecutablePath = Join-Path $PSScriptRoot 'dist\HermesTray.exe' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'release' }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
# Inspect the PE header without running the application.
$bytes = [IO.File]::ReadAllBytes($ExecutablePath)
if ($bytes.Length -lt 64 -or [BitConverter]::ToUInt16($bytes, 0) -ne 0x5a4d) {
  throw 'Only valid Windows x64 (AMD64) executables can be released.'
}
$pe = [BitConverter]::ToInt32($bytes, 0x3c)
if ($pe -lt 0 -or $pe -gt $bytes.Length - 6 -or [BitConverter]::ToUInt32($bytes, $pe) -ne 0x4550 -or [BitConverter]::ToUInt16($bytes, $pe + 4) -ne 0x8664) {
  throw 'Only valid Windows x64 (AMD64) executables can be released.'
}
$metadata = [Diagnostics.FileVersionInfo]::GetVersionInfo($ExecutablePath)
if ($metadata.FileVersion -ne $releaseVersion.FileVersion -or $metadata.FileDescription -ne 'HermesTray' -or $metadata.Comments -ne ('HermesTray ' + $releaseVersion.Tag + ' - Windows tray server launcher')) { throw 'Executable version does not match the requested release tag. Build with the same -Tag first.' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$zipPath = Join-Path $OutputDirectory ("HermesTray-$Tag-windows-x64.zip")
$scratch = if ($env:TMPDIR) { $env:TMPDIR } else { [IO.Path]::GetTempPath() }
$temporaryZip = Join-Path $scratch ('HermesTray.Release.' + [Guid]::NewGuid().ToString('N') + '.zip')

try {
  $archive = [IO.Compression.ZipFile]::Open($temporaryZip, [IO.Compression.ZipArchiveMode]::Create)
  try {
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $ExecutablePath, 'HermesTray.exe', [IO.Compression.CompressionLevel]::Optimal)
  } finally { $archive.Dispose() }
  [IO.File]::Copy($temporaryZip, $zipPath, $true)
} finally {
  if ([IO.File]::Exists($temporaryZip)) { [IO.File]::Delete($temporaryZip) }
}
Write-Output $zipPath
