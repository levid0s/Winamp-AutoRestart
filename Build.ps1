function Get-ScriptPath {
  <#
  .SYNOPSIS
  Returns the full path to the powershell running script.

  .EXAMPLE
  Write-Host "Script path: $(Get-ScriptPath)"
  #>

  return (Get-PSCallStack)[1].ScriptName | Split-Path -Parent
}

$root = Get-ScriptPath

if (!(Test-Path "$root\temp")) {
  New-Item -ItemType Directory -Path "$root\temp"
  git clone https://github.com/levid0s/useful.git "$root\temp\useful"
}
else {
  git -C "$root\temp\useful" pull
}

Push-Location "$root\temp\useful"
$version = git rev-parse --short HEAD
Pop-Location

. "$root\temp\useful\ps-winhelpers\_PS-WinHelpers.ps1"

$FnSrc = Get-Command Register-PowerShellScheduledTask | Select-Object -ExpandProperty ScriptBlock

$FnSrc = @"
function Register-PowerShellScheduledTask {
  # source: https://github.com/levid0s/useful
  # commit: $version
$FnSrc
}
"@

Out-File _Helper.ps1 -InputObject $FnSrc

$FnSrc = @"


# source: https://github.com/levid0s/useful
# commit: $version
$(Get-Content -Path "$root\temp\useful\control-winapps\Control-WinApps.ps1")
"@

Out-File -FilePath .\_Helper.ps1 -InputObject $FnSrc -Append