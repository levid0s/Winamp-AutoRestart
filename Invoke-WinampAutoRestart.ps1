<#PSScriptInfo
.VERSION      2023.03.30
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

  .PARAMETER Install [CurrentUser|AllUsers]
  Install the script as a Windows Scheduled Task, to run at startup.
  AllUsers requires the script to be run as Administrator (although the Scheduled task will be started as limited privileges, as `BUILTIN\Users`).
  A detailed Log file is written to `%TEMP%\Start-WinampAutoFlush.ps1-%TIMESTAMP%.log`

  .PARAMETER Uninstall
  Remove the previously created Windows Scheduled Task
#>

param(
  [int]$FlushAfterSeconds = 300,
  [Parameter()][ValidateSet('Verbose', 'Debug', 'Information')][string]$LogLevel = 'Information',
  [Parameter()][ValidateSet('CurrentUser', 'AllUsers')]$Install = $null,
  [switch]$Uninstall
)

. $PSScriptRoot/_Winamp-AutoRestartHelpers.ps1

$MyScript = $MyInvocation.MyCommand.Source
$ScriptName = Split-Path $MyScript -Leaf
$Timestamp = Get-Date -Format "yyyMMdd-HHmmss"
$LogPath = "$env:TEMP\${ScriptName}-$Timestamp.log"

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
    "INFO: Parent process has exited. Stopping the script." >> $LogPath
    Stop-Process $ScriptPid
  } -ArgumentList $pid, $LogPath | Out-Null
}
&$HaltScriptOnParentExit

###
#Region Register-PowerShellScheduledTask
###

function Register-PowerShellScheduledTask {
  <#
  .VERSION 20230331

  .SYNOPSIS
  Registers a PowerShell script as a **Hidden** Scheduled Task.
  At the moment the schedule frequency is hardcoded to every 15 minutes.

  .DESCRIPTION
  Currently, it's not possible create a hidden Scheduled Task that executes a PowerShell task.
  A command window will keep popping up every time the task is run.
  This function creates a wrapper vbs script that runs the PowerShell script as hidden.
  source: https://github.com/PowerShell/PowerShell/issues/3028

  .PARAMETER ScriptPath
  The path to the PowerShell script that will be executed in the task.

  .PARAMETER Parameters
  A hashtable of parameters to pass to the script.

  .PARAMETER TaskName
  The Scheduled Task will be registered under this name in the Task Scheduler.
  If not specified, the script name will be used.

  .PARAMETER AllowRunningOnBatteries
  Allows the task to run when the computer is on batteries.

  .PARAMETER Uninstall
  Unregister the Scheduled Task.

  .PARAMETER ExecutionTimeLimit
  The maximum amount of time the task is allowed to run.
  New-TimeSpan -Hours 72
  New-TimeSpan -Minutes 15
  New-TimeSpan -Seconds 30
  New-TimeSpan -Seconds 0 = Means disabled

  .PARAMETER AsAdmin
  Run the Scheduled Task as administrator.

  .PARAMETER GroupId
  The Scheduled Task will be registered under this group in the Task Scheduler.
  Eg: "BUILTIN\Administrators"

  .PARAMETER TimeInterval
  The Scheduled Task will be run every X minutes.

  .PARAMETER AtLogon
  The Scheduled Task will be run at user logon.

  .PARAMETER AtStartup
  The Scheduled Task will be run at system startup. Requires admin rights.
  #>

  param(
    [Parameter(Mandatory = $true)]$ScriptPath,
    [hashtable]$Parameters = @{},
    [string]$TaskName,
    [bool]$AllowRunningOnBatteries,
    [switch]$DisallowHardTerminate,
    [TimeSpan]$ExecutionTimeLimit,
    [int]$TimeInterval,
    [switch]$AtLogon,
    [switch]$AtStartup,
    [string]$GroupId,
    [switch]$AsAdmin,
    [switch]$Uninstall
  )

  if ([string]::IsNullOrEmpty($TaskName)) {
    $TaskName = Split-Path $ScriptPath -Leaf
  }

  ## Uninstall
  if ($Uninstall) {
    Stop-ScheduledTask -TaskName $TaskName
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    return
  }

  ## Install
  if (!(Test-Path $ScriptPath)) {
    Throw "Script ``$ScriptPath`` not found!"
  }
  $ScriptPath = Resolve-Path -LiteralPath $ScriptPath

  # Create wrapper vbs script so we can run the PowerShell script as hidden
  # https://github.com/PowerShell/PowerShell/issues/3028
  if ($GroupId) {
    $vbsPath = "$env:ALLUSERSPROFILE\PsScheduledTasks\$TaskName.vbs"
  }
  else {
    $vbsPath = "$env:LOCALAPPDATA\PsScheduledTasks\$TaskName.vbs"
  }
  $vbsDir = Split-Path $vbsPath -Parent

  if (!(Test-Path $vbsDir)) {
    New-Item -ItemType Directory -Path $vbsDir
  }

  $ps = @(); $Parameters.GetEnumerator() | ForEach-Object { $ps += "-$($_.Name) $($_.Value)" }; $ps -join " "
  $vbsScript = @"
Dim shell,command
command = "powershell.exe -nologo -File $ScriptPath $ps"
Set shell = CreateObject("WScript.Shell")
shell.Run command, 0, true
"@

  Set-Content -Path $vbsPath -Value $vbsScript -Force

  Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue -OutVariable TaskExists
  if ($TaskExists.State -eq 'Running') {
    Write-Debug "Stopping task for update: $TaskName"
    $TaskExists | Stop-ScheduledTask
  }
  $action = New-ScheduledTaskAction -Execute $vbsPath
  
  ## Schedule
  $triggers = @()
  if ($TimeInterval) {
    $t1 = New-ScheduledTaskTrigger -Daily -At 00:05
    $t2 = New-ScheduledTaskTrigger -Once -At 00:05 `
      -RepetitionInterval (New-TimeSpan -Minutes $TimeInterval) `
      -RepetitionDuration (New-TimeSpan -Hours 23 -Minutes 55)
    $t1.Repetition = $t2.Repetition
    $t1.Repetition.StopAtDurationEnd = $false
    $triggers += $t1
  }
  if ($AtLogOn) {
    $triggers += New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  }
  if ($AtStartUp) {
    $triggers += New-ScheduledTaskTrigger -AtStartup
  }
    
  ## Additional Options
  $AdditionalOptions = @{}

  if ($AsAdmin) {
    $AdditionalOptions.RunLevel = 'Highest'
  }

  if ($GroupId) {
    $STPrin = New-ScheduledTaskPrincipal -GroupId $GroupId
    $AdditionalOptions.Principal = $STPrin
  }
  
  ## Settings 
  $AdditionalSettings = @{}

  if ($AllowRunningOnBatteries -eq $true) {
    $AdditionalSettings.AllowStartIfOnBatteries = $true
    $AdditionalSettings.DontStopIfGoingOnBatteries = $true
  }
  elseif ($AllowRunningOnBatteries -eq $false) {
    $AdditionalSettings.AllowStartIfOnBatteries = $false
    $AdditionalSettings.DontStopIfGoingOnBatteries = $false
  }

  if ($DisallowHardTerminate) {
    $AdditionalSettings.DisallowHardTerminate = $true
  }

  if ($ExecutionTimeLimit) {
    $AdditionalSettings.ExecutionTimeLimit = $ExecutionTimeLimit
  }


  $STSet = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    @AdditionalSettings

  ## Decide if Register or Update
  if (!$TaskExists) {
    $cim = Register-ScheduledTask -Action $action -Trigger $triggers -TaskName $TaskName -Description "Scheduled Task for running $ScriptPath" -Settings $STSet @AdditionalOptions
  }
  else {
    $cim = Set-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $STSet @AdditionalOptions
  }
  
  return $cim
}


###
#Endregion
###

$LogLevels = @{
  "Error"       = 1
  "Warning"     = 2
  "Information" = 3
  "Info"        = 3
  "Debug"       = 4
  "Verbose"     = 5
}
$LogLevelv = $LogLevels.$LogLevel

switch ($LogLevelv) {
  { $_ -ge 3 } { $InformationPreference = 'SilentlyContinue' } # PS 5.1 Bug: https://stackoverflow.com/questions/55191548/write-information-does-not-show-in-a-file-transcribed-by-start-transcript
  { $_ -ge 4 } { $DebugPreference = 'Continue' }
  { $_ -ge 5 } { $VerbosePreference = 'Continue' }
}

if ($Install) {
  $ps = @{
    FlushAfterSeconds = $FlushAfterSeconds
    LogLevel          = $LogLevel
  }
  $SchTaskGroupSett = @{}
  if ($Install -eq 'AllUsers') {
    $SchTaskGroupSett.GroupId = 'BUILTIN\Users'
  }

  $job = Register-PowerShellScheduledTask `
    -ScriptPath $MyScript `
    -AllowRunningOnBatteries $true `
    @SchTaskGroupSett `
    -Parameters $ps `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -AtLogon
  Start-ScheduledTask $job.TaskName
  return
}

if ($Uninstall) {
  Register-PowerShellScheduledTask -ScriptPath $MyScript -Uninstall
  return
}

Start-Transcript -Path $LogPath -append
Logger -LogLevel Information -Message "Starting WinampAutoFlush. LogLevel: $LogLevel"
Logger -LogLevel Information -Message "Winamp will be restarted after $FlushAfterSeconds seconds of inactivity."

function Restart-Winamp {
  # https://forums.winamp.com/forum/developer-center/winamp-development/156726-winamp-application-programming-interface?postid=1953663
  param(
    [Parameter(Mandatory = $true)]$Window
  )

  $WM_COMMAND = 0x0111
  $WM_USER = 0x0400

  $playStatus = $window.SendMessage($WM_USER, 0, 104) # 0: stopped, 1: playing, 3: paused
  $SeekPosMS = $window.SendMessage($WM_USER, 0, 105)
  Logger -LogLevel Debug "Winamp: hWnd: $($window.hWnd), PlayStatus: $playStatus, SeekPos: $SeekPosMS"
  Logger -LogLevel Information "RESTARTING Winamp.."
  $process = Get-Process 'winamp'
  $window.SendMessage($WM_USER, 0, 135) | Out-Null
  While (!$process.HasExited) {
    start-sleep 1
  }
  $process = Get-Process 'winamp'
  Write-Host "old HWND: $($window.Hwnd)"
  $window = Wait-WinampInit
  Write-Host "new HWND: $($window.Hwnd)"

  Logger -LogLevel Information "Winamp restarted: hWnd: $($window.hWnd), PlayStatus: $playStatus, SeekPos: $SeekPosMS"

  switch ($playStatus) {
    1 {
      Logger -LogLevel Information "Pressing: Play"
      $window.SendMessage($WM_COMMAND, 40045, 0) | Out-Null
      Logger -LogLevel Information "Seeking to previous pos: $seekPosMS ms"
      $window.SendMessage($WM_USER, $SeekPosMS, 106) | Out-Null
    }
    3 {
      Logger -LogLevel Information "Pressing: Play"
      $window.SendMessage($WM_COMMAND, 40045, 0) | Out-Null
      Logger -LogLevel Information "Seeking to previous pos: $seekPosMS ms"
      $window.SendMessage($WM_USER, $SeekPosMS, 106) | Out-Null
      Logger -LogLevel Information "Pressing: Pause"
      $window.SendMessage($WM_COMMAND, 40046, 0) | Out-Null
    }
  }

  return $window
}


$RestartedCheck = $null
$PlayStoppedAt = $null
$PlayStoppedCheck = $null

Logger -LogLevel Debug "INIT: Winamp will be restarted after $FlushAfterSeconds seconds of inactivity."

$status = 'unknown'

while ($true) {
  Start-Sleep -Seconds ([int]($FlushAfterSeconds / 5))

  if (!(Get-Process "winamp" -ErrorAction SilentlyContinue)) {
    if ($status) {
      Logger -LogLevel Information "Winamp not started."  
      $status = $null
    }
    else {
      Logger -LogLevel Verbose "Waiting for winamp to be started.."
    }
    Continue
  }

  if (!$status -or $status -eq 'unknown') {
    # Winamp process now exists, but we don't have a $status yet.
    # Waiting for Winamp to start up..
    $window = Wait-WinampInit
  }

  $status = Get-WinampStatus -Window $window

  if ($status.playStatus -eq 1) {
    Logger -LogLevel Verbose "Winamp currently playing, nothing to do."
    $PlayStoppedAt = $null
    Continue
  }

  $RunningForSeconds = ([TimeSpan]::Parse((Get-Date) - $status.StartTime)).TotalSeconds
  Logger -LogLevel Verbose "STATS: Start Time: $($status.StartTime).  Running for: $([int]${RunningForSeconds})s"

  if ($RestartedCheck -eq $status.statusCheck) {
    Logger -LogLevel Verbose "Winamp already restarted, nothing to do for now."
    Continue
  }
  else {
    Logger -LogLevel Verbose "RestartedCheck status changed:"
    Logger -LogLevel Verbose "RestartedCheck = $RestartedCheck; StatusCheck = $($status.statusCheck)"
  }

  if ($RunningForSeconds -lt $FlushAfterSeconds) {
    Logger -LogLevel Debug "Winamp started just recently ($RunningForSeconds seconds ago. Flush after: $FlushAfterSeconds). Recording state as RESTARTED. Nothing else to do."
    $RestartedCheck = $status.statusCheck
    Logger -LogLevel Verbose "Status check string: $($status.statusCheck)"
    Continue
  }

  if (!$PlayStoppedAt) {
    Logger -LogLevel Information "Winamp is now stopped or paused; recording state st STOPPED."
    $PlayStoppedAt = Get-Date
    $PlayStoppedCheck = $status.statusCheck
    Continue
  }

  if ($PlayStoppedCheck -ne $status.statusCheck) {
    Logger -LogLevel Information "Winamp's state has changed since the last check (even if it's currently stopped or paused). Resetting counter." 
    $PlayStoppedAt = Get-Date
    $PlayStoppedCheck = $status.statusCheck
    Continue
  }

  $StoppedForSeconds = ([TimeSpan]::Parse((Get-Date) - $PlayStoppedAt)).TotalSeconds
  Logger -LogLevel Debug "Winamp stopped for $StoppedForSeconds seconds."

  if ($StoppedForSeconds -gt $FlushAfterSeconds) {
    Logger -LogLevel Debug "Winamp stopped for $FlushAfterSeconds seconds, restarting."
    $window = Restart-Winamp -Window $window
    $status = Get-WinampStatus -Window $window
    $RestartedCheck = $status.statusCheck
  }
}
