#requires -Version 5.1
param([switch]$Build, [string]$Tag)
$ErrorActionPreference = 'Stop'
if (-not $env:TMPDIR) { $env:TMPDIR = Join-Path $env:LOCALAPPDATA 'HermesTray\TestScratch' }
[void][IO.Directory]::CreateDirectory($env:TMPDIR)
$previousTemp = $env:TEMP; $previousTmp = $env:TMP
try {
  $env:TEMP = $env:TMPDIR; $env:TMP = $env:TMPDIR
  if ($Build) { & (Join-Path $PSScriptRoot 'Build.ps1') -Tag $Tag }
  $suites = @([IO.Directory]::GetFiles((Join-Path $PSScriptRoot 'tests'), '*.Tests.ps1') | Sort-Object)
  if ($suites.Count -eq 0) { throw 'No test suites found.' }
  foreach ($suite in $suites) {
    powershell.exe -NoProfile -STA -File $suite
    if ($LASTEXITCODE -ne 0) { throw ('Test suite failed: ' + [IO.Path]::GetFileName($suite)) }
  }
  Write-Output ("PASS: all {0} test suites passed." -f $suites.Count)
} finally { $env:TEMP = $previousTemp; $env:TMP = $previousTmp }
