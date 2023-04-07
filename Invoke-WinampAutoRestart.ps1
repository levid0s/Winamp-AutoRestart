<#PSScriptInfo
.VERSION      2023.04.07
.AUTHOR       Levente Rog
.COPYRIGHT    (c) 2023 Levente Rog
.LICENSEURI   https://github.com/levid0s/Winamp-AutoRestart/blob/master/LICENSE.md
.PROJECTURI   https://github.com/levid0s/Winamp-AutoRestart/
#>

<#
  .SYNOPSIS
  Script for monitoring Winamp, and restart it when idle, to get the Media Library written to disk.
  
  .DESCRIPTION
  The WinAmp Media Library database is only saved when Winamp is closed. If Winamp has been open for a long time, and the app crashes, those changes will be lost. (I usually keep Winamp open for days.)
  This script keeps monitoring Winamp in the background, using the Windows API, and if the plaback is paused/stopped for `$FlushAfterSeconds`, the app will be restarted to flush the database. Playback will be seeked back to the same position, as before the restart.

  .PARAMETER FlushAfterSeconds
  Restart Winamp after it has been idle for this number of seconds. Default is 300 seconds (5 minutes).
  Idle means plackback is either stopped or paused.

  .PARAMETER LogLevel
  The level of logging to write to the Log file. Default is 'Information'.
  Valid values are: 'Verbose', 'Debug', 'Information'

  .PARAMETER Install [CurrentUser|GROUPS\AllUsers]
  Install the script as a Windows Scheduled Task, to run at startup.
  AllUsers requires the script to be run as Administrator (although the Scheduled task will be started as limited privileges, as `BUILTIN\Users`).
  A detailed Log file is written to `%TEMP%\Start-WinampAutoFlush.ps1-%TIMESTAMP%.log`

  .PARAMETER Uninstall
  Remove the previously created Windows Scheduled Task
#>

param(
  [Parameter(Position = 0, ParameterSetName = 'Default')][ValidateSet('CurrentUser', 'GROUPS\AllUsers')]$Install = $null,
  [Parameter(Position = 1, ParameterSetName = 'Default')][int]$FlushAfterSeconds = 300,
  [Parameter(Position = 2, ParameterSetName = 'Default')][ValidateSet('Verbose', 'Debug', 'Information')][string]$LogLevel = 'Information',
  [Parameter(Position = 3, ParameterSetName = 'Uninstall')][switch]$Uninstall
)

. $PSScriptRoot/_Winamp-AutoRestartHelpers.ps1

$MyScript = $MyInvocation.MyCommand.Source
$ScriptName = Split-Path $MyScript -Leaf
$Timestamp = Get-Date -Format 'yyyMMdd-HHmmss'
$LogPath = "$env:LOCALAPPDATA\Temp\${ScriptName}-$Timestamp.log"

# End this PowerShell script if the parent process (Scheduled Task Job) has exited
$HaltScriptOnParentExit = { Start-Job -ScriptBlock {
    param($ScriptPid, $LogPath)
    $parentProcessId = (Get-WmiObject Win32_Process -Filter "processid='$ScriptPid'").ParentProcessId
    $PSParent = Get-Process -Id $parentProcessId
    while (!$PSParent.HasExited) {
      Start-Sleep -Milliseconds 500
    }
    # Stop the PowerShell script
    # Append to the end of the logfile
    Stop-Transcript
    # For some reason this never gets executed.
    'INFO: Parent process has exited. Stopping the script.' >> $LogPath
    Stop-Process $ScriptPid
  } -ArgumentList $pid, $LogPath | Out-Null
}
&$HaltScriptOnParentExit

$LogLevels = @{
  'Error'       = 1
  'Warning'     = 2
  'Information' = 3
  'Info'        = 3
  'Debug'       = 4
  'Verbose'     = 5
}
$LogLevelv = $LogLevels.$LogLevel

switch ($LogLevelv) {
  { $_ -ge 3 } { $InformationPreference = 'SilentlyContinue' } # PS 5.1 Bug: https://stackoverflow.com/questions/55191548/write-information-does-not-show-in-a-file-transcribed-by-start-transcript
  { $_ -ge 4 } { $DebugPreference = 'Continue' }
  { $_ -ge 5 } { $VerbosePreference = 'Continue' }
}

####
#Region Install
####

if ($Install -and $Uninstall) {
  Throw 
}

if ($Install) {
  $ps = @{
    FlushAfterSeconds = $FlushAfterSeconds
    LogLevel          = $LogLevel
  }
  $SchTaskGroupSett = @{}
  if ($Install -eq 'GROUPS\AllUsers') {
    $SchTaskGroupSett.GroupId = 'BUILTIN\Users'
  }
  Logger -LogLevel Information 'Installing Scheduled Task..'
  $job = Register-PowerShellScheduledTask `
    -ScriptPath $MyScript `
    -AllowRunningOnBatteries $true `
    @SchTaskGroupSett `
    -Parameters $ps `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -AtLogon
  $TaskName = ($job | Select-Object -Last 1 -ExpandProperty TaskName)
  Logger -LogLevel Information "Starting Scheduled Task: $TaskName"
  Start-ScheduledTask $TaskName
  return
}

if ($Uninstall) {
  Logger -LogLevel Information 'Uninstalling Scheduled Task..'
  Register-PowerShellScheduledTask -ScriptPath $MyScript -Uninstall | Out-Null
  return
}

####
#Endregion
####

Start-Transcript -Path $LogPath -Append
Logger -LogLevel Information -Message "Starting WinampAutoFlush. LogLevel: $LogLevel"
Logger -LogLevel Information -Message "Winamp will be restarted after $FlushAfterSeconds seconds of inactivity."

$Checkpoint = @{}
$Checkpoint.Fingerprint = 'unknown'
$PlayStoppedAt = $null

while ($true) {
  Start-Sleep -Seconds ([math]::Max(1, [int]($FlushAfterSeconds / 5)))

  if (!(Get-Process 'winamp' -ErrorAction SilentlyContinue)) {
    if ($Checkpoint.Fingerprint) {
      Logger -LogLevel Information 'Waiting for winamp to be started..'  
      $Checkpoint.Fingerprint = $null
    }
    else {
      Logger -LogLevel Verbose 'Waiting for winamp to be started..'
    }
    Continue
  }

  if (!$Checkpoint.Fingerprint -or $Checkpoint.Fingerprint -eq 'unknown') {

    # Winamp is now started, but we don't have a $status yet.
    # Wait for the API to become ready.
    $window = Wait-WinampInit
    Logger -LogLevel Information 'Winamp started..'

    # Register the current status as 'seen' so we don't restart until we have changes.
    $Checkpoint = Get-WinampStatus -Window $window
  }

  $Current = Get-WinampStatus -Window $window

  if ($Current.playStatus -eq 1) {
    Logger -LogLevel Verbose 'Winamp currently playing, nothing to do.'
    $PlayStoppedAt = $null
    Continue
  }

  $RunningForSeconds = ([TimeSpan]::Parse((Get-Date) - $Current.StartTime)).TotalSeconds
  Logger -LogLevel Verbose "STATS: Start Time: $($Current.StartTime).  Running for: $(((Get-Date) - $Current.StartTime).ToString().Substring(0,8))"
  if ($RunningForSeconds -lt [math]::Max(15, $FlushAfterSeconds)) {
    Logger -LogLevel Verbose "Winamp started just recently, we'll leave it alone. Recording current state as checkpointed."
    $Checkpoint = $Current.Clone()
    Logger -LogLevel Verbose "Checkpoint fingerprint: $($Checkpoint.Fingerprint)"
    Continue
  }
  Logger -LogLevel Verbose "FYI: Checkpoint.Fingerprint = '$($Checkpoint.Fingerprint)'; Current.Fingerprint = '$($Current.Fingerprint)'"

  if ($Checkpoint.Fingerprint -eq $Current.Fingerprint) {
    Logger -LogLevel Verbose 'Winamp already restarted, nothing to do for now.'
    Continue
  }
  else {
    Logger -LogLevel Verbose "Winamp status changed: Checkpoint.Fingerprint = '$($Checkpoint.Fingerprint)'; Current.Fingerprint = '$($Current.Fingerprint)'"
  }

  if (!$PlayStoppedAt) {
    $PlayStoppedAt = Get-Date
  }

  $StoppedForSeconds = ([TimeSpan]::Parse((Get-Date) - $PlayStoppedAt)).TotalSeconds
  Logger -LogLevel Debug "Winamp stopped for $StoppedForSeconds seconds."

  if ($StoppedForSeconds -gt $FlushAfterSeconds) {
    Logger -LogLevel Debug "Winamp stopped for $StoppedForSeconds seconds, restarting."
    $window = Restart-Winamp -Window $window
    Logger -LogLevel Information 'Winamp restarted..'
    $Checkpoint = Get-WinampStatus -Window $window
  }
}
