. "$PSScriptRoot/../../useful\ps-winhelpers\_PS-WinHelpers.ps1"
. "$PSScriptRoot/../_Winamp-AutoRestartHelpers.ps1"

$DebugPreference = 'Continue'
$InformationPreference = 'Continue'
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
    [Parameter(Mandatory)][string]$TestDrive,
    [Parameter(Mandatory)][string]$FixturesPath,
    [Parameter(Mandatory)][string]$TestMP3
  )

  if (!(Test-Path $TestDrive)) {
    Throw "TestDrive doesn't exist: $TestDrive"
  }
  if (!(Test-Path $TestMP3)) {
    Throw "Test MP3 file not found: $TestMP3"
  }

  $Repetitions = 30

  $TestDrive = Resolve-Path $TestDrive
  $TestMP3 = Resolve-Path $TestMP3
  $WinampTemp = "$TestDrive\WinampTemp"

  Write-Verbose 'Preparing Winamp staging area...'
  Copy-Item -Path "$FixturesPath\Settings" -Destination "$WinampTemp\Settings" -Recurse -Force
  if ($DebugPreference -eq 'Continue') {
    explorer $WinampTemp
  }

  $TestPlaylist = "$WinampTemp\test.m3u"
  Write-Verbose "Creating test playlist at $TestPlaylist"
  $Songlist = @($TestMP3) * $Repetitions
  Set-Content -Path $TestPlaylist -Value ($Songlist -join "`n") -Force -NoNewline
  $TestPlaylist = Resolve-Path $TestPlaylist
  $WinampTemp = Resolve-Path $WinampTemp
  Write-Debug "Staging area ready: $WinampTemp"

  return $WinampTemp
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
    [Parameter(Mandatory)][string]$TestPlaylist,
    [Parameter(Mandatory)][string]$WorkingDirectory
  )
  Write-Debug "Starting test Winamp: $WinampPath, WorkDir: $WorkingDirectory, Playlist: $TestPlaylist"

  if (!(Test-Path $WinampPath)) {
    Throw "Winamp path not found: $WinampPath"
  }

  if (!(Test-Path $TestPlaylist)) {
    Throw "Test playlist not found: $TestPlaylist"
  }

  if (!(Test-Path $WorkingDirectory)) {
    Throw "Working directory not found: $WorkingDirectory"
  }

  $process = Start-Process -FilePath $WinampPath -ArgumentList '/NOREG', $TestPlaylist -WorkingDirectory $WorkingDirectory -PassThru
  Start-Sleep -Milliseconds 500
  if ($process.HasExited) {
    Throw "Winamp failed to start: $($process.ExitCode)"
  }
  Start-SleepUntilTrue -Condition { [long]$process.MainWindowHandle -gt 0 } -Seconds 30
  Wait-WinampInit | Out-Null
  return $process
}

Function Stop-TestWinamp {
  $process = Get-Process winamp -ErrorAction SilentlyContinue
  if (!$process) {
    return
  }
  
  &($process.Path) /close
  Start-SleepUntilTrue -Seconds 30 -Condition { $process.HasExited }
  if (!$process.HasExited) {
    $process.Kill()
    $process.WaitForExit()
  }
  Start-SleepUntilTrue -Seconds 30 -Condition { $process.HasExited }
  Start-Sleep -Milliseconds 500
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
  Write-Information "$($data | Out-String)"
  Throw 'Winamp is already running and it must be closed before testing can start.'
}

$process = Get-WmiObject Win32_Process | Where-Object Commandline -Match 'powershell.*[wW]inamp.*(?<!Tests).ps1'
if ($process) {
  $data = $process | Select-Object ProcessId, CommandLine
  Write-Information "$($data | Out-String)"
  Throw 'WinampAutoRestart script is already running, please exit.'
}

####
#Endregion
####