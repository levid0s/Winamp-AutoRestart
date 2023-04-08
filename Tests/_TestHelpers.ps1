. "$PSScriptRoot/../../useful\ps-winhelpers\_PS-WinHelpers.ps1"
. "$PSScriptRoot/../_Winamp-AutoRestartHelpers.ps1"

$DebugPreference = 'Continue'
$InformationPreference = 'SilentlyContinue'
$VerbosePreference = 'Continue'

$PsShell = Get-Process -Id $PID | Select-Object -ExpandProperty Path
$WinampPath = 'N:\Tools\Winamp-58portable\winamp.exe'
$TestMP3 = './Fixtures/5-minutes-of-silence.mp3' | Resolve-Path
$ScriptPath = '../Invoke-WinampAutoRestart.ps1' | Resolve-Path

####
#Region Prep Winamp Staing
####

function New-WinampStagingArea {
  param(
    [Parameter(Mandatory)][string]$FixturesPath,
    [Parameter(Mandatory)][string]$TestMP3
  )

  $WinampStaging = "$env:LOCALAPPDATA\Temp\$(New-Guid)\WinampStaging"

  New-Item -Path $TestDrive -ItemType Directory -Force -ErrorAction Stop | Out-Null

  if (!(Test-Path $TestMP3)) {
    Throw "Test MP3 file not found: $TestMP3"
  }

  $Repetitions = 30

  $TestMP3 = Resolve-Path $TestMP3

  Write-Verbose 'Preparing Winamp staging area...'
  Copy-Item -Path "$FixturesPath\Settings" -Destination "$WinampStaging\Settings" -Recurse -Force
  if ($DebugPreference -eq 'Continue') {
    explorer $WinampStaging
  }

  $TestPlaylist = "$WinampStaging\Settings\Winamp.m3u"
  Write-Verbose "Creating test playlist at $TestPlaylist"
  $Songlist = @($TestMP3) * $Repetitions
  Set-Content -Path $TestPlaylist -Value ($Songlist -join "`n") -Force -NoNewline
  $TestPlaylist = Resolve-Path $TestPlaylist
  $WinampStaging = Resolve-Path $WinampStaging
  Write-Debug "Staging area ready: $WinampStaging"

  return $WinampStaging
}

####
#Endregion
####

####
#Region Start-TestWinamp
####

Function Start-TestWinamp {
  param(
    [Parameter(Mandatory)][string]$WinampPath,
    [Parameter(Mandatory)][string]$WorkingDirectory,
    [switch]$NoAPI
  )
  Write-Debug "Starting test Winamp: $WinampPath, WorkDir: $WorkingDirectory"

  if (!(Test-Path $WinampPath)) {
    Throw "Winamp path not found: $WinampPath"
  }

  if (!(Test-Path $WorkingDirectory)) {
    Throw "Working directory not found: $WorkingDirectory"
  }

  $process = Start-Process -FilePath $WinampPath -ArgumentList '/NOREG', '/PLAY' -WorkingDirectory $WorkingDirectory -ErrorAction Stop -PassThru
  Start-Sleep -Milliseconds 500
  if ($process.HasExited) {
    Throw "Winamp failed to start: $($process.ExitCode)"
  }
  Start-SleepUntilTrue -Condition { [long]$process.MainWindowHandle -gt 0 } -Seconds 30
  if (!$NoAPI) {
    Wait-WinampInit | Out-Null
  }
  return $process
}

function Remove-WinampStagingArea {
  param(
    [Parameter(Mandatory)][string]$Path
  )

  ## Stop Winamp
  $process = Get-Process winamp -ErrorAction SilentlyContinue
  if ($process) {  
    &($process.Path) /close
    Start-SleepUntilTrue -Seconds 30 -Condition { $process.HasExited }
    if (!$process.HasExited) {
      $process.Kill()
      $process.WaitForExit()
    }
    Start-SleepUntilTrue -Seconds 30 -Condition { $process.HasExited }
    Start-Sleep -Milliseconds 500
  }
  
  ## Delete Staging Area
  Write-Verbose "Destroying Winamp staging area: $Path"
  Remove-Item -Recurse -Force -Path $Path -ErrorAction SilentlyContinue
  $parent = Split-Path $Path -Parent 
  if (!(Get-ChildItem -Path $parent -Recurse -Force -ErrorAction SilentlyContinue)) {
    Remove-Item -Path $parent -Force -ErrorAction SilentlyContinue
  }
}

####
#Endregion
####

####
#Region Error Checking
####

$process = Get-Process 'winamp' -ErrorAction SilentlyContinue
if ($process) {
  $data = $process | Select-Object Id, Path
  Write-Output "$($data | Out-String)"
  Throw 'Winamp is already running and it must be closed before testing can start.'
}

$process = Get-WmiObject Win32_Process | Where-Object Commandline -Match 'powershell.*[wW]inamp.*(?<!Tests).ps1'
if ($process) {
  $data = $process | Select-Object ProcessId, CommandLine
  Write-Output "$($data | Out-String)"
  Throw 'WinampAutoRestart script is already running, please exit.'
}

####
#Endregion
####