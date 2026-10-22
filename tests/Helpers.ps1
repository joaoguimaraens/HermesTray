function Free-Port {
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  try {
    $listener.Start()
    return $listener.LocalEndpoint.Port
  } finally { $listener.Stop() }
}

function Wait-Tray([scriptblock]$Condition, [string]$Message) {
  $clock = [Diagnostics.Stopwatch]::StartNew()
  do {
    [Windows.Forms.Application]::DoEvents()
    if (& $Condition) { return }
    Start-Sleep -Milliseconds 30
  } while ($clock.Elapsed.TotalSeconds -lt 15)
  throw $Message
}

function Read-SharedLog([string]$Path) {
  $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  $reader = [IO.StreamReader]::new($stream)
  try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}
