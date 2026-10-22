#requires -Version 5.1

param(
  [string]$ModulePath,
  [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'),
  [string]$Tag,
  [ValidatePattern('^[A-Fa-f0-9]{40}$')][string]$SigningCertificateThumbprint,
  [string]$TimestampServer = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\Version.ps1')
$releaseVersion = Get-HermesTrayVersion $Tag

if ($ModulePath) {
  Import-Module $ModulePath -ErrorAction Stop
} else {
  Import-Module ps2exe -RequiredVersion 1.0.18 -ErrorAction Stop
}

$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$outputPath = Join-Path $OutputDirectory 'HermesTray.exe'

if ([IO.File]::Exists($outputPath)) {
  try {
    $probe = [IO.File]::Open($outputPath, 'Open', 'ReadWrite', 'None');
    $probe.Dispose()
  } catch {
    throw 'HermesTray.exe is in use. Choose Exit in its tray menu or build into a different OutputDirectory.'
  }
}

$iconPath = Join-Path $PSScriptRoot 'assets\icon.ico'
$runtimePath = Join-Path $PSScriptRoot 'src\Runtime.cs'
$licensePath = Join-Path $PSScriptRoot 'LICENSE'
$noticesPath = Join-Path $PSScriptRoot 'THIRD-PARTY-NOTICES.txt'

if (-not [IO.File]::Exists($iconPath) -or -not [IO.File]::Exists($runtimePath)) {
  throw 'Missing assets/icon.ico or src/Runtime.cs.'
}

if (-not [IO.File]::Exists($licensePath) -or -not [IO.File]::Exists($noticesPath)) {
  throw 'Missing LICENSE or THIRD-PARTY-NOTICES.txt.'
}

$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'HermesTray.ps1'))

foreach ($item in @(
  @{ Marker='# EMBED_ICON_ICO'; Variable='embeddedIconIco'; Path=$iconPath },
  @{ Marker='# EMBED_RUNTIME_CS'; Variable='embeddedRuntime'; Path=$runtimePath }
)) {
  if (-not $source.Contains($item.Marker)) {
    throw ('Missing marker: ' + $item.Marker)
  }

  $assignment = '$' + $item.Variable + " = '" + [Convert]::ToBase64String([IO.File]::ReadAllBytes($item.Path)) + "'"
  $source = $source.Replace($item.Marker, $assignment)
}

# Preserve project and dependency notices in the single-file distribution.
$licenseText = [IO.File]::ReadAllText($licensePath)
$noticesText = [IO.File]::ReadAllText($noticesPath)
$source += "`r`n<#`r`nRelease: " + $releaseVersion.Tag + "`r`nProject license:`r`n" + $licenseText + "`r`nThird-party notices:`r`n" + $noticesText + "`r`n#>`r`n"
$copyright = [regex]::Match($licenseText, '(?m)^Copyright.*$').Value.Trim()

$scratch = $env:TMPDIR

if (-not $scratch) {
  $scratch = [IO.Path]::GetTempPath()
}

$temporaryBase = Join-Path $scratch ('HermesTray-' + [Guid]::NewGuid().ToString('N'))
$buildSource = $temporaryBase + '.ps1'
$compiledExe = $temporaryBase + '.exe'

try {
  [IO.File]::WriteAllText($buildSource, $source, [Text.UTF8Encoding]::new($true))
  Invoke-PS2EXE -InputFile $buildSource -OutputFile $compiledExe -NoConsole -NoError -NoOutput -STA -x64 `
    -IconFile $iconPath -Title 'HermesTray' -Product 'HermesTray' `
    -Description ('HermesTray ' + $releaseVersion.Tag + ' - Windows tray server launcher') -Version $releaseVersion.FileVersion -Copyright $copyright
  # A pre-existing output must never hide compiler failures in a child shell
  
  if (-not [IO.File]::Exists($compiledExe)) {
    throw 'Compilation failed: no fresh executable was produced.'
  }
  
  [void][Reflection.AssemblyName]::GetAssemblyName($compiledExe)
  if ([Diagnostics.FileVersionInfo]::GetVersionInfo($compiledExe).FileVersion -ne $releaseVersion.FileVersion) { throw 'Compiled version does not match the release tag.' }
  if ($SigningCertificateThumbprint) {
    $certificate = Get-Item ('Cert:\CurrentUser\My\' + $SigningCertificateThumbprint) -ErrorAction Stop
    if (-not $certificate.HasPrivateKey) { throw 'The signing certificate has no accessible private key.' }
    $signature = Set-AuthenticodeSignature -FilePath $compiledExe -Certificate $certificate -TimestampServer $TimestampServer -HashAlgorithm SHA256
    if ($signature.Status -ne 'Valid' -or (Get-AuthenticodeSignature -FilePath $compiledExe).Status -ne 'Valid') { throw 'Code signing could not be verified.' }
  }
  [IO.File]::Copy($compiledExe, $outputPath, $true)
} finally {
  if ([IO.File]::Exists($buildSource)) {
    [IO.File]::Delete($buildSource)
  }
  
  if ([IO.File]::Exists($compiledExe)) {
    [IO.File]::Delete($compiledExe)
  }
}

Write-Output ('Executable: ' + $outputPath)
