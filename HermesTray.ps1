#requires -Version 5.1

<#
Tray-only Hermes server owner. No windows or server-wide stop commands.
-NoRun constructs a context for isolated tests without starting a server.
#>
param(
  [string]$HermesPath,
  [ValidateScript({ $ip = $null; [Net.IPAddress]::TryParse($_, [ref]$ip) -and $ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and $ip.ToString() -eq $_ })]
  [string]$BindAddress = '0.0.0.0',
  [ValidateRange(1, 65535)][int]$Port = 9119,
  [string]$LogDirectory = (Join-Path $env:LOCALAPPDATA 'HermesTray\logs'),
  [string]$InstanceMutexName = ('Local\HermesTray.' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value),
  [switch]$NoRun
)

$ErrorActionPreference = 'Stop'

$mutex = $null

if (-not $NoRun) {
  $mutex = [Threading.Mutex]::new($false, $InstanceMutexName)
  
  try {
    $owned = $mutex.WaitOne(0)
  }
  catch [Threading.AbandonedMutexException] {
    $owned = $true
  }
  
  if (-not $owned) {
    $mutex.Dispose();
    return
  }
}

$context = $null

try {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  [Windows.Forms.Application]::EnableVisualStyles()
  $embeddedRuntime = ''
  # EMBED_RUNTIME_CS
  $embeddedIconIco = ''
  # EMBED_ICON_ICO
  $fromScript = $PSCommandPath -and [IO.Path]::GetExtension($PSCommandPath) -eq '.ps1'
  
  if ($fromScript) {
    $root = [IO.Path]::GetDirectoryName($PSCommandPath)
    $runtimeSource = [IO.File]::ReadAllText([IO.Path]::Combine($root, 'src\Runtime.cs'))
    $iconBytes = [IO.File]::ReadAllBytes([IO.Path]::Combine($root, 'assets\icon.ico'))
  }
  else {
    $runtimeSource = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($embeddedRuntime))
    $iconBytes = [Convert]::FromBase64String($embeddedIconIco)
  }
  
  if (-not ('HermesTray.Runtime.TrayApplication' -as [type])) {
    Add-Type -TypeDefinition $runtimeSource -ReferencedAssemblies @('System', 'System.Core', 'System.Windows.Forms', 'System.Drawing', 'System.Web.Extensions')
  }
  
  if (-not $HermesPath) {
    $command = Get-Command hermes.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    
    if ($command) {
      $HermesPath = $command.Source

    }
    else {
      $HermesPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\hermes.exe'
    }
  }
  
  try {
    $HermesPath = [IO.Path]::GetFullPath($HermesPath)
  }
  catch {
    # Preflight handles invalid paths with the same safe missing-Hermes notification.
  }
  

  $arguments = 'serve --host ' + $BindAddress
  
  if ($Port -ne 9119) {
    $arguments += ' --port ' + $Port
  }
  
  $icon = [HermesTray.Runtime.IconLoader]::Load($iconBytes, [Windows.Forms.SystemInformation]::SmallIconSize)
  
  $context = [HermesTray.Runtime.TrayApplication]::new($icon, $HermesPath, $arguments, $Port, $LogDirectory, $BindAddress)
  
  if ($NoRun) {
    $context.NotifyFailures = $false;
    return $context
  }
  
  $context.Start()
  [Windows.Forms.Application]::Run($context)
  
  if ($context.ResultCode -ne 0) {
    exit $context.ResultCode
  }
}
catch {
  [void][IO.Directory]::CreateDirectory($LogDirectory)
  [IO.File]::AppendAllText((Join-Path $LogDirectory 'tray.log'), [DateTime]::Now.ToString('s') + ' ' + $_.Exception.Message + [Environment]::NewLine)
  
  if ($NoRun) { throw }
  exit 1
}
finally {
  if ($context -and -not $NoRun) {
    $context.Dispose()
  }
  
  if ($mutex) {
    try {
      $mutex.ReleaseMutex()
    }
    finally {
      $mutex.Dispose()
    }
  }
}
