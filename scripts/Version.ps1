function Get-HermesTrayVersion([string]$Tag) {
  if (-not $Tag) { $Tag = 'v' + [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\VERSION')).Trim() }
  $match = [regex]::Match($Tag, '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\z')
  if (-not $match.Success) { throw 'Invalid version tag. Use vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-prerelease.' }
  foreach ($index in 1..3) {
    $number = [uint16]0
    if (-not [uint16]::TryParse($match.Groups[$index].Value, [ref]$number)) { throw 'Version components must fit Windows file metadata (0..65535).' }
  }
  foreach ($id in $match.Groups[4].Value.Split('.')) {
    if ($id -match '^[0-9]+$' -and $id.Length -gt 1 -and $id.StartsWith('0')) { throw 'Numeric prerelease identifiers cannot have leading zeroes.' }
  }
  [pscustomobject]@{ Tag = $Tag; FileVersion = ($match.Groups[1].Value + '.' + $match.Groups[2].Value + '.' + $match.Groups[3].Value + '.0') }
}
