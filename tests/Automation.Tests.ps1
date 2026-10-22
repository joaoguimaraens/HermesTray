$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach ($path in @('Test.ps1','.github\workflows\ci.yml','.github\actions\build\action.yml')) {
  if (-not [IO.File]::Exists((Join-Path $root $path))) { throw "Missing shared validation entry point: $path" }
}
$ci = [IO.File]::ReadAllText((Join-Path $root '.github\workflows\ci.yml'))
if ($ci -notmatch 'pull_request:' -or $ci -match 'contents: write') { throw 'PR validation must run with read-only repository access.' }
$release = [IO.File]::ReadAllText((Join-Path $root '.github\workflows\release.yml'))
if ($release -notmatch '(?m)^  publish:' -or $release -notmatch 'needs: build') { throw 'Publishing must be isolated after the read-only build job.' }
$tokens = $null; $errors = $null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Test.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
Write-Output 'PASS: CI and release share validation, with publication isolated from PR builds.'
