. N:\src\useful\ps-winhelpers\_PS-WinHelpers.ps1
. ../_Winamp-AutoRestartHelpers.ps1

$DebugPreference = "Continue"
$InformationPreference = "Continue"
$VerbosePreference = "Continue"

$PsShell = Get-Process -Id $PID | Select-Object -ExpandProperty Path
$WinampPath = "N:\Tools\Winamp-58portable\winamp.exe"
$TestFile = './Fixtures/5-minutes-of-silence.mp3' | Resolve-Path
$TestPlaylist = './Fixtures/test.m3u'
$ScriptPath = '../Invoke-WinampAutoRestart.ps1' | Resolve-Path
$MaxTestFiles = 30

####
#Region Create Test Playlist
####

$TestFiles = @($TestFile) * $MaxTestFiles
Set-Content -Path $TestPlaylist -Value ($TestFiles -join "`n") -Force -NoNewline
$TestPlaylist = $TestPlaylist | Resolve-Path

####
#Endregion
####

####
#Region Start-TestWinamp
####

Function Start-TestWinamp {
  $process = Start-Process -FilePath $WinampPath -ArgumentList '/NOREG', $TestPlaylist -WorkingDirectory "${PSScriptRoot}\Fixtures" -PassThru
  return $process
}

Function Stop-TestWinamp {
  &$WinampPath /close
  Start-SleepOrCondition -Seconds 30 -Condition { $testWinamp.HasExited }
  if (!$testWinamp.HasExited) {
    $testWinamp.Kill()
    $testWinamp.WaitForExit()
  }
}

####
#Endregion
####

####
#Region Error Checking
####

$process = Get-Process "winamp" -ErrorAction SilentlyContinue
if ($process) {
  $data = $process | Select-Object Id, Path
  Write-Information "$($data | Out-String)"
  Throw "Winamp is already running and it must be closed before testing can start."
}

$process = Get-WmiObject Win32_Process | Where-Object Commandline -match "powershell.*[wW]inamp.*(?<!Tests).ps1"
if ($process) {
  $data = $process | Select-Object ProcessId, CommandLine
  Write-Information "$($data | Out-String)"
  Throw "WinampAutoRestart script is already running, please exit."
}

####
#Endregion
####