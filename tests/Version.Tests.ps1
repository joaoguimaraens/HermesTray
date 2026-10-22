$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $root 'scripts\Version.ps1')
$v = Get-HermesTrayVersion 'v1.2.3-rc--1'
if ($v.FileVersion -ne '1.2.3.0' -or $v.Tag -ne 'v1.2.3-rc--1') { throw 'Tag/version mapping failed.' }
foreach ($invalid in @('v01.2.3','v1.2','v1.2.70000','v1.2.3-01','v1.2.3/escape')) {
  $rejected = $false
  try { Get-HermesTrayVersion $invalid | Out-Null } catch { $rejected = $true }
  if (-not $rejected) { throw "Invalid version accepted: $invalid" }
}
$work = Join-Path $env:TMPDIR ('HermesTray.Version.' + [Guid]::NewGuid().ToString('N'))
& (Join-Path $root 'Build.ps1') -OutputDirectory $work -Tag 'v1.2.3-rc--1'
$info = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $work 'HermesTray.exe'))
if ($info.FileVersion -ne '1.2.3.0' -or $info.FileDescription -ne 'HermesTray' -or $info.Comments -ne 'HermesTray v1.2.3-rc--1 - Windows tray server launcher') { throw 'Executable metadata does not match its release tag.' }
& (Join-Path $root 'Release.ps1') -ExecutablePath (Join-Path $work 'HermesTray.exe') -OutputDirectory $work -Tag 'v1.2.3-rc--1' | Out-Null
Write-Output 'PASS: semantic tags map to checked binary versions, including prerelease identity.'
