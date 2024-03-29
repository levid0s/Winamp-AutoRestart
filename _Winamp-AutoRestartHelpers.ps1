$WM_COMMAND = 0x0111
$WM_USER = 0x0400

function Logger {
    param(
        [Parameter()][ValidateSet('Error', 'Warning', 'Information', 'Debug', 'Verbose')][string]$LogLevel,
        [Parameter(Mandatory)][string]$Message
    )
    $Timestamp = Get-Date -Format 'yyyMMdd-HHmmss'

    switch ($LogLevel) {
        'Information' {
            # Workaround for https://stackoverflow.com/questions/55191548/write-information-does-not-show-in-a-file-transcribed-by-start-transcript
            Write-Information "${Timestamp}: $Message"
            [System.Console]::WriteLine("INFO: ${Timestamp}: $Message")
        }
        'Debug' {
            Write-Debug "${Timestamp}: $Message"
        }
        'Verbose' {
            Write-Verbose "${Timestamp}: $Message"
        }
        'Error' {
            Write-Error "${Timestamp}: $Message"
        }
        'Warning' {
            Write-Warning "${Timestamp}: $Message"
        }
    }
}

Function Get-Timestamp {
    <#
  .VERSION 20230407
  #>
    return Get-Date -Format 'yyyyMMdd-HHmmss'
}

function Wait-WinampInit {
    <#
  .VERSION 2023.03.30

  .SYNOPSIS
  Wait until the Winamp API is ready to accept commands
  #>
    param(
        $window
    )

    $StartTime = Get-Date

    $process = Get-Process 'winamp' -ErrorAction SilentlyContinue
    if ($process.Count -ne 1) {
        Logger -LogLevel Debug 'Waiting for the Winamp process to start..'
        [System.Console]::Write('Waiting for Winamp to start.')
        while ($process.Count -ne 1) {
            try {
                $process = Get-Process 'winamp' -ErrorAction SilentlyContinue
            }
            catch {
            }
            Start-Sleep -Seconds 1
            [System.Console]::Write('.')
        }
        [System.Console]::WriteLine(': ok')
    }

    if ($window.ClassName -ne 'Winamp v1.x') {
        Logger -LogLevel Debug 'Waiting for the Winamp 1.x class to initialize..'
        [System.Console]::Write('Waiting for the Winamp 1.x class to load.')
        while ($window.ClassName -ne 'Winamp v1.x') {
            try {
                $window = [System.Windows.Win32Window]::FromProcessName('winamp')
            }
            catch {
            }
            if ($process.HasExited) {
                [System.Console]::Write(': failed!')
                Throw 'Winamp exited unexpectedly.'
            }
            Start-Sleep -Seconds 1
            [System.Console]::Write('.')
        }
        [System.Console]::WriteLine(': ok')
    }
  
    [System.Console]::Write('Waiting for the API to be ready.')

    do {
        if ($process.HasExited) {
            [System.Console]::Write(': failed!')
            Throw 'Winamp exited unexpectedly.'
        }
        $SeekPosMS = $window.SendMessage($WM_USER, 0, 105)
        [System.Console]::Write('.')
        Start-Sleep -Seconds 1
    } while (!([long]$SeekPosMS -gt 0))
    $Duration = (Get-Date) - $StartTime
    [System.Console]::WriteLine(": ok (SeekPosMS:$SeekPosMS)")
    Logger -LogLevel Debug "Winamp API ready. SeekPosMS: $SeekPosMS. Duration: $Duration"
    return $window | Where-Object ClassName -EQ 'Winamp v1.x' 
}

function Get-WinampStatus {
    param(
        [Parameter(Mandatory = $true)]$Window
    )
    $playStatus = Get-WinampPlayStatus -Window $Window
    $SeekPosMS = Get-WinampSeekPos -Window $Window
    $PlaylistIndex = Get-WinampPlaylistIndex -Window $Window

    $fingerprint = "hWnd=$($window.hWnd);status=$playStatus;ix=$PlaylistIndex;seek=$SeekPosMS"
    return @{
        hWnd        = $window.hWnd
        PlayStatus  = $playStatus
        SeekPosMS   = $SeekPosMS
        Fingerprint = $fingerprint
        StartTime   = $window.Process.StartTime
        Timestamp   = Get-Date
        Tainted     = $false
    }
}

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
    Logger -LogLevel Information 'RESTARTING Winamp..'
    $process = Get-Process 'winamp'
    $window.SendMessage($WM_USER, 0, 135) | Out-Null
    While (!$process.HasExited) {
        Start-Sleep 1
    }
    $process = Get-Process 'winamp'
    $window = Wait-WinampInit

    Logger -LogLevel Information "Winamp restarted: hWnd: $($window.hWnd), PlayStatus: $playStatus, SeekPos: $SeekPosMS"

    switch ($playStatus) {
        1 {
            Invoke-WinampPlay -Window $window | Out-Null
      
            Logger -LogLevel Debug "Seeking to previous pos: $seekPosMS ms"
            Set-WinampSeekPos -Window $window -SeekPosMS $SeekPosMS | Out-Null

            $window.SendMessage($WM_USER, $SeekPosMS, 106) | Out-Null
        }
        3 {
            Invoke-WinampPlay -Window $window | Out-Null
            Logger -LogLevel Debug "Seeking to previous pos: $seekPosMS ms"
            Set-WinampSeekPos -Window $window -SeekPosMS $SeekPosMS | Out-Null
            Invoke-WinampPause -Window $window | Out-Null
        }
    }

    return $window
}


#######

function Get-WinampSeekPos {
    param(
        [Parameter(Mandatory = $true)]$Window
    )
    # [long]$SeekPosMS = ExponentialBackoff -Rounds 3 -InitialDelayMs 100 -Do {
    #   $window.SendMessage($WM_USER, 0, 105)
    # } -Check {
    #   $result -gt 0 ## Not implemented yet in ExponentialBackoff
    # }
    # [long]$SeekPosMS = $window.SendMessage($WM_USER, 0, 105)
    # while ($SeekPosMS -eq 0) {
    #   Start-Sleep 1
    #   $SeekPosMS = $window.SendMessage($WM_USER, 0, 105)
    # }

    $SeekPosMS = ExponentialBackoff `
        -Do { $window.SendMessage($WM_USER, 0, 105) } `
        -Check { [long]$DoResult -gt 0 }

    return [long]$SeekPosMS.DoResult
}

function Get-WinampPlayStatus {
    <#
  0: stopped, 1: playing, 3: paused
  #>
    param(
        [Parameter(Mandatory = $true)]$Window
    )
    $playStatus = $window.SendMessage($WM_USER, 0, 104)
    return $playStatus
}

function Invoke-WinampPause {
    param(
        [Parameter(Mandatory = $true)]$Window
    )
    Logger -LogLevel Information 'Pressing: PLAY'
  
    $result = ExponentialBackoff `
        -Do { $window.SendMessage($WM_COMMAND, 40046, 0) } `
        -Check { (Get-WinampPlayStatus -Window $Window) -eq 3 }

    return $result.CheckResult
}

function Invoke-WinampPlay {
    param(
        [Parameter(Mandatory = $true)]$Window
    )
    Logger -LogLevel Information 'Pressing: PAUSE'
    $result = ExponentialBackoff `
        -Do { $window.SendMessage($WM_COMMAND, 40045, 0) } `
        -Check { (Get-WinampPlayStatus -Window $Window) -eq 1 }
  
    return $result.CheckResult
}

function Invoke-WinampRestart {
    param(
        [Parameter(Mandatory = $true)]$Window
    )
    Logger -LogLevel Information 'RESTARTING Winamp..'
    $result = $window.SendMessage($WM_USER, 0, 135)
    return $result
}

function Set-WinampPlaylistIndex {
    param(
        [Parameter(Mandatory = $true)]$Window,
        [Parameter(Mandatory = $true)][int]$PlaylistIndex # Starts at 1
    )

    Logger -LogLevel Information "Seeking to Playlist index: $($PlaylistIndex)"
    $result = ExponentialBackoff `
        -Do { $window.SendMessage($WM_USER, $PlaylistIndex - 1, 121) } `
        -Check { (Get-WinampPlaylistIndex -Window $Window) -eq $PlaylistIndex }

    return $result.DoResult + 1
}

function Get-WinampPlaylistIndex {
    param(
        [Parameter(Mandatory = $true)]$Window
    )
    $result = $window.SendMessage($WM_USER, 0, 125)
    return $result + 1
}

function Set-WinampSeekPos {
    param(
        [Parameter(Mandatory = $true)]$Window,
        [Parameter(Mandatory = $true)][long]$SeekPosMS
    )
    Logger -LogLevel Information "Seeking track to time(ms): $($SeekPosMS)"
    $result = ExponentialBackoff `
        -Do { $window.SendMessage($WM_USER, $SeekPosMS, 106) } `
        -Check { [long]$test = Get-WinampSeekPos -Window $Window; ([Math]::Abs($SeekPosMS - $test) -lt 2000) }

    return $result.CheckResult
}

function Get-WinampSongTitle {
    <#
    .VERSION 2023.11.25
    
    .SYNOPSIS
    Returns the title of the currently selected song in Winamp.

    #>

    [CmdletBinding()]
    param(
    )

    $DebugPreference = 'SilentlyContinue'
    if ($PSBoundParameters.ContainsKey('Debug')) {
        $DebugPreference = 'Continue'
    }

    $VerbosePreference = 'SilentlyContinue'
    if ($PSBoundParameters.ContainsKey('Verbose')) {
        $VerbosePreference = 'Continue'
    }

    $wpid = Get-Process winamp -ErrorAction SilentlyContinue
    if (!$wpid) {
        Write-Debug 'Winamp not running.'
        return $null
    }
    if ($wpid.Count -gt 1) {
        if ($ErrorActionPreference -eq 'SilentlyContinue') {
            return $null
        }
        Throw "Multiple Winamp processes found; PIDs: $($wpid | Select-Object -ExpandProperty Id)"
    }

    $wTitles = @()
    [WinAPI]::GetProcessWindows($wpid.Id, [ref]$wTitles) | Out-Null
    $Search = $wTitles | Select-String '- Winamp' | Select-Object -Last 1
    if (!$Search) {
        if ($ErrorActionPreference -eq 'SilentlyContinue') {
            return $null
        }
        Throw 'Winamp song info not found in window titles.'
    }

    $Title = $Search.ToString()
    $Title = $Title -replace '★', ''
    $Title = $Title -replace '\s*\[(?:Stopped|Paused)\]$'
    $Title = $Title -replace '^\d+\.\s*', ''
    $Title = $Title -replace '\s*\-\s*Winamp$', ''
    return $Title
}

function Get-WinampSongRating {
    <#
    .VERSION 2023.11.18
    
    .SYNOPSIS
    Gets the rating of the currently playing song in Winamp.

    .DESCRIPTION
    The function counts the number of stars in the title of the Winamp window.
    #>
    
    [CmdletBinding()]
    param(
    )

    $DebugPreference = 'SilentlyContinue'
    if ($PSBoundParameters.ContainsKey('Debug')) {
        $DebugPreference = 'Continue'
    }

    $VerbosePreference = 'SilentlyContinue'
    if ($PSBoundParameters.ContainsKey('Verbose')) {
        $VerbosePreference = 'Continue'
    }

    $wpid = Get-Process winamp -ErrorAction SilentlyContinue
    if (!$wpid) {
        Write-Debug 'Winamp not running.'
        return $null
    }
    if ($wpid.Count -gt 1) {
        Throw "Multiple Winamp processes found; PIDs: $($wpid | Select-Object -ExpandProperty Id)"
    }
    
    $rating = $null
    $wTitles = @()
    [WinAPI]::GetProcessWindows($wpid.Id, [ref]$wTitles) | Out-Null
  
    # There are two titles that contain the rating, but one is not instantly updated when the rating changes.
    # The safest way to get the rating is (Get-Process winamp).MainWindowTitle but that's not available when the "Now playing notifier" pops up.
    $search = $wTitles | Select-String "($([char]0x2605)+)?\s*\-\s*Winamp" | Select-Object -Last 1
    if (!$search) {
        Write-Debug 'Winamp song info not found in window titles.'
        return $null
    }
    Write-Debug "Search result: $($search.ToString())"
    Write-Verbose "Search groups: $($search.Matches.Groups | Out-String)"
    $rating = $search.Matches.Groups[1].Value.Length
    return $rating
}
  
Function ExponentialBackoff {
    <#
  .VERSION 20230408
  #>
    param(
        [int]$Rounds = 5,
        [int]$InitialDelayMs = 100,
        [scriptblock]$Do = {},
        [scriptblock]$Check = {}
    )

    $CheckResult = $null

    for ($round = 1; $round -le $rounds; $round++) {
        if ($round -gt 1) {
            Write-Verbose "Check condition not met, retrying with exponential backoff, round $round. Sleeping for $InitialDelayMs ms.."
            Start-Sleep -Milliseconds $InitialDelayMs  
            $InitialDelayMs *= 2
        }
        try {
            $DoResult = & $Do
            $DoSuccess = $true
        }
        catch {
            $DoSuccess = $false
        }

        # If a Check block was provided, success depends if the Check block returns $true.
        if ($Check.ToString()) {
            $CheckResult = & $Check
            if (!$CheckResult) {
                Continue
            }
        }
        else {
            # If no Check block was provided, success depends if the Do block doesn't throw an error.
            if (!$DoSuccess) {
                Continue
            }
        }

        Write-Verbose 'Check condition met, exiting loop.'
        return @{DoResult = $DoResult; CheckResult = $CheckResult }
    }
    Throw "Check condition not met after $Rounds rounds."
}

#######

###
#Region Register-PowerShellScheduledTask
###

function Register-PowerShellScheduledTask {
    <#
  .VERSION 20230407

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
        [Parameter(Mandatory = $true, Position = 0)]$ScriptPath,
        [hashtable]$Parameters = @{},
        [string]$TaskName,
        [int]$TimeInterval,
        [switch]$AtLogon,
        [switch]$AtStartup,
        [bool]$AllowRunningOnBatteries,
        [switch]$DisallowHardTerminate,
        [TimeSpan]$ExecutionTimeLimit,
        [string]$GroupId,
        [switch]$AsAdmin,
        [switch]$Uninstall
    )

    if (!($TimeInterval -or $AtLogon -or $AtStartup -or $Uninstall)) {
        Throw 'At least one of the following parameters must be defined: -TimeInterval, -AtLogon, -AtStartup, (or -Uninstall)'
    }

    if ([string]::IsNullOrEmpty($TaskName)) {
        $TaskName = Split-Path $ScriptPath -Leaf
    }

    ## Uninstall
    if ($Uninstall) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        # Return $true if no tasks found, otherwise $false
        return !(Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
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

    $ps = @(); $Parameters.GetEnumerator() | ForEach-Object { $ps += "-$($_.Name) $($_.Value)" }; $ps -join ' '
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

    # Sometimes $cim returns more than 1 object, looks like a PowerShell bug.
    # In those cases, get the last element of the list.
    return $cim
}

###
#Endregion
###

###
#Region GetWindowTiles
###

Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public class WinAPI
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public static bool GetProcessWindows(int processId, out string[] windowTitles)
    {
        var list = new System.Collections.Generic.List<string>();
        EnumWindows((hWnd, lParam) =>
        {
            int pid = 0;
            if (GetWindowThreadProcessId(hWnd, out pid) != 0 && pid == processId)
            {
                var titleBuilder = new StringBuilder(256);
                GetWindowText(hWnd, titleBuilder, titleBuilder.Capacity);
                list.Add(titleBuilder.ToString());
            }
            return true;
        }, IntPtr.Zero);
        windowTitles = list.ToArray();
        return true;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out int lpdwProcessId);
}
'@



###
#Region Control-WinApps.ps1
###

#   Copyright (c) 2014 Serguei Kouzmine
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

<#
.SYNOPSIS
Low Level Win32 API calls to control a windows app
.EXAMPLE
Get Winamp Play/Stop status:
$window = [System.Windows.Win32Window]::FromProcessName("winamp")
$window.SendMessage(0x0400,0,104)
# ref: https://forums.winamp.com/forum/developer-center/winamp-development/156726-winamp-application-programming-interface?postid=1953663
.LINK
source: https://github.com/sergueik/powershell_selenium/blob/master/powershell/button_selenium.ps1
ref: http://www.codeproject.com/Articles/790966/Hosting-And-Changing-Controls-In-Other-Application
#>
Add-Type -TypeDefinition @'
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.ComponentModel;
using System.Reflection;
using System.Windows.Forms;
using System.Collections.Generic;
using System.Collections;
using System.Drawing.Imaging;
namespace System.Windows
{
    class Win32WindowEvents
    {
        delegate void WinEventDelegate(IntPtr hWinEventHook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);
        [DllImport("user32.dll")]
        static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmodWinEventProc, WinEventDelegate lpfnWinEventProc, uint idProcess, uint idThread, uint dwFlags);
        [DllImport("user32.dll")]
        static extern bool UnhookWinEvent(IntPtr hWinEventHook);
        static IntPtr hhook;
        // Need to ensure delegate is not collected while we're using it,
        // storing it in a class field is simplest way to do this.
        static WinEventDelegate procDelegate = new WinEventDelegate(WinEventProc);
        public static void StartListening()
        {
            hhook = SetWinEventHook((uint)EventTypes.EVENT_MIN, (uint)EventTypes.EVENT_MAX, IntPtr.Zero,
                    procDelegate, 0, 0, (uint)(WinHookParameter.OUTOFCONTEXT | WinHookParameter.SKIPOWNPROCESS));
        }
        static void WinEventProc(IntPtr hWinEventHook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime)
        {
            Win32Window Window = new Win32Window(hwnd);
            //if window is found fire event
            if (predicate != null && predicate.Invoke(Window) == true)
            {
                WindowFound(Window.Process, Window, (EventTypes)eventType);
                predicate = null;
                StopListening();
            }
            if (GlobalWindowEvent != null)
            {
                GlobalWindowEvent(Window.Process, Window, (EventTypes)eventType);
            }
        }
        static Func<Win32Window, bool> predicate;
        public static void WaitForWindowWhere(Func<Win32Window, bool> Predicate)
        {
            predicate = Predicate;
            StartListening();
        }
        public static void StopListening()
        {
            UnhookWinEvent(hhook);
        }
        public delegate void WinEvent(Process Process, Win32Window Window, EventTypes type);
        public static event WinEvent WindowFound = delegate { };
        public static event WinEvent GlobalWindowEvent;
        [Flags]
        internal enum WinHookParameter : uint
        {
            INCONTEXT = 4,
            OUTOFCONTEXT = 0,
            SKIPOWNPROCESS = 2,
            SKIPOWNTHREAD = 1
        }
        public enum EventTypes : uint
        {
            WINEVENT_OUTOFCONTEXT = 0x0000, // Events are ASYNC
            WINEVENT_SKIPOWNTHREAD = 0x0001, // Don't call back for events on installer's thread
            WINEVENT_SKIPOWNPROCESS = 0x0002, // Don't call back for events on installer's process
            WINEVENT_INCONTEXT = 0x0004, // Events are SYNC, this causes your dll to be injected into every process
            EVENT_MIN = 0x00000001,
            EVENT_MAX = 0x7FFFFFFF,
            EVENT_SYSTEM_SOUND = 0x0001,
            EVENT_SYSTEM_ALERT = 0x0002,
            EVENT_SYSTEM_FOREGROUND = 0x0003,
            EVENT_SYSTEM_MENUSTART = 0x0004,
            EVENT_SYSTEM_MENUEND = 0x0005,
            EVENT_SYSTEM_MENUPOPUPSTART = 0x0006,
            EVENT_SYSTEM_MENUPOPUPEND = 0x0007,
            EVENT_SYSTEM_CAPTURESTART = 0x0008,
            EVENT_SYSTEM_CAPTUREEND = 0x0009,
            EVENT_SYSTEM_MOVESIZESTART = 0x000A,
            EVENT_SYSTEM_MOVESIZEEND = 0x000B,
            EVENT_SYSTEM_CONTEXTHELPSTART = 0x000C,
            EVENT_SYSTEM_CONTEXTHELPEND = 0x000D,
            EVENT_SYSTEM_DRAGDROPSTART = 0x000E,
            EVENT_SYSTEM_DRAGDROPEND = 0x000F,
            EVENT_SYSTEM_DIALOGSTART = 0x0010,
            EVENT_SYSTEM_DIALOGEND = 0x0011,
            EVENT_SYSTEM_SCROLLINGSTART = 0x0012,
            EVENT_SYSTEM_SCROLLINGEND = 0x0013,
            EVENT_SYSTEM_SWITCHSTART = 0x0014,
            EVENT_SYSTEM_SWITCHEND = 0x0015,
            EVENT_SYSTEM_MINIMIZESTART = 0x0016,
            EVENT_SYSTEM_MINIMIZEEND = 0x0017,
            EVENT_SYSTEM_DESKTOPSWITCH = 0x0020,
            EVENT_SYSTEM_END = 0x00FF,
            EVENT_OEM_DEFINED_START = 0x0101,
            EVENT_OEM_DEFINED_END = 0x01FF,
            EVENT_UIA_EVENTID_START = 0x4E00,
            EVENT_UIA_EVENTID_END = 0x4EFF,
            EVENT_UIA_PROPID_START = 0x7500,
            EVENT_UIA_PROPID_END = 0x75FF,
            EVENT_CONSOLE_CARET = 0x4001,
            EVENT_CONSOLE_UPDATE_REGION = 0x4002,
            EVENT_CONSOLE_UPDATE_SIMPLE = 0x4003,
            EVENT_CONSOLE_UPDATE_SCROLL = 0x4004,
            EVENT_CONSOLE_LAYOUT = 0x4005,
            EVENT_CONSOLE_START_APPLICATION = 0x4006,
            EVENT_CONSOLE_END_APPLICATION = 0x4007,
            EVENT_CONSOLE_END = 0x40FF,
            EVENT_OBJECT_CREATE = 0x8000, // hwnd ID idChild is created item
            EVENT_OBJECT_DESTROY = 0x8001, // hwnd ID idChild is destroyed item
            EVENT_OBJECT_SHOW = 0x8002, // hwnd ID idChild is shown item
            EVENT_OBJECT_HIDE = 0x8003, // hwnd ID idChild is hidden item
            EVENT_OBJECT_REORDER = 0x8004, // hwnd ID idChild is parent of zordering children
            EVENT_OBJECT_FOCUS = 0x8005, // hwnd ID idChild is focused item
            EVENT_OBJECT_SELECTION = 0x8006, // hwnd ID idChild is selected item (if only one), or idChild is OBJID_WINDOW if complex
            EVENT_OBJECT_SELECTIONADD = 0x8007, // hwnd ID idChild is item added
            EVENT_OBJECT_SELECTIONREMOVE = 0x8008, // hwnd ID idChild is item removed
            EVENT_OBJECT_SELECTIONWITHIN = 0x8009, // hwnd ID idChild is parent of changed selected items
            EVENT_OBJECT_STATECHANGE = 0x800A, // hwnd ID idChild is item w/ state change
            EVENT_OBJECT_LOCATIONCHANGE = 0x800B, // hwnd ID idChild is moved/sized item
            EVENT_OBJECT_NAMECHANGE = 0x800C, // hwnd ID idChild is item w/ name change
            EVENT_OBJECT_DESCRIPTIONCHANGE = 0x800D, // hwnd ID idChild is item w/ desc change
            EVENT_OBJECT_VALUECHANGE = 0x800E, // hwnd ID idChild is item w/ value change
            EVENT_OBJECT_PARENTCHANGE = 0x800F, // hwnd ID idChild is item w/ new parent
            EVENT_OBJECT_HELPCHANGE = 0x8010, // hwnd ID idChild is item w/ help change
            EVENT_OBJECT_DEFACTIONCHANGE = 0x8011, // hwnd ID idChild is item w/ def action change
            EVENT_OBJECT_ACCELERATORCHANGE = 0x8012, // hwnd ID idChild is item w/ keybd accel change
            EVENT_OBJECT_INVOKED = 0x8013, // hwnd ID idChild is item invoked
            EVENT_OBJECT_TEXTSELECTIONCHANGED = 0x8014, // hwnd ID idChild is item w? test selection change
            EVENT_OBJECT_CONTENTSCROLLED = 0x8015,
            EVENT_SYSTEM_ARRANGMENTPREVIEW = 0x8016,
            EVENT_OBJECT_END = 0x80FF,
            EVENT_AIA_START = 0xA000,
            EVENT_AIA_END = 0xAFFF,
        }
    }
    public static class WinAPI
    {
        #region Pinvoke
        [DllImport("user32.dll", SetLastError = true)]
        static extern System.UInt16 RegisterClassW([System.Runtime.InteropServices.In] ref WNDCLASS lpWndClass);
        [Flags]
        public enum WindowStyles : uint
        {
            WS_OVERLAPPED = 0x00000000,
            WS_POPUP = 0x80000000,
            WS_CHILD = 0x40000000,
            WS_MINIMIZE = 0x20000000,
            WS_VISIBLE = 0x10000000,
            WS_DISABLED = 0x08000000,
            WS_CLIPSIBLINGS = 0x04000000,
            WS_CLIPCHILDREN = 0x02000000,
            WS_MAXIMIZE = 0x01000000,
            WS_BORDER = 0x00800000,
            WS_DLGFRAME = 0x00400000,
            WS_VSCROLL = 0x00200000,
            WS_HSCROLL = 0x00100000,
            WS_SYSMENU = 0x00080000,
            WS_THICKFRAME = 0x00040000,
            WS_GROUP = 0x00020000,
            WS_TABSTOP = 0x00010000,
            WS_MINIMIZEBOX = 0x00020000,
            WS_MAXIMIZEBOX = 0x00010000,
            WS_CAPTION = WS_BORDER | WS_DLGFRAME,
            WS_TILED = WS_OVERLAPPED,
            WS_ICONIC = WS_MINIMIZE,
            WS_SIZEBOX = WS_THICKFRAME,
            WS_TILEDWINDOW = WS_OVERLAPPEDWINDOW,
            WS_OVERLAPPEDWINDOW = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX,
            WS_POPUPWINDOW = WS_POPUP | WS_BORDER | WS_SYSMENU,
            WS_CHILDWINDOW = WS_CHILD,
            BS_RADIOBUTTON = 0x00000004,
            BS_CHECKBOX = 0x00000002,
            ES_MULTILINE =0x0004,
            ES_AUTOVSCROLL = 0x0040,
            ES_AUTOHSCROLL = 0x0080,
            ES_WANTRETURN = 0x1000,
            ES_LEFT =0x0000,
            LBS_NOTIFY=0x0001,
            LBS_SORT=0x0002,
            LBS_STANDARD= LBS_NOTIFY | LBS_SORT | WS_VSCROLL | WS_BORDER,
            SBS_HORZ=0x0000,
            SBS_VERT=0x0001
            /*
            #define SBS_HORZ                    0x0000L
            #define SBS_VERT                    0x0001L
            #define SBS_TOPALIGN                0x0002L
            #define SBS_LEFTALIGN               0x0002L
            #define SBS_BOTTOMALIGN             0x0004L
            #define SBS_RIGHTALIGN              0x0004L
            #define SBS_SIZEBOXTOPLEFTALIGN     0x0002L
            #define SBS_SIZEBOXBOTTOMRIGHTALIGN 0x0004L
            #define SBS_SIZEBOX                 0x0008L
             * /
           /* 
            #define LBS_NOTIFY            0x0001L
            #define LBS_SORT              0x0002L
            #define LBS_NOREDRAW          0x0004L
            #define LBS_MULTIPLESEL       0x0008L
            #define LBS_OWNERDRAWFIXED    0x0010L
            #define LBS_OWNERDRAWVARIABLE 0x0020L
            #define LBS_HASSTRINGS        0x0040L
            #define LBS_USETABSTOPS       0x0080L
            #define LBS_NOINTEGRALHEIGHT  0x0100L
            #define LBS_MULTICOLUMN       0x0200L
            #define LBS_WANTKEYBOARDINPUT 0x0400L
            #define LBS_EXTENDEDSEL       0x0800L
            #define LBS_DISABLENOSCROLL   0x1000L
            #define LBS_NODATA            0x2000L
            */
            /*
            #define ES_LEFT             0x0000L
            #define ES_CENTER           0x0001L
            #define ES_RIGHT            0x0002L
            #define ES_MULTILINE        0x0004L
            #define ES_UPPERCASE        0x0008L
            #define ES_LOWERCASE        0x0010L
            #define ES_PASSWORD         0x0020L
            #define ES_AUTOVSCROLL      0x0040L
            #define ES_AUTOHSCROLL      0x0080L
            #define ES_NOHIDESEL        0x0100L
            #define ES_OEMCONVERT       0x0400L
            #define ES_READONLY         0x0800L
            #define ES_WANTRETURN       0x1000L
             */
            /*
             #define BS_PUSHBUTTON       0x00000000L
             #define BS_DEFPUSHBUTTON    0x00000001L
             #define BS_CHECKBOX         0x00000002L
             #define BS_AUTOCHECKBOX     0x00000003L
             #define 
             #define BS_3STATE           0x00000005L
             #define BS_AUTO3STATE       0x00000006L
             #define BS_GROUPBOX         0x00000007L
             #define BS_USERBUTTON       0x00000008L
             #define BS_AUTORADIOBUTTON  0x00000009L
             #define BS_PUSHBOX          0x0000000AL
             #define BS_OWNERDRAW        0x0000000BL
             #define BS_TYPEMASK         0x0000000FL
             #define BS_LEFTTEXT         0x00000020L
             #if(WINVER >= 0x0400)
             #define BS_TEXT             0x00000000L
             #define BS_ICON             0x00000040L
             #define BS_BITMAP           0x00000080L
             #define BS_LEFT             0x00000100L
             #define BS_RIGHT            0x00000200L
             #define BS_CENTER           0x00000300L
             #define BS_TOP              0x00000400L
             #define BS_BOTTOM           0x00000800L
             #define BS_VCENTER          0x00000C00L
             #define BS_PUSHLIKE         0x00001000L
             #define BS_MULTILINE        0x00002000L
             #define BS_NOTIFY           0x00004000L
             #define BS_FLAT             0x00008000L
             #define BS_RIGHTBUTTON      BS_LEFTTEXT
             */
            
        }
        [Flags]
        public enum WindowStylesEx : uint
        {
            //Extended Window Styles
            WS_EX_DLGMODALFRAME = 0x00000001,
            WS_EX_NOPARENTNOTIFY = 0x00000004,
            WS_EX_TOPMOST = 0x00000008,
            WS_EX_ACCEPTFILES = 0x00000010,
            WS_EX_TRANSPARENT = 0x00000020,
            //#if(WINVER >= 0x0400)
            WS_EX_MDICHILD = 0x00000040,
            WS_EX_TOOLWINDOW = 0x00000080,
            WS_EX_WINDOWEDGE = 0x00000100,
            WS_EX_CLIENTEDGE = 0x00000200,
            WS_EX_CONTEXTHELP = 0x00000400,
            WS_EX_RIGHT = 0x00001000,
            WS_EX_LEFT = 0x00000000,
            WS_EX_RTLREADING = 0x00002000,
            WS_EX_LTRREADING = 0x00000000,
            WS_EX_LEFTSCROLLBAR = 0x00004000,
            WS_EX_RIGHTSCROLLBAR = 0x00000000,
            WS_EX_CONTROLPARENT = 0x00010000,
            WS_EX_STATICEDGE = 0x00020000,
            WS_EX_APPWINDOW = 0x00040000,
            WS_EX_OVERLAPPEDWINDOW = (WS_EX_WINDOWEDGE | WS_EX_CLIENTEDGE),
            WS_EX_PALETTEWINDOW = (WS_EX_WINDOWEDGE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST),
            //#endif /* WINVER >= 0x0400 */
            //#if(WIN32WINNT >= 0x0500)
            WS_EX_LAYERED = 0x00080000,
            //#endif /* WIN32WINNT >= 0x0500 */
            //#if(WINVER >= 0x0500)
            WS_EX_NOINHERITLAYOUT = 0x00100000, // Disable inheritence of mirroring by children
            WS_EX_LAYOUTRTL = 0x00400000, // Right to left mirroring
            //#endif /* WINVER >= 0x0500 */
            //#if(WIN32WINNT >= 0x0500)
            WS_EX_COMPOSITED = 0x02000000,
            WS_EX_NOACTIVATE = 0x08000000
            //#endif /* WIN32WINNT >= 0x0500 */
        }
        private enum ClassStyles : uint
        {
            /// <summary>Aligns the window's client area on a byte boundary (in the x direction). This style affects the width of the window and its horizontal placement on the display.</summary>
            ByteAlignClient = 0x1000,
            /// <summary>Aligns the window on a byte boundary (in the x direction). This style affects the width of the window and its horizontal placement on the display.</summary>
            ByteAlignWindow = 0x2000,
            /// <summary>
            /// Allocates one device context to be shared by all windows in the class.
            /// Because window classes are process specific, it is possible for multiple threads of an application to create a window of the same class.
            /// It is also possible for the threads to attempt to use the device context simultaneously. When this happens, the system allows only one thread to successfully finish its drawing operation.
            /// </summary>
            ClassDC = 0x40,
            /// <summary>Sends a double-click message to the window procedure when the user double-clicks the mouse while the cursor is within a window belonging to the class.</summary>
            DoubleClicks = 0x8,
            /// <summary>
            /// Enables the drop shadow effect on a window. The effect is turned on and off through SPI_SETDROPSHADOW.
            /// Typically, this is enabled for small, short-lived windows such as menus to emphasize their Z order relationship to other windows.
            /// </summary>
            DropShadow = 0x20000,
            /// <summary>Indicates that the window class is an application global class. For more information, see the "Application Global Classes" section of About Window Classes.</summary>
            GlobalClass = 0x4000,
            /// <summary>Redraws the entire window if a movement or size adjustment changes the width of the client area.</summary>
            HorizontalRedraw = 0x2,
            /// <summary>Disables Close on the window menu.</summary>
            NoClose = 0x200,
            /// <summary>Allocates a unique device context for each window in the class.</summary>
            OwnDC = 0x20,
            /// <summary>
            /// Sets the clipping rectangle of the child window to that of the parent window so that the child can draw on the parent.
            /// A window with the CS_PARENTDC style bit receives a regular device context from the system's cache of device contexts.
            /// It does not give the child the parent's device context or device context settings. Specifying CS_PARENTDC enhances an application's performance.
            /// </summary>
            ParentDC = 0x80,
            /// <summary>
            /// Saves, as a bitmap, the portion of the screen image obscured by a window of this class.
            /// When the window is removed, the system uses the saved bitmap to restore the screen image, including other windows that were obscured.
            /// Therefore, the system does not send WM_PAINT messages to windows that were obscured if the memory used by the bitmap has not been discarded and if other screen actions have not invalidated the stored image.
            /// This style is useful for small windows (for example, menus or dialog boxes) that are displayed briefly and then removed before other screen activity takes place.
            /// This style increases the time required to display the window, because the system must first allocate memory to store the bitmap.
            /// </summary>
            SaveBits = 0x800,
            /// <summary>Redraws the entire window if a movement or size adjustment changes the height of the client area.</summary>
            VerticalRedraw = 0x1
        }
        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr DefWindowProcW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
        public delegate IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", SetLastError = true)]
        static extern IntPtr CreateWindowExW(UInt32 dwExStyle,
           [MarshalAs(UnmanagedType.LPWStr)]
       string lpClassName,
           [MarshalAs(UnmanagedType.LPWStr)]
       string lpWindowName,
           UInt32 dwStyle,
           Int32 x,
           Int32 y,
           Int32 nWidth,
           Int32 nHeight,
           IntPtr hWndParent,
           IntPtr hMenu,
           IntPtr hInstance,
           IntPtr lpParam
        );
        [DllImport("user32.dll")]
        static extern IntPtr LoadIcon(IntPtr hInstance, string lpIconName);
        [DllImport("user32.dll")]
        static extern IntPtr LoadCursor(IntPtr hInstance, int lpCursorName);
        [StructLayout(LayoutKind.Sequential)]
        struct WNDCLASS
        {
            public ClassStyles style;
            public IntPtr lpfnWndProc;
            public int cbClsExtra;
            public int cbWndExtra;
            public IntPtr hInstance;
            public IntPtr hIcon;
            public IntPtr hCursor;
            public IntPtr hbrBackground;
            [MarshalAs(UnmanagedType.LPTStr)]
            public string lpszMenuName;
            [MarshalAs(UnmanagedType.LPTStr)]
            public string lpszClassName;
        }
        #endregion
        #region Messages
        /// <summary>
        /// Windows Messages
        /// Defined in winuser.h from Windows SDK v6.1
        /// Documentation pulled from MSDN.
        /// </summary>
        public enum WM : uint
        {
            /// <summary>
            /// The WM_NULL message performs no operation. An application sends the WM_NULL message if it wants to post a message that the recipient window will ignore.
            /// </summary>
            NULL = 0x0000,
            /// <summary>
            /// The WM_CREATE message is sent when an application requests that a window be created by calling the CreateWindowEx or CreateWindow function. (The message is sent before the function returns.) The window procedure of the new window receives this message after the window is created, but before the window becomes visible.
            /// </summary>
            CREATE = 0x0001,
            /// <summary>
            /// The WM_DESTROY message is sent when a window is being destroyed. It is sent to the window procedure of the window being destroyed after the window is removed from the screen.
            /// This message is sent first to the window being destroyed and then to the child windows (if any) as they are destroyed. During the processing of the message, it can be assumed that all child windows still exist.
            /// /// </summary>
            DESTROY = 0x0002,
            /// <summary>
            /// The WM_MOVE message is sent after a window has been moved.
            /// </summary>
            MOVE = 0x0003,
            /// <summary>
            /// The WM_SIZE message is sent to a window after its size has changed.
            /// </summary>
            SIZE = 0x0005,
            /// <summary>
            /// The WM_ACTIVATE message is sent to both the window being activated and the window being deactivated. If the windows use the same input queue, the message is sent synchronously, first to the window procedure of the top-level window being deactivated, then to the window procedure of the top-level window being activated. If the windows use different input queues, the message is sent asynchronously, so the window is activated immediately.
            /// </summary>
            ACTIVATE = 0x0006,
            /// <summary>
            /// The WM_SETFOCUS message is sent to a window after it has gained the keyboard focus.
            /// </summary>
            SETFOCUS = 0x0007,
            /// <summary>
            /// The WM_KILLFOCUS message is sent to a window immediately before it loses the keyboard focus.
            /// </summary>
            KILLFOCUS = 0x0008,
            /// <summary>
            /// The WM_ENABLE message is sent when an application changes the enabled state of a window. It is sent to the window whose enabled state is changing. This message is sent before the EnableWindow function returns, but after the enabled state (WS_DISABLED style bit) of the window has changed.
            /// </summary>
            ENABLE = 0x000A,
            /// <summary>
            /// An application sends the WM_SETREDRAW message to a window to allow changes in that window to be redrawn or to prevent changes in that window from being redrawn.
            /// </summary>
            SETREDRAW = 0x000B,
            /// <summary>
            /// An application sends a WM_SETTEXT message to set the text of a window.
            /// </summary>
            SETTEXT = 0x000C,
            /// <summary>
            /// An application sends a WM_GETTEXT message to copy the text that corresponds to a window into a buffer provided by the caller.
            /// </summary>
            GETTEXT = 0x000D,
            /// <summary>
            /// An application sends a WM_GETTEXTLENGTH message to determine the length, in characters, of the text associated with a window.
            /// </summary>
            GETTEXTLENGTH = 0x000E,
            /// <summary>
            /// The WM_PAINT message is sent when the system or another application makes a request to paint a portion of an application's window. The message is sent when the UpdateWindow or RedrawWindow function is called, or by the DispatchMessage function when the application obtains a WM_PAINT message by using the GetMessage or PeekMessage function.
            /// </summary>
            PAINT = 0x000F,
            /// <summary>
            /// The WM_CLOSE message is sent as a signal that a window or an application should terminate.
            /// </summary>
            CLOSE = 0x0010,
            /// <summary>
            /// The WM_QUERYENDSESSION message is sent when the user chooses to end the session or when an application calls one of the system shutdown functions. If any application returns zero, the session is not ended. The system stops sending WM_QUERYENDSESSION messages as soon as one application returns zero.
            /// After processing this message, the system sends the WM_ENDSESSION message with the wParam parameter set to the results of the WM_QUERYENDSESSION message.
            /// </summary>
            QUERYENDSESSION = 0x0011,
            /// <summary>
            /// The WM_QUERYOPEN message is sent to an icon when the user requests that the window be restored to its previous size and position.
            /// </summary>
            QUERYOPEN = 0x0013,
            /// <summary>
            /// The WM_ENDSESSION message is sent to an application after the system processes the results of the WM_QUERYENDSESSION message. The WM_ENDSESSION message informs the application whether the session is ending.
            /// </summary>
            ENDSESSION = 0x0016,
            /// <summary>
            /// The WM_QUIT message indicates a request to terminate an application and is generated when the application calls the PostQuitMessage function. It causes the GetMessage function to return zero.
            /// </summary>
            QUIT = 0x0012,
            /// <summary>
            /// The WM_ERASEBKGND message is sent when the window background must be erased (for example, when a window is resized). The message is sent to prepare an invalidated portion of a window for painting.
            /// </summary>
            ERASEBKGND = 0x0014,
            /// <summary>
            /// This message is sent to all top-level windows when a change is made to a system color setting.
            /// </summary>
            SYSCOLORCHANGE = 0x0015,
            /// <summary>
            /// The WM_SHOWWINDOW message is sent to a window when the window is about to be hidden or shown.
            /// </summary>
            SHOWWINDOW = 0x0018,
            /// <summary>
            /// An application sends the WM_WININICHANGE message to all top-level windows after making a change to the WIN.INI file. The SystemParametersInfo function sends this message after an application uses the function to change a setting in WIN.INI.
            /// Note  The WM_WININICHANGE message is provided only for compatibility with earlier versions of the system. Applications should use the WM_SETTINGCHANGE message.
            /// </summary>
            WININICHANGE = 0x001A,
            /// <summary>
            /// An application sends the WM_WININICHANGE message to all top-level windows after making a change to the WIN.INI file. The SystemParametersInfo function sends this message after an application uses the function to change a setting in WIN.INI.
            /// Note  The WM_WININICHANGE message is provided only for compatibility with earlier versions of the system. Applications should use the WM_SETTINGCHANGE message.
            /// </summary>
            SETTINGCHANGE = WININICHANGE,
            /// <summary>
            /// The WM_DEVMODECHANGE message is sent to all top-level windows whenever the user changes device-mode settings.
            /// </summary>
            DEVMODECHANGE = 0x001B,
            /// <summary>
            /// The WM_ACTIVATEAPP message is sent when a window belonging to a different application than the active window is about to be activated. The message is sent to the application whose window is being activated and to the application whose window is being deactivated.
            /// </summary>
            ACTIVATEAPP = 0x001C,
            /// <summary>
            /// An application sends the WM_FONTCHANGE message to all top-level windows in the system after changing the pool of font resources.
            /// </summary>
            FONTCHANGE = 0x001D,
            /// <summary>
            /// A message that is sent whenever there is a change in the system time.
            /// </summary>
            TIMECHANGE = 0x001E,
            /// <summary>
            /// The WM_CANCELMODE message is sent to cancel certain modes, such as mouse capture. For example, the system sends this message to the active window when a dialog box or message box is displayed. Certain functions also send this message explicitly to the specified window regardless of whether it is the active window. For example, the EnableWindow function sends this message when disabling the specified window.
            /// </summary>
            CANCELMODE = 0x001F,
            /// <summary>
            /// The WM_SETCURSOR message is sent to a window if the mouse causes the cursor to move within a window and mouse input is not captured.
            /// </summary>
            SETCURSOR = 0x0020,
            /// <summary>
            /// The WM_MOUSEACTIVATE message is sent when the cursor is in an inactive window and the user presses a mouse button. The parent window receives this message only if the child window passes it to the DefWindowProc function.
            /// </summary>
            MOUSEACTIVATE = 0x0021,
            /// <summary>
            /// The WM_CHILDACTIVATE message is sent to a child window when the user clicks the window's title bar or when the window is activated, moved, or sized.
            /// </summary>
            CHILDACTIVATE = 0x0022,
            /// <summary>
            /// The WM_QUEUESYNC message is sent by a computer-based training (CBT) application to separate user-input messages from other messages sent through the WH_JOURNALPLAYBACK Hook procedure.
            /// </summary>
            QUEUESYNC = 0x0023,
            /// <summary>
            /// The WM_GETMINMAXINFO message is sent to a window when the size or position of the window is about to change. An application can use this message to override the window's default maximized size and position, or its default minimum or maximum tracking size.
            /// </summary>
            GETMINMAXINFO = 0x0024,
            /// <summary>
            /// Windows NT 3.51 and earlier: The WM_PAINTICON message is sent to a minimized window when the icon is to be painted. This message is not sent by newer versions of Microsoft Windows, except in unusual circumstances explained in the Remarks.
            /// </summary>
            PAINTICON = 0x0026,
            /// <summary>
            /// Windows NT 3.51 and earlier: The WM_ICONERASEBKGND message is sent to a minimized window when the background of the icon must be filled before painting the icon. A window receives this message only if a class icon is defined for the window; otherwise, WM_ERASEBKGND is sent. This message is not sent by newer versions of Windows.
            /// </summary>
            ICONERASEBKGND = 0x0027,
            /// <summary>
            /// The WM_NEXTDLGCTL message is sent to a dialog box procedure to set the keyboard focus to a different control in the dialog box.
            /// </summary>
            NEXTDLGCTL = 0x0028,
            /// <summary>
            /// The WM_SPOOLERSTATUS message is sent from Print Manager whenever a job is added to or removed from the Print Manager queue.
            /// </summary>
            SPOOLERSTATUS = 0x002A,
            /// <summary>
            /// The WM_DRAWITEM message is sent to the parent window of an owner-drawn button, combo box, list box, or menu when a visual aspect of the button, combo box, list box, or menu has changed.
            /// </summary>
            DRAWITEM = 0x002B,
            /// <summary>
            /// The WM_MEASUREITEM message is sent to the owner window of a combo box, list box, list view control, or menu item when the control or menu is created.
            /// </summary>
            MEASUREITEM = 0x002C,
            /// <summary>
            /// Sent to the owner of a list box or combo box when the list box or combo box is destroyed or when items are removed by the LB_DELETESTRING, LB_RESETCONTENT, CB_DELETESTRING, or CB_RESETCONTENT message. The system sends a WM_DELETEITEM message for each deleted item. The system sends the WM_DELETEITEM message for any deleted list box or combo box item with nonzero item data.
            /// </summary>
            DELETEITEM = 0x002D,
            /// <summary>
            /// Sent by a list box with the LBS_WANTKEYBOARDINPUT style to its owner in response to a WM_KEYDOWN message.
            /// </summary>
            VKEYTOITEM = 0x002E,
            /// <summary>
            /// Sent by a list box with the LBS_WANTKEYBOARDINPUT style to its owner in response to a WM_CHAR message.
            /// </summary>
            CHARTOITEM = 0x002F,
            /// <summary>
            /// An application sends a WM_SETFONT message to specify the font that a control is to use when drawing text.
            /// </summary>
            SETFONT = 0x0030,
            /// <summary>
            /// An application sends a WM_GETFONT message to a control to retrieve the font with which the control is currently drawing its text.
            /// </summary>
            GETFONT = 0x0031,
            /// <summary>
            /// An application sends a WM_SETHOTKEY message to a window to associate a hot key with the window. When the user presses the hot key, the system activates the window.
            /// </summary>
            SETHOTKEY = 0x0032,
            /// <summary>
            /// An application sends a WM_GETHOTKEY message to determine the hot key associated with a window.
            /// </summary>
            GETHOTKEY = 0x0033,
            /// <summary>
            /// The WM_QUERYDRAGICON message is sent to a minimized (iconic) window. The window is about to be dragged by the user but does not have an icon defined for its class. An application can return a handle to an icon or cursor. The system displays this cursor or icon while the user drags the icon.
            /// </summary>
            QUERYDRAGICON = 0x0037,
            /// <summary>
            /// The system sends the WM_COMPAREITEM message to determine the relative position of a new item in the sorted list of an owner-drawn combo box or list box. Whenever the application adds a new item, the system sends this message to the owner of a combo box or list box created with the CBS_SORT or LBS_SORT style.
            /// </summary>
            COMPAREITEM = 0x0039,
            /// <summary>
            /// Active Accessibility sends the WM_GETOBJECT message to obtain information about an accessible object contained in a server application.
            /// Applications never send this message directly. It is sent only by Active Accessibility in response to calls to AccessibleObjectFromPoint, AccessibleObjectFromEvent, or AccessibleObjectFromWindow. However, server applications handle this message.
            /// </summary>
            GETOBJECT = 0x003D,
            /// <summary>
            /// The WM_COMPACTING message is sent to all top-level windows when the system detects more than 12.5 percent of system time over a 30- to 60-second interval is being spent compacting memory. This indicates that system memory is low.
            /// </summary>
            COMPACTING = 0x0041,
            /// <summary>
            /// WM_COMMNOTIFY is Obsolete for Win32-Based Applications
            /// </summary>
            [Obsolete]
            COMMNOTIFY = 0x0044,
            /// <summary>
            /// The WM_WINDOWPOSCHANGING message is sent to a window whose size, position, or place in the Z order is about to change as a result of a call to the SetWindowPos function or another window-management function.
            /// </summary>
            WINDOWPOSCHANGING = 0x0046,
            /// <summary>
            /// The WM_WINDOWPOSCHANGED message is sent to a window whose size, position, or place in the Z order has changed as a result of a call to the SetWindowPos function or another window-management function.
            /// </summary>
            WINDOWPOSCHANGED = 0x0047,
            /// <summary>
            /// Notifies applications that the system, typically a battery-powered personal computer, is about to enter a suspended mode.
            /// Use: POWERBROADCAST
            /// </summary>
            [Obsolete]
            POWER = 0x0048,
            /// <summary>
            /// An application sends the WM_COPYDATA message to pass data to another application.
            /// </summary>
            COPYDATA = 0x004A,
            /// <summary>
            /// The WM_CANCELJOURNAL message is posted to an application when a user cancels the application's journaling activities. The message is posted with a NULL window handle.
            /// </summary>
            CANCELJOURNAL = 0x004B,
            /// <summary>
            /// Sent by a common control to its parent window when an event has occurred or the control requires some information.
            /// </summary>
            NOTIFY = 0x004E,
            /// <summary>
            /// The WM_INPUTLANGCHANGEREQUEST message is posted to the window with the focus when the user chooses a new input language, either with the hotkey (specified in the Keyboard control panel application) or from the indicator on the system taskbar. An application can accept the change by passing the message to the DefWindowProc function or reject the change (and prevent it from taking place) by returning immediately.
            /// </summary>
            INPUTLANGCHANGEREQUEST = 0x0050,
            /// <summary>
            /// The WM_INPUTLANGCHANGE message is sent to the topmost affected window after an application's input language has been changed. You should make any application-specific settings and pass the message to the DefWindowProc function, which passes the message to all first-level child windows. These child windows can pass the message to DefWindowProc to have it pass the message to their child windows, and so on.
            /// </summary>
            INPUTLANGCHANGE = 0x0051,
            /// <summary>
            /// Sent to an application that has initiated a training card with Microsoft Windows Help. The message informs the application when the user clicks an authorable button. An application initiates a training card by specifying the HELP_TCARD command in a call to the WinHelp function.
            /// </summary>
            TCARD = 0x0052,
            /// <summary>
            /// Indicates that the user pressed the F1 key. If a menu is active when F1 is pressed, WM_HELP is sent to the window associated with the menu; otherwise, WM_HELP is sent to the window that has the keyboard focus. If no window has the keyboard focus, WM_HELP is sent to the currently active window.
            /// </summary>
            HELP = 0x0053,
            /// <summary>
            /// The WM_USERCHANGED message is sent to all windows after the user has logged on or off. When the user logs on or off, the system updates the user-specific settings. The system sends this message immediately after updating the settings.
            /// </summary>
            USERCHANGED = 0x0054,
            /// <summary>
            /// Determines if a window accepts ANSI or Unicode structures in the WM_NOTIFY notification message. WM_NOTIFYFORMAT messages are sent from a common control to its parent window and from the parent window to the common control.
            /// </summary>
            NOTIFYFORMAT = 0x0055,
            /// <summary>
            /// The WM_CONTEXTMENU message notifies a window that the user clicked the right mouse button (right-clicked) in the window.
            /// </summary>
            CONTEXTMENU = 0x007B,
            /// <summary>
            /// The WM_STYLECHANGING message is sent to a window when the SetWindowLong function is about to change one or more of the window's styles.
            /// </summary>
            STYLECHANGING = 0x007C,
            /// <summary>
            /// The WM_STYLECHANGED message is sent to a window after the SetWindowLong function has changed one or more of the window's styles
            /// </summary>
            STYLECHANGED = 0x007D,
            /// <summary>
            /// The WM_DISPLAYCHANGE message is sent to all windows when the display resolution has changed.
            /// </summary>
            DISPLAYCHANGE = 0x007E,
            /// <summary>
            /// The WM_GETICON message is sent to a window to retrieve a handle to the large or small icon associated with a window. The system displays the large icon in the ALT+TAB dialog, and the small icon in the window caption.
            /// </summary>
            GETICON = 0x007F,
            /// <summary>
            /// An application sends the WM_SETICON message to associate a new large or small icon with a window. The system displays the large icon in the ALT+TAB dialog box, and the small icon in the window caption.
            /// </summary>
            SETICON = 0x0080,
            /// <summary>
            /// The WM_NCCREATE message is sent prior to the WM_CREATE message when a window is first created.
            /// </summary>
            NCCREATE = 0x0081,
            /// <summary>
            /// The WM_NCDESTROY message informs a window that its nonclient area is being destroyed. The DestroyWindow function sends the WM_NCDESTROY message to the window following the WM_DESTROY message. WM_DESTROY is used to free the allocated memory object associated with the window.
            /// The WM_NCDESTROY message is sent after the child windows have been destroyed. In contrast, WM_DESTROY is sent before the child windows are destroyed.
            /// </summary>
            NCDESTROY = 0x0082,
            /// <summary>
            /// The WM_NCCALCSIZE message is sent when the size and position of a window's client area must be calculated. By processing this message, an application can control the content of the window's client area when the size or position of the window changes.
            /// </summary>
            NCCALCSIZE = 0x0083,
            /// <summary>
            /// The WM_NCHITTEST message is sent to a window when the cursor moves, or when a mouse button is pressed or released. If the mouse is not captured, the message is sent to the window beneath the cursor. Otherwise, the message is sent to the window that has captured the mouse.
            /// </summary>
            NCHITTEST = 0x0084,
            /// <summary>
            /// The WM_NCPAINT message is sent to a window when its frame must be painted.
            /// </summary>
            NCPAINT = 0x0085,
            /// <summary>
            /// The WM_NCACTIVATE message is sent to a window when its nonclient area needs to be changed to indicate an active or inactive state.
            /// </summary>
            NCACTIVATE = 0x0086,
            /// <summary>
            /// The WM_GETDLGCODE message is sent to the window procedure associated with a control. By default, the system handles all keyboard input to the control; the system interprets certain types of keyboard input as dialog box navigation keys. To override this default behavior, the control can respond to the WM_GETDLGCODE message to indicate the types of input it wants to process itself.
            /// </summary>
            GETDLGCODE = 0x0087,
            /// <summary>
            /// The WM_SYNCPAINT message is used to synchronize painting while avoiding linking independent GUI threads.
            /// </summary>
            SYNCPAINT = 0x0088,
            /// <summary>
            /// The WM_NCMOUSEMOVE message is posted to a window when the cursor is moved within the nonclient area of the window. This message is posted to the window that contains the cursor. If a window has captured the mouse, this message is not posted.
            /// </summary>
            NCMOUSEMOVE = 0x00A0,
            /// <summary>
            /// The WM_NCLBUTTONDOWN message is posted when the user presses the left mouse button while the cursor is within the nonclient area of a window. This message is posted to the window that contains the cursor. If a window has captured the mouse, this message is not posted.
            /// </summary>
            NCLBUTTONDOWN = 0x00A1,
            /// <summary>
            /// The WM_NCLBUTTONUP message is posted when the user releases the left mouse button while the cursor is within the nonclient area of a window. This message is posted to the window that contains the cursor. If a window has captured the mouse, this message is not posted.
            /// </summary>
            NCLBUTTONUP = 0x00A2,
            /// <summary>
            /// The WM_NCLBUTTONDBLCLK message is posted when the user double-clicks the left mouse button while the cursor is within the nonclient area of a window. This message is posted to the window that contains the cursor. If a window has captured the mouse, this message is not posted.
            /// </summary>
            NCLBUTTONDBLCLK = 0x00A3,
            /// <summary>
            /// The WM_NCRBUTTONDOWN message is posted when the user presses the right mouse button while the cursor is within the nonclient area of a window. This message is posted to the window that contains the cursor. If a window has captured the mouse, this message is not posted.
            /// </summary>
            NCRBUTTONDOWN = 0x00A4,
            /// <summary>
            /// The WM_NCRBUTTONUP message is posted when the user releases the right mouse button while the cursor is within the nonclient area of a window. This message is posted to the window that contains the cursor. If a window has captured the mouse, this message is not posted.
            /// </summary>
            NCRBUTTONUP = 0x00A5,
            /// <summary>
            /// The WM_NCRBUTTONDBLCLK message is posted when the user double-clicks the right mouse button while the cursor is within the nonclient area of a window. This message is posted to the window that contains the cursor. If a window has captured the mouse, this message is not posted.
            /// </summary>
            NCRBUTTONDBLCLK = 0x00A6,
            /// <summary>
            /// The WM_NCMBUTTONDOWN message is posted when the user presses the middle mouse button while the cursor is within the nonclient area of a window. This message is posted to the window that contains the cursor. If a window has captured the mouse, this message is not posted.
            /// </summary>
            NCMBUTTONDOWN = 0x00A7,
            /// <summary>
            /// The WM_NCMBUTTONUP message is posted when the user releases the middle mouse button while the cursor is within the nonclient area of a window. This message is posted to the window that contains the cursor. If a window has captured the mouse, this message is not posted.
            /// </summary>
            NCMBUTTONUP = 0x00A8,
            /// <summary>
            /// The WM_NCMBUTTONDBLCLK message is posted when the user double-clicks the middle mouse button while the cursor is within the nonclient area of a window. This message is posted to the window that contains the cursor. If a window has captured the mouse, this message is not posted.
            /// </summary>
            NCMBUTTONDBLCLK = 0x00A9,
            /// <summary>
            /// The WM_NCXBUTTONDOWN message is posted when the user presses the first or second X button while the cursor is in the nonclient area of a window. This message is posted to the window that contains the cursor. If a window has captured the mouse, this message is not posted.
            /// </summary>
            NCXBUTTONDOWN = 0x00AB,
            /// <summary>
            /// The WM_NCXBUTTONUP message is posted when the user releases the first or second X button while the cursor is in the nonclient area of a window. This message is posted to the window that contains the cursor. If a window has captured the mouse, this message is not posted.
            /// </summary>
            NCXBUTTONUP = 0x00AC,
            /// <summary>
            /// The WM_NCXBUTTONDBLCLK message is posted when the user double-clicks the first or second X button while the cursor is in the nonclient area of a window. This message is posted to the window that contains the cursor. If a window has captured the mouse, this message is not posted.
            /// </summary>
            NCXBUTTONDBLCLK = 0x00AD,
            /// <summary>
            /// The WM_INPUT_DEVICE_CHANGE message is sent to the window that registered to receive raw input. A window receives this message through its WindowProc function.
            /// </summary>
            INPUT_DEVICE_CHANGE = 0x00FE,
            /// <summary>
            /// The WM_INPUT message is sent to the window that is getting raw input.
            /// </summary>
            INPUT = 0x00FF,
            /// <summary>
            /// This message filters for keyboard messages.
            /// </summary>
            KEYFIRST = 0x0100,
            /// <summary>
            /// The WM_KEYDOWN message is posted to the window with the keyboard focus when a nonsystem key is pressed. A nonsystem key is a key that is pressed when the ALT key is not pressed.
            /// </summary>
            KEYDOWN = 0x0100,
            /// <summary>
            /// The WM_KEYUP message is posted to the window with the keyboard focus when a nonsystem key is released. A nonsystem key is a key that is pressed when the ALT key is not pressed, or a keyboard key that is pressed when a window has the keyboard focus.
            /// </summary>
            KEYUP = 0x0101,
            /// <summary>
            /// The WM_CHAR message is posted to the window with the keyboard focus when a WM_KEYDOWN message is translated by the TranslateMessage function. The WM_CHAR message contains the character code of the key that was pressed.
            /// </summary>
            CHAR = 0x0102,
            /// <summary>
            /// The WM_DEADCHAR message is posted to the window with the keyboard focus when a WM_KEYUP message is translated by the TranslateMessage function. WM_DEADCHAR specifies a character code generated by a dead key. A dead key is a key that generates a character, such as the umlaut (double-dot), that is combined with another character to form a composite character. For example, the umlaut-O character (Ö) is generated by typing the dead key for the umlaut character, and then typing the O key.
            /// </summary>
            DEADCHAR = 0x0103,
            /// <summary>
            /// The WM_SYSKEYDOWN message is posted to the window with the keyboard focus when the user presses the F10 key (which activates the menu bar) or holds down the ALT key and then presses another key. It also occurs when no window currently has the keyboard focus; in this case, the WM_SYSKEYDOWN message is sent to the active window. The window that receives the message can distinguish between these two contexts by checking the context code in the lParam parameter.
            /// </summary>
            SYSKEYDOWN = 0x0104,
            /// <summary>
            /// The WM_SYSKEYUP message is posted to the window with the keyboard focus when the user releases a key that was pressed while the ALT key was held down. It also occurs when no window currently has the keyboard focus; in this case, the WM_SYSKEYUP message is sent to the active window. The window that receives the message can distinguish between these two contexts by checking the context code in the lParam parameter.
            /// </summary>
            SYSKEYUP = 0x0105,
            /// <summary>
            /// The WM_SYSCHAR message is posted to the window with the keyboard focus when a WM_SYSKEYDOWN message is translated by the TranslateMessage function. It specifies the character code of a system character key  that is, a character key that is pressed while the ALT key is down.
            /// </summary>
            SYSCHAR = 0x0106,
            /// <summary>
            /// The WM_SYSDEADCHAR message is sent to the window with the keyboard focus when a WM_SYSKEYDOWN message is translated by the TranslateMessage function. WM_SYSDEADCHAR specifies the character code of a system dead key  that is, a dead key that is pressed while holding down the ALT key.
            /// </summary>
            SYSDEADCHAR = 0x0107,
            /// <summary>
            /// The WM_UNICHAR message is posted to the window with the keyboard focus when a WM_KEYDOWN message is translated by the TranslateMessage function. The WM_UNICHAR message contains the character code of the key that was pressed.
            /// The WM_UNICHAR message is equivalent to WM_CHAR, but it uses Unicode Transformation Format (UTF)-32, whereas WM_CHAR uses UTF-16. It is designed to send or post Unicode characters to ANSI windows and it can can handle Unicode Supplementary Plane characters.
            /// </summary>
            UNICHAR = 0x0109,
            /// <summary>
            /// This message filters for keyboard messages.
            /// </summary>
            KEYLAST = 0x0109,
            /// <summary>
            /// Sent immediately before the IME generates the composition string as a result of a keystroke. A window receives this message through its WindowProc function.
            /// </summary>
            IME_STARTCOMPOSITION = 0x010D,
            /// <summary>
            /// Sent to an application when the IME ends composition. A window receives this message through its WindowProc function.
            /// </summary>
            IME_ENDCOMPOSITION = 0x010E,
            /// <summary>
            /// Sent to an application when the IME changes composition status as a result of a keystroke. A window receives this message through its WindowProc function.
            /// </summary>
            IME_COMPOSITION = 0x010F,
            IME_KEYLAST = 0x010F,
            /// <summary>
            /// The WM_INITDIALOG message is sent to the dialog box procedure immediately before a dialog box is displayed. Dialog box procedures typically use this message to initialize controls and carry out any other initialization tasks that affect the appearance of the dialog box.
            /// </summary>
            INITDIALOG = 0x0110,
            /// <summary>
            /// The WM_COMMAND message is sent when the user selects a command item from a menu, when a control sends a notification message to its parent window, or when an accelerator keystroke is translated.
            /// </summary>
            COMMAND = 0x0111,
            /// <summary>
            /// A window receives this message when the user chooses a command from the Window menu, clicks the maximize button, minimize button, restore button, close button, or moves the form. You can stop the form from moving by filtering this out.
            /// </summary>
            SYSCOMMAND = 0x0112,
            /// <summary>
            /// The WM_TIMER message is posted to the installing thread's message queue when a timer expires. The message is posted by the GetMessage or PeekMessage function.
            /// </summary>
            TIMER = 0x0113,
            /// <summary>
            /// The WM_HSCROLL message is sent to a window when a scroll event occurs in the window's standard horizontal scroll bar. This message is also sent to the owner of a horizontal scroll bar control when a scroll event occurs in the control.
            /// </summary>
            HSCROLL = 0x0114,
            /// <summary>
            /// The WM_VSCROLL message is sent to a window when a scroll event occurs in the window's standard vertical scroll bar. This message is also sent to the owner of a vertical scroll bar control when a scroll event occurs in the control.
            /// </summary>
            VSCROLL = 0x0115,
            /// <summary>
            /// The WM_INITMENU message is sent when a menu is about to become active. It occurs when the user clicks an item on the menu bar or presses a menu key. This allows the application to modify the menu before it is displayed.
            /// </summary>
            INITMENU = 0x0116,
            /// <summary>
            /// The WM_INITMENUPOPUP message is sent when a drop-down menu or submenu is about to become active. This allows an application to modify the menu before it is displayed, without changing the entire menu.
            /// </summary>
            INITMENUPOPUP = 0x0117,
            /// <summary>
            /// The WM_MENUSELECT message is sent to a menu's owner window when the user selects a menu item.
            /// </summary>
            MENUSELECT = 0x011F,
            /// <summary>
            /// The WM_MENUCHAR message is sent when a menu is active and the user presses a key that does not correspond to any mnemonic or accelerator key. This message is sent to the window that owns the menu.
            /// </summary>
            MENUCHAR = 0x0120,
            /// <summary>
            /// The WM_ENTERIDLE message is sent to the owner window of a modal dialog box or menu that is entering an idle state. A modal dialog box or menu enters an idle state when no messages are waiting in its queue after it has processed one or more previous messages.
            /// </summary>
            ENTERIDLE = 0x0121,
            /// <summary>
            /// The WM_MENURBUTTONUP message is sent when the user releases the right mouse button while the cursor is on a menu item.
            /// </summary>
            MENURBUTTONUP = 0x0122,
            /// <summary>
            /// The WM_MENUDRAG message is sent to the owner of a drag-and-drop menu when the user drags a menu item.
            /// </summary>
            MENUDRAG = 0x0123,
            /// <summary>
            /// The WM_MENUGETOBJECT message is sent to the owner of a drag-and-drop menu when the mouse cursor enters a menu item or moves from the center of the item to the top or bottom of the item.
            /// </summary>
            MENUGETOBJECT = 0x0124,
            /// <summary>
            /// The WM_UNINITMENUPOPUP message is sent when a drop-down menu or submenu has been destroyed.
            /// </summary>
            UNINITMENUPOPUP = 0x0125,
            /// <summary>
            /// The WM_MENUCOMMAND message is sent when the user makes a selection from a menu.
            /// </summary>
            MENUCOMMAND = 0x0126,
            /// <summary>
            /// An application sends the WM_CHANGEUISTATE message to indicate that the user interface (UI) state should be changed.
            /// </summary>
            CHANGEUISTATE = 0x0127,
            /// <summary>
            /// An application sends the WM_UPDATEUISTATE message to change the user interface (UI) state for the specified window and all its child windows.
            /// </summary>
            UPDATEUISTATE = 0x0128,
            /// <summary>
            /// An application sends the WM_QUERYUISTATE message to retrieve the user interface (UI) state for a window.
            /// </summary>
            QUERYUISTATE = 0x0129,
            /// <summary>
            /// The WM_CTLCOLORMSGBOX message is sent to the owner window of a message box before Windows draws the message box. By responding to this message, the owner window can set the text and background colors of the message box by using the given display device context handle.
            /// </summary>
            CTLCOLORMSGBOX = 0x0132,
            /// <summary>
            /// An edit control that is not read-only or disabled sends the WM_CTLCOLOREDIT message to its parent window when the control is about to be drawn. By responding to this message, the parent window can use the specified device context handle to set the text and background colors of the edit control.
            /// </summary>
            CTLCOLOREDIT = 0x0133,
            /// <summary>
            /// Sent to the parent window of a list box before the system draws the list box. By responding to this message, the parent window can set the text and background colors of the list box by using the specified display device context handle.
            /// </summary>
            CTLCOLORLISTBOX = 0x0134,
            /// <summary>
            /// The WM_CTLCOLORBTN message is sent to the parent window of a button before drawing the button. The parent window can change the button's text and background colors. However, only owner-drawn buttons respond to the parent window processing this message.
            /// </summary>
            CTLCOLORBTN = 0x0135,
            /// <summary>
            /// The WM_CTLCOLORDLG message is sent to a dialog box before the system draws the dialog box. By responding to this message, the dialog box can set its text and background colors using the specified display device context handle.
            /// </summary>
            CTLCOLORDLG = 0x0136,
            /// <summary>
            /// The WM_CTLCOLORSCROLLBAR message is sent to the parent window of a scroll bar control when the control is about to be drawn. By responding to this message, the parent window can use the display context handle to set the background color of the scroll bar control.
            /// </summary>
            CTLCOLORSCROLLBAR = 0x0137,
            /// <summary>
            /// A static control, or an edit control that is read-only or disabled, sends the WM_CTLCOLORSTATIC message to its parent window when the control is about to be drawn. By responding to this message, the parent window can use the specified device context handle to set the text and background colors of the static control.
            /// </summary>
            CTLCOLORSTATIC = 0x0138,
            /// <summary>
            /// Use WM_MOUSEFIRST to specify the first mouse message. Use the PeekMessage() Function.
            /// </summary>
            MOUSEFIRST = 0x0200,
            /// <summary>
            /// The WM_MOUSEMOVE message is posted to a window when the cursor moves. If the mouse is not captured, the message is posted to the window that contains the cursor. Otherwise, the message is posted to the window that has captured the mouse.
            /// </summary>
            MOUSEMOVE = 0x0200,
            /// <summary>
            /// The WM_LBUTTONDOWN message is posted when the user presses the left mouse button while the cursor is in the client area of a window. If the mouse is not captured, the message is posted to the window beneath the cursor. Otherwise, the message is posted to the window that has captured the mouse.
            /// </summary>
            LBUTTONDOWN = 0x0201,
            /// <summary>
            /// The WM_LBUTTONUP message is posted when the user releases the left mouse button while the cursor is in the client area of a window. If the mouse is not captured, the message is posted to the window beneath the cursor. Otherwise, the message is posted to the window that has captured the mouse.
            /// </summary>
            LBUTTONUP = 0x0202,
            /// <summary>
            /// The WM_LBUTTONDBLCLK message is posted when the user double-clicks the left mouse button while the cursor is in the client area of a window. If the mouse is not captured, the message is posted to the window beneath the cursor. Otherwise, the message is posted to the window that has captured the mouse.
            /// </summary>
            LBUTTONDBLCLK = 0x0203,
            /// <summary>
            /// The WM_RBUTTONDOWN message is posted when the user presses the right mouse button while the cursor is in the client area of a window. If the mouse is not captured, the message is posted to the window beneath the cursor. Otherwise, the message is posted to the window that has captured the mouse.
            /// </summary>
            RBUTTONDOWN = 0x0204,
            /// <summary>
            /// The WM_RBUTTONUP message is posted when the user releases the right mouse button while the cursor is in the client area of a window. If the mouse is not captured, the message is posted to the window beneath the cursor. Otherwise, the message is posted to the window that has captured the mouse.
            /// </summary>
            RBUTTONUP = 0x0205,
            /// <summary>
            /// The WM_RBUTTONDBLCLK message is posted when the user double-clicks the right mouse button while the cursor is in the client area of a window. If the mouse is not captured, the message is posted to the window beneath the cursor. Otherwise, the message is posted to the window that has captured the mouse.
            /// </summary>
            RBUTTONDBLCLK = 0x0206,
            /// <summary>
            /// The WM_MBUTTONDOWN message is posted when the user presses the middle mouse button while the cursor is in the client area of a window. If the mouse is not captured, the message is posted to the window beneath the cursor. Otherwise, the message is posted to the window that has captured the mouse.
            /// </summary>
            MBUTTONDOWN = 0x0207,
            /// <summary>
            /// The WM_MBUTTONUP message is posted when the user releases the middle mouse button while the cursor is in the client area of a window. If the mouse is not captured, the message is posted to the window beneath the cursor. Otherwise, the message is posted to the window that has captured the mouse.
            /// </summary>
            MBUTTONUP = 0x0208,
            /// <summary>
            /// The WM_MBUTTONDBLCLK message is posted when the user double-clicks the middle mouse button while the cursor is in the client area of a window. If the mouse is not captured, the message is posted to the window beneath the cursor. Otherwise, the message is posted to the window that has captured the mouse.
            /// </summary>
            MBUTTONDBLCLK = 0x0209,
            /// <summary>
            /// The WM_MOUSEWHEEL message is sent to the focus window when the mouse wheel is rotated. The DefWindowProc function propagates the message to the window's parent. There should be no internal forwarding of the message, since DefWindowProc propagates it up the parent chain until it finds a window that processes it.
            /// </summary>
            MOUSEWHEEL = 0x020A,
            /// <summary>
            /// The WM_XBUTTONDOWN message is posted when the user presses the first or second X button while the cursor is in the client area of a window. If the mouse is not captured, the message is posted to the window beneath the cursor. Otherwise, the message is posted to the window that has captured the mouse.
            /// </summary>
            XBUTTONDOWN = 0x020B,
            /// <summary>
            /// The WM_XBUTTONUP message is posted when the user releases the first or second X button while the cursor is in the client area of a window. If the mouse is not captured, the message is posted to the window beneath the cursor. Otherwise, the message is posted to the window that has captured the mouse.
            /// </summary>
            XBUTTONUP = 0x020C,
            /// <summary>
            /// The WM_XBUTTONDBLCLK message is posted when the user double-clicks the first or second X button while the cursor is in the client area of a window. If the mouse is not captured, the message is posted to the window beneath the cursor. Otherwise, the message is posted to the window that has captured the mouse.
            /// </summary>
            XBUTTONDBLCLK = 0x020D,
            /// <summary>
            /// The WM_MOUSEHWHEEL message is sent to the focus window when the mouse's horizontal scroll wheel is tilted or rotated. The DefWindowProc function propagates the message to the window's parent. There should be no internal forwarding of the message, since DefWindowProc propagates it up the parent chain until it finds a window that processes it.
            /// </summary>
            MOUSEHWHEEL = 0x020A,
            /// <summary>
            /// Use WM_MOUSELAST to specify the last mouse message. Used with PeekMessage() Function.
            /// </summary>
            MOUSELAST = 0x020E,
            /// <summary>
            /// The WM_PARENTNOTIFY message is sent to the parent of a child window when the child window is created or destroyed, or when the user clicks a mouse button while the cursor is over the child window. When the child window is being created, the system sends WM_PARENTNOTIFY just before the CreateWindow or CreateWindowEx function that creates the window returns. When the child window is being destroyed, the system sends the message before any processing to destroy the window takes place.
            /// </summary>
            PARENTNOTIFY = 0x0210,
            /// <summary>
            /// The WM_ENTERMENULOOP message informs an application's main window procedure that a menu modal loop has been entered.
            /// </summary>
            ENTERMENULOOP = 0x0211,
            /// <summary>
            /// The WM_EXITMENULOOP message informs an application's main window procedure that a menu modal loop has been exited.
            /// </summary>
            EXITMENULOOP = 0x0212,
            /// <summary>
            /// The WM_NEXTMENU message is sent to an application when the right or left arrow key is used to switch between the menu bar and the system menu.
            /// </summary>
            NEXTMENU = 0x0213,
            /// <summary>
            /// The WM_SIZING message is sent to a window that the user is resizing. By processing this message, an application can monitor the size and position of the drag rectangle and, if needed, change its size or position.
            /// </summary>
            SIZING = 0x0214,
            /// <summary>
            /// The WM_CAPTURECHANGED message is sent to the window that is losing the mouse capture.
            /// </summary>
            CAPTURECHANGED = 0x0215,
            /// <summary>
            /// The WM_MOVING message is sent to a window that the user is moving. By processing this message, an application can monitor the position of the drag rectangle and, if needed, change its position.
            /// </summary>
            MOVING = 0x0216,
            /// <summary>
            /// Notifies applications that a power-management event has occurred.
            /// </summary>
            POWERBROADCAST = 0x0218,
            /// <summary>
            /// Notifies an application of a change to the hardware configuration of a device or the computer.
            /// </summary>
            DEVICECHANGE = 0x0219,
            /// <summary>
            /// An application sends the WM_MDICREATE message to a multiple-document interface (MDI) client window to create an MDI child window.
            /// </summary>
            MDICREATE = 0x0220,
            /// <summary>
            /// An application sends the WM_MDIDESTROY message to a multiple-document interface (MDI) client window to close an MDI child window.
            /// </summary>
            MDIDESTROY = 0x0221,
            /// <summary>
            /// An application sends the WM_MDIACTIVATE message to a multiple-document interface (MDI) client window to instruct the client window to activate a different MDI child window.
            /// </summary>
            MDIACTIVATE = 0x0222,
            /// <summary>
            /// An application sends the WM_MDIRESTORE message to a multiple-document interface (MDI) client window to restore an MDI child window from maximized or minimized size.
            /// </summary>
            MDIRESTORE = 0x0223,
            /// <summary>
            /// An application sends the WM_MDINEXT message to a multiple-document interface (MDI) client window to activate the next or previous child window.
            /// </summary>
            MDINEXT = 0x0224,
            /// <summary>
            /// An application sends the WM_MDIMAXIMIZE message to a multiple-document interface (MDI) client window to maximize an MDI child window. The system resizes the child window to make its client area fill the client window. The system places the child window's window menu icon in the rightmost position of the frame window's menu bar, and places the child window's restore icon in the leftmost position. The system also appends the title bar text of the child window to that of the frame window.
            /// </summary>
            MDIMAXIMIZE = 0x0225,
            /// <summary>
            /// An application sends the WM_MDITILE message to a multiple-document interface (MDI) client window to arrange all of its MDI child windows in a tile format.
            /// </summary>
            MDITILE = 0x0226,
            /// <summary>
            /// An application sends the WM_MDICASCADE message to a multiple-document interface (MDI) client window to arrange all its child windows in a cascade format.
            /// </summary>
            MDICASCADE = 0x0227,
            /// <summary>
            /// An application sends the WM_MDIICONARRANGE message to a multiple-document interface (MDI) client window to arrange all minimized MDI child windows. It does not affect child windows that are not minimized.
            /// </summary>
            MDIICONARRANGE = 0x0228,
            /// <summary>
            /// An application sends the WM_MDIGETACTIVE message to a multiple-document interface (MDI) client window to retrieve the handle to the active MDI child window.
            /// </summary>
            MDIGETACTIVE = 0x0229,
            /// <summary>
            /// An application sends the WM_MDISETMENU message to a multiple-document interface (MDI) client window to replace the entire menu of an MDI frame window, to replace the window menu of the frame window, or both.
            /// </summary>
            MDISETMENU = 0x0230,
            /// <summary>
            /// The WM_ENTERSIZEMOVE message is sent one time to a window after it enters the moving or sizing modal loop. The window enters the moving or sizing modal loop when the user clicks the window's title bar or sizing border, or when the window passes the WM_SYSCOMMAND message to the DefWindowProc function and the wParam parameter of the message specifies the SC_MOVE or SC_SIZE value. The operation is complete when DefWindowProc returns.
            /// The system sends the WM_ENTERSIZEMOVE message regardless of whether the dragging of full windows is enabled.
            /// </summary>
            ENTERSIZEMOVE = 0x0231,
            /// <summary>
            /// The WM_EXITSIZEMOVE message is sent one time to a window, after it has exited the moving or sizing modal loop. The window enters the moving or sizing modal loop when the user clicks the window's title bar or sizing border, or when the window passes the WM_SYSCOMMAND message to the DefWindowProc function and the wParam parameter of the message specifies the SC_MOVE or SC_SIZE value. The operation is complete when DefWindowProc returns.
            /// </summary>
            EXITSIZEMOVE = 0x0232,
            /// <summary>
            /// Sent when the user drops a file on the window of an application that has registered itself as a recipient of dropped files.
            /// </summary>
            DROPFILES = 0x0233,
            /// <summary>
            /// An application sends the WM_MDIREFRESHMENU message to a multiple-document interface (MDI) client window to refresh the window menu of the MDI frame window.
            /// </summary>
            MDIREFRESHMENU = 0x0234,
            /// <summary>
            /// Sent to an application when a window is activated. A window receives this message through its WindowProc function.
            /// </summary>
            IME_SETCONTEXT = 0x0281,
            /// <summary>
            /// Sent to an application to notify it of changes to the IME window. A window receives this message through its WindowProc function.
            /// </summary>
            IME_NOTIFY = 0x0282,
            /// <summary>
            /// Sent by an application to direct the IME window to carry out the requested command. The application uses this message to control the IME window that it has created. To send this message, the application calls the SendMessage function with the following parameters.
            /// </summary>
            IME_CONTROL = 0x0283,
            /// <summary>
            /// Sent to an application when the IME window finds no space to extend the area for the composition window. A window receives this message through its WindowProc function.
            /// </summary>
            IME_COMPOSITIONFULL = 0x0284,
            /// <summary>
            /// Sent to an application when the operating system is about to change the current IME. A window receives this message through its WindowProc function.
            /// </summary>
            IME_SELECT = 0x0285,
            /// <summary>
            /// Sent to an application when the IME gets a character of the conversion result. A window receives this message through its WindowProc function.
            /// </summary>
            IME_CHAR = 0x0286,
            /// <summary>
            /// Sent to an application to provide commands and request information. A window receives this message through its WindowProc function.
            /// </summary>
            IME_REQUEST = 0x0288,
            /// <summary>
            /// Sent to an application by the IME to notify the application of a key press and to keep message order. A window receives this message through its WindowProc function.
            /// </summary>
            IME_KEYDOWN = 0x0290,
            /// <summary>
            /// Sent to an application by the IME to notify the application of a key release and to keep message order. A window receives this message through its WindowProc function.
            /// </summary>
            IME_KEYUP = 0x0291,
            /// <summary>
            /// The WM_MOUSEHOVER message is posted to a window when the cursor hovers over the client area of the window for the period of time specified in a prior call to TrackMouseEvent.
            /// </summary>
            MOUSEHOVER = 0x02A1,
            /// <summary>
            /// The WM_MOUSELEAVE message is posted to a window when the cursor leaves the client area of the window specified in a prior call to TrackMouseEvent.
            /// </summary>
            MOUSELEAVE = 0x02A3,
            /// <summary>
            /// The WM_NCMOUSEHOVER message is posted to a window when the cursor hovers over the nonclient area of the window for the period of time specified in a prior call to TrackMouseEvent.
            /// </summary>
            NCMOUSEHOVER = 0x02A0,
            /// <summary>
            /// The WM_NCMOUSELEAVE message is posted to a window when the cursor leaves the nonclient area of the window specified in a prior call to TrackMouseEvent.
            /// </summary>
            NCMOUSELEAVE = 0x02A2,
            /// <summary>
            /// The WM_WTSSESSION_CHANGE message notifies applications of changes in session state.
            /// </summary>
            WTSSESSION_CHANGE = 0x02B1,
            TABLET_FIRST = 0x02c0,
            TABLET_LAST = 0x02df,
            /// <summary>
            /// An application sends a WM_CUT message to an edit control or combo box to delete (cut) the current selection, if any, in the edit control and copy the deleted text to the clipboard in CF_TEXT format.
            /// </summary>
            CUT = 0x0300,
            /// <summary>
            /// An application sends the WM_COPY message to an edit control or combo box to copy the current selection to the clipboard in CF_TEXT format.
            /// </summary>
            COPY = 0x0301,
            /// <summary>
            /// An application sends a WM_PASTE message to an edit control or combo box to copy the current content of the clipboard to the edit control at the current caret position. Data is inserted only if the clipboard contains data in CF_TEXT format.
            /// </summary>
            PASTE = 0x0302,
            /// <summary>
            /// An application sends a WM_CLEAR message to an edit control or combo box to delete (clear) the current selection, if any, from the edit control.
            /// </summary>
            CLEAR = 0x0303,
            /// <summary>
            /// An application sends a WM_UNDO message to an edit control to undo the last operation. When this message is sent to an edit control, the previously deleted text is restored or the previously added text is deleted.
            /// </summary>
            UNDO = 0x0304,
            /// <summary>
            /// The WM_RENDERFORMAT message is sent to the clipboard owner if it has delayed rendering a specific clipboard format and if an application has requested data in that format. The clipboard owner must render data in the specified format and place it on the clipboard by calling the SetClipboardData function.
            /// </summary>
            RENDERFORMAT = 0x0305,
            /// <summary>
            /// The WM_RENDERALLFORMATS message is sent to the clipboard owner before it is destroyed, if the clipboard owner has delayed rendering one or more clipboard formats. For the content of the clipboard to remain available to other applications, the clipboard owner must render data in all the formats it is capable of generating, and place the data on the clipboard by calling the SetClipboardData function.
            /// </summary>
            RENDERALLFORMATS = 0x0306,
            /// <summary>
            /// The WM_DESTROYCLIPBOARD message is sent to the clipboard owner when a call to the EmptyClipboard function empties the clipboard.
            /// </summary>
            DESTROYCLIPBOARD = 0x0307,
            /// <summary>
            /// The WM_DRAWCLIPBOARD message is sent to the first window in the clipboard viewer chain when the content of the clipboard changes. This enables a clipboard viewer window to display the new content of the clipboard.
            /// </summary>
            DRAWCLIPBOARD = 0x0308,
            /// <summary>
            /// The WM_PAINTCLIPBOARD message is sent to the clipboard owner by a clipboard viewer window when the clipboard contains data in the CF_OWNERDISPLAY format and the clipboard viewer's client area needs repainting.
            /// </summary>
            PAINTCLIPBOARD = 0x0309,
            /// <summary>
            /// The WM_VSCROLLCLIPBOARD message is sent to the clipboard owner by a clipboard viewer window when the clipboard contains data in the CF_OWNERDISPLAY format and an event occurs in the clipboard viewer's vertical scroll bar. The owner should scroll the clipboard image and update the scroll bar values.
            /// </summary>
            VSCROLLCLIPBOARD = 0x030A,
            /// <summary>
            /// The WM_SIZECLIPBOARD message is sent to the clipboard owner by a clipboard viewer window when the clipboard contains data in the CF_OWNERDISPLAY format and the clipboard viewer's client area has changed size.
            /// </summary>
            SIZECLIPBOARD = 0x030B,
            /// <summary>
            /// The WM_ASKCBFORMATNAME message is sent to the clipboard owner by a clipboard viewer window to request the name of a CF_OWNERDISPLAY clipboard format.
            /// </summary>
            ASKCBFORMATNAME = 0x030C,
            /// <summary>
            /// The WM_CHANGECBCHAIN message is sent to the first window in the clipboard viewer chain when a window is being removed from the chain.
            /// </summary>
            CHANGECBCHAIN = 0x030D,
            /// <summary>
            /// The WM_HSCROLLCLIPBOARD message is sent to the clipboard owner by a clipboard viewer window. This occurs when the clipboard contains data in the CF_OWNERDISPLAY format and an event occurs in the clipboard viewer's horizontal scroll bar. The owner should scroll the clipboard image and update the scroll bar values.
            /// </summary>
            HSCROLLCLIPBOARD = 0x030E,
            /// <summary>
            /// This message informs a window that it is about to receive the keyboard focus, giving the window the opportunity to realize its logical palette when it receives the focus.
            /// </summary>
            QUERYNEWPALETTE = 0x030F,
            /// <summary>
            /// The WM_PALETTEISCHANGING message informs applications that an application is going to realize its logical palette.
            /// </summary>
            PALETTEISCHANGING = 0x0310,
            /// <summary>
            /// This message is sent by the OS to all top-level and overlapped windows after the window with the keyboard focus realizes its logical palette.
            /// This message enables windows that do not have the keyboard focus to realize their logical palettes and update their client areas.
            /// </summary>
            PALETTECHANGED = 0x0311,
            /// <summary>
            /// The WM_HOTKEY message is posted when the user presses a hot key registered by the RegisterHotKey function. The message is placed at the top of the message queue associated with the thread that registered the hot key.
            /// </summary>
            HOTKEY = 0x0312,
            /// <summary>
            /// The WM_PRINT message is sent to a window to request that it draw itself in the specified device context, most commonly in a printer device context.
            /// </summary>
            PRINT = 0x0317,
            /// <summary>
            /// The WM_PRINTCLIENT message is sent to a window to request that it draw its client area in the specified device context, most commonly in a printer device context.
            /// </summary>
            PRINTCLIENT = 0x0318,
            /// <summary>
            /// The WM_APPCOMMAND message notifies a window that the user generated an application command event, for example, by clicking an application command button using the mouse or typing an application command key on the keyboard.
            /// </summary>
            APPCOMMAND = 0x0319,
            /// <summary>
            /// The WM_THEMECHANGED message is broadcast to every window following a theme change event. Examples of theme change events are the activation of a theme, the deactivation of a theme, or a transition from one theme to another.
            /// </summary>
            THEMECHANGED = 0x031A,
            /// <summary>
            /// Sent when the contents of the clipboard have changed.
            /// </summary>
            CLIPBOARDUPDATE = 0x031D,
            /// <summary>
            /// The system will send a window the WM_DWMCOMPOSITIONCHANGED message to indicate that the availability of desktop composition has changed.
            /// </summary>
            DWMCOMPOSITIONCHANGED = 0x031E,
            /// <summary>
            /// WM_DWMNCRENDERINGCHANGED is called when the non-client area rendering status of a window has changed. Only windows that have set the flag DWM_BLURBEHIND.fTransitionOnMaximized to true will get this message.
            /// </summary>
            DWMNCRENDERINGCHANGED = 0x031F,
            /// <summary>
            /// Sent to all top-level windows when the colorization color has changed.
            /// </summary>
            DWMCOLORIZATIONCOLORCHANGED = 0x0320,
            /// <summary>
            /// WM_DWMWINDOWMAXIMIZEDCHANGE will let you know when a DWM composed window is maximized. You also have to register for this message as well. You'd have other windowd go opaque when this message is sent.
            /// </summary>
            DWMWINDOWMAXIMIZEDCHANGE = 0x0321,
            /// <summary>
            /// Sent to request extended title bar information. A window receives this message through its WindowProc function.
            /// </summary>
            GETTITLEBARINFOEX = 0x033F,
            HANDHELDFIRST = 0x0358,
            HANDHELDLAST = 0x035F,
            AFXFIRST = 0x0360,
            AFXLAST = 0x037F,
            PENWINFIRST = 0x0380,
            PENWINLAST = 0x038F,
            /// <summary>
            /// The WM_APP constant is used by applications to help define private messages, usually of the form WM_APP+X, where X is an integer value.
            /// </summary>
            APP = 0x8000,
            /// <summary>
            /// The WM_USER constant is used by applications to help define private messages for use by private window classes, usually of the form WM_USER+X, where X is an integer value.
            /// </summary>
            USER = 0x0400,
            /// <summary>
            /// An application sends the WM_CPL_LAUNCH message to Windows Control Panel to request that a Control Panel application be started.
            /// </summary>
            CPL_LAUNCH = USER + 0x1000,
            /// <summary>
            /// The WM_CPL_LAUNCHED message is sent when a Control Panel application, started by the WM_CPL_LAUNCH message, has closed. The WM_CPL_LAUNCHED message is sent to the window identified by the wParam parameter of the WM_CPL_LAUNCH message that started the application.
            /// </summary>
            CPL_LAUNCHED = USER + 0x1001,
            /// <summary>
            /// WM_SYSTIMER is a well-known yet still undocumented message. Windows uses WM_SYSTIMER for internal actions like scrolling.
            /// </summary>
            SYSTIMER = 0x118,
            /// <summary>
            /// The accessibility state has changed.
            /// </summary>
            HSHELL_ACCESSIBILITYSTATE = 11,
            /// <summary>
            /// The shell should activate its main window.
            /// </summary>
            HSHELL_ACTIVATESHELLWINDOW = 3,
            /// <summary>
            /// The user completed an input event (for example, pressed an application command button on the mouse or an application command key on the keyboard), and the application did not handle the WM_APPCOMMAND message generated by that input.
            /// If the Shell procedure handles the WM_COMMAND message, it should not call CallNextHookEx. See the Return Value section for more information.
            /// </summary>
            HSHELL_APPCOMMAND = 12,
            /// <summary>
            /// A window is being minimized or maximized. The system needs the coordinates of the minimized rectangle for the window.
            /// </summary>
            HSHELL_GETMINRECT = 5,
            /// <summary>
            /// Keyboard language was changed or a new keyboard layout was loaded.
            /// </summary>
            HSHELL_LANGUAGE = 8,
            /// <summary>
            /// The title of a window in the task bar has been redrawn.
            /// </summary>
            HSHELL_REDRAW = 6,
            /// <summary>
            /// The user has selected the task list. A shell application that provides a task list should return TRUE to prevent Windows from starting its task list.
            /// </summary>
            HSHELL_TASKMAN = 7,
            /// <summary>
            /// A top-level, unowned window has been created. The window exists when the system calls this hook.
            /// </summary>
            HSHELL_WINDOWCREATED = 1,
            /// <summary>
            /// A top-level, unowned window is about to be destroyed. The window still exists when the system calls this hook.
            /// </summary>
            HSHELL_WINDOWDESTROYED = 2,
            /// <summary>
            /// The activation has changed to a different top-level, unowned window.
            /// </summary>
            HSHELL_WINDOWACTIVATED = 4,
            /// <summary>
            /// A top-level window is being replaced. The window exists when the system calls this hook.
            /// </summary>
            HSHELL_WINDOWREPLACED = 13
        }
        #endregion
        public enum WindowTypes
        {
            Window,
            Button,
            Combobox,
            Edit,
            ListBox,
            ScrollBar,
            Static
        }
        /// <summary>
        /// Creates an invisible borderless window
        /// </summary>
        public static IntPtr CreateWindow(WindowTypes type,WndProc CallBack)
        {
            if (type == WindowTypes.Window) { return CreateWindow(Guid.NewGuid().ToString(), IntPtr.Zero, CallBack, WindowStyles.WS_CAPTION |WindowStyles.WS_THICKFRAME | WindowStyles.WS_SYSMENU | WindowStyles.WS_MAXIMIZEBOX | WindowStyles.WS_MINIMIZEBOX, WindowStylesEx.WS_EX_CONTEXTHELP); }
            return CreateWindow(type.ToString(), Process.GetCurrentProcess().MainWindowHandle, CallBack, 0, WindowStylesEx.WS_EX_CLIENTEDGE);
        }
        public static IntPtr CreateWindow(WindowTypes type,WindowStyles Style, WndProc CallBack)
        {
            if (type == WindowTypes.Window) { return CreateWindow(Guid.NewGuid().ToString(), IntPtr.Zero, CallBack, WindowStyles.WS_CAPTION | WindowStyles.WS_SYSMENU | WindowStyles.WS_MAXIMIZEBOX ); }
            return CreateWindow(type.ToString(), Process.GetCurrentProcess().MainWindowHandle, CallBack, Style, WindowStylesEx.WS_EX_CLIENTEDGE);
        }
        
        public static IntPtr CreateWindow(WindowTypes type, WindowStyles Style,WindowStylesEx ExStyle, WndProc CallBack)
        {
            if (type == WindowTypes.Window) { return CreateWindow(Guid.NewGuid().ToString(), IntPtr.Zero, CallBack, WindowStyles.WS_CAPTION | WindowStyles.WS_SYSMENU | WindowStyles.WS_MAXIMIZEBOX, ExStyle); }
            return CreateWindow(type.ToString(), Process.GetCurrentProcess().MainWindowHandle, CallBack, Style, ExStyle);
        }
            public static class Win32ControlType
            {
                public static string Button = "Button";
                public static string ComboBox = "ComboBox";     //The class for a combo box.
                public static string Edit = "Edit";         //The class for an edit control.
                public static string ListBox = "ListBox";       //The class for a list box.
                public static string ScrollBar = "ScrollBar";   //The class for a scroll bar.
                public static string Static = "Static"; //The class for a static control.
                //public static string Custom = "MyWindow"; //Creates a new custom window
            }
            static IntPtr CreateWindow(string class_name, IntPtr hWndParent, WndProc CallBack, WindowStyles Style, WindowStylesEx ExStyle = WindowStylesEx.WS_EX_CLIENTEDGE) 
            { 
                IntPtr hWnd;
                if (class_name == null) throw new System.Exception("class_name is null");
                if (class_name == String.Empty) throw new System.Exception("class_name is empty");
                var n = typeof(Win32ControlType).GetFields(BindingFlags.Static | BindingFlags.Public);
                for (int i = 0; i < n.Length;i++)
                {
                    if (n[i].GetValue(null).ToString() == class_name) { goto Create;}
                }
                WNDCLASS wc = new WNDCLASS();
                wc.style = ClassStyles.HorizontalRedraw | ClassStyles.VerticalRedraw;
                wc.lpfnWndProc = System.Runtime.InteropServices.Marshal.GetFunctionPointerForDelegate(CallBack);
                wc.cbClsExtra = 0;
                wc.cbWndExtra = 0;
                wc.hInstance = Process.GetCurrentProcess().Handle;
                wc.hIcon = LoadIcon(Process.GetCurrentProcess().Handle, "IDI_APPLICATION");
                wc.hCursor = LoadCursor(IntPtr.Zero, 32512);
                wc.hbrBackground = new IntPtr(6);
                wc.lpszMenuName = "Menu";
                wc.lpszClassName = class_name;
                UInt16 class_atom = RegisterClassW(ref wc);
                if (class_atom == 0) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            
                // Create window
                Create:
                hWnd = CreateWindowExW(
                    (uint)ExStyle,
                    class_name,
                    String.Empty,
                    (uint)Style,
                    0,
                    0,
                    0,
                    0,
                    hWndParent,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero
                );
                if (hWnd == IntPtr.Zero) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                return hWnd;
            }
        
    }
    public class Win32CheckBox : Win32Button
    {
        public Win32CheckBox() : base()
        {
            base.Style = WinAPI.WindowStyles.BS_CHECKBOX;
            base.Click += Win32CheckBox_Click;
        }
        void Win32CheckBox_Click(object sender, MouseEventArgs e)
        {
            Checked = !Checked;
        }
        int BM_GETCHECK = 0xF0;
        int BM_SETCHECK = 0xF1;
        public enum CheckedState
        { 
            CHECKED = 1,
            INDETERMINATE = 2,
            UNCHECKED = 0
        }   
        public bool? Checked
        {
            get 
            {
                var s = SendMessage(BM_GETCHECK, 0, 0).ToInt64();
                return Convert.ToBoolean(s);
            }
            set 
            { 
                if (value==true)
                {
                    SendMessage(BM_SETCHECK, (int)CheckedState.CHECKED, 0);
                }
                if (value==false)
                {
                    SendMessage(BM_SETCHECK, (int)CheckedState.UNCHECKED, 0);
                }
                if (value==null)
                {
                    SendMessage(BM_SETCHECK, (int)CheckedState.INDETERMINATE, 0);
                }
            }
        }
    }
    public class Win32Label : Win32Window
    {
        public Win32Label() : base(IntPtr.Zero)
        {
            var Wait = new ManualResetEvent(false);
            new Thread(() =>
            {
                base.hWnd = WinAPI.CreateWindow(WinAPI.WindowTypes.Static, base.WindowProcedure);
                Wait.Set();
                base.MessageLoop();
                base.Destroy();
            }).Start();
            Wait.WaitOne();
        }
    }
    public class Win32ListBox: Win32Window
    {
        public Win32ListBox() : base(IntPtr.Zero)
        {
            var Wait = new ManualResetEvent(false);
            new Thread(() =>
            {
                base.hWnd = WinAPI.CreateWindow(WinAPI.WindowTypes.ListBox, WinAPI.WindowStyles.LBS_STANDARD, base.WindowProcedure);
                MouseScroll += Win32ListBox_MouseScroll;
                MouseDown += Win32ListBox_MouseDown;
                KeyDown += Win32ListBox_KeyDown;
                Wait.Set();
                base.MessageLoop();
                base.Destroy();
            }).Start();
            Wait.WaitOne();
        }
        void Win32ListBox_KeyDown(object sender, KeyEventArgs e)
        {
            CheckChange();
        }
        void Win32ListBox_MouseDown(object sender, MouseEventArgs e)
        {
            CheckChange();
        }
        void Win32ListBox_MouseScroll(object sender, MouseEventArgs e)
        {
            if (e.Delta>0)
            {
                if (SelectedItem != 0)
                {
                    SelectedItem--;
                }
            }
            else
            {
                SelectedItem++;
            }
        }
        int LB_ADDSTRING = 0x0180;
        int LB_GETCURSEL = 0x0186;
        int LB_GETSEL = 0x0187;
        int LB_GETCOUNT = 0x018B;
        int LB_GETTEXT = 0x0189;
        int LB_GETITEMDATA=0x0199;
        int LB_SETITEMDATA = 0x019A;
        int LB_DELETESTRING = 0x0182;
        public delegate void _selection(Win32ListBox instance,int NewIndex,string ItemString,IntPtr ItemData);
        public event _selection SelectedItemChanged=delegate{};
        public delegate void _itemadd(Win32ListBox instance, string ItemAdded);
        public event _itemadd ItemAdded = delegate { };
        public delegate void _itemremove(Win32ListBox instance, string ItemRemoved);
        public event _itemremove ItemRemoved = delegate { };
        int lastindex = -1;
        void CheckChange()
        {
            if (lastindex!=SelectedItem)
            {
                lastindex = SelectedItem;
                SelectedItemChanged(this, lastindex, ItemString(lastindex),ItemData(lastindex));
            }
        }
        public int SelectedItem
        {
            get 
            {
                for (int i = 0; i < ItemCount; i++)
                {
                    if (SendMessage(LB_GETSEL, i, 0).ToInt32() != 0) { return i; }
                }
                return -1;
            }
            set
            {
                SendMessage(LB_GETCURSEL, value, 0);
                CheckChange();
            }
        }
        public int ItemCount
        {
            get
            {
                return SendMessage(LB_GETCOUNT, 0, 0).ToInt32();
            }
            private set { }
        }
        public string ItemString(int index)
        {
            StringBuilder text=new StringBuilder();
            SendMessage(this.hWnd, (uint)LB_GETTEXT, index,text);
            return text.ToString();
        }
        public void SetItemData(int index,IntPtr Data)
        {
            SendMessage(this.hWnd,LB_SETITEMDATA, new IntPtr(index), Data);
        }
        public IntPtr ItemData(int index)
        {
            return SendMessage(LB_GETITEMDATA, index, 0);
        }
        public void AddItem(string ItemText)
        {
            AddItem(ItemText, IntPtr.Zero);
            ItemAdded(this, ItemText);
        }
        public void AddItem(string ItemText,IntPtr Data)
        {
            var position = Marshal.StringToHGlobalAuto(ItemText);
            SendMessage(this.hWnd, LB_ADDSTRING, IntPtr.Zero, position);
            SetItemData(ItemCount - 1, Data);
        }
        public void RemoveItem(int index)
        {
            string item=ItemString(index);
            SendMessage(LB_DELETESTRING, index, 0);
            ItemRemoved(this, item);
        }
    }
    public class Win32TextBox: Win32Window
    {
        public Win32TextBox() : base(IntPtr.Zero)
        {
            var Wait = new ManualResetEvent(false);
            new Thread(() =>
            {
                base.hWnd = WinAPI.CreateWindow(WinAPI.WindowTypes.Edit,WinAPI.WindowStyles.ES_MULTILINE | WinAPI.WindowStyles.ES_WANTRETURN |WinAPI.WindowStyles.ES_AUTOVSCROLL | WinAPI.WindowStyles.ES_LEFT,base.WindowProcedure);
                Wait.Set();
                base.MessageLoop();
                base.Destroy();
            }).Start();
            Wait.WaitOne();
        }
    }
    public class Win32Button : Win32Window
    {
        public Win32Button() : base(IntPtr.Zero)
        {
            var Wait = new ManualResetEvent(false);
            new Thread(() =>
            {
                base.hWnd = WinAPI.CreateWindow(WinAPI.WindowTypes.Button, base.WindowProcedure);
                Wait.Set();
                base.MessageLoop();
                base.Destroy();
            }).Start();
            Wait.WaitOne();
        }
       
    }
    /// <summary>
    /// A wrapper for a native win32 window
    /// </summary>
    /// 
    public class Win32Window
    {
        public IntPtr hWnd;
        
        /// <summary>
        /// Creates a new Win32Window instance from existing window.
        /// </summary>
        /// <param name="hWnd"></param>
        public Win32Window(IntPtr hWnd)
        {
            this.hWnd = new IntPtr(hWnd.ToInt32());
        }
        public Win32Window()
        {
            var Wait = new ManualResetEvent(false);
            new Thread(() =>
            {
                this.hWnd = WinAPI.CreateWindow(WinAPI.WindowTypes.Window,WindowProcedure);
                this.Visible = true;
                this.Width = 500;
                this.Height = 500;
                Wait.Set();
                MessageLoop();
                Destroy();
            }).Start();
            Wait.WaitOne();
        }
        
        public void AddControl(Win32Window Child)
        {
            WinAPI.WindowStyles tempstyle = Child.Style |= WinAPI.WindowStyles.WS_CHILD | WinAPI.WindowStyles.WS_TABSTOP;
            tempstyle &= ~WinAPI.WindowStyles.WS_TILED;
            tempstyle &= ~WinAPI.WindowStyles.WS_TILEDWINDOW;
            Child.Style = tempstyle;
            Child.Parent = this;
            Child.Visible = true;
            Child.Refresh();
        }
        public IntPtr WindowProcedure(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
        {
            return WinAPI.DefWindowProcW(hWnd, msg, wParam, lParam);
        }
        /*
        public WinAPI.WndProc WindowProcedureDelegate
        {
            get
            {
                IntPtr Location = GetWindowLongPtr(this.hWnd, (int)GWL.GWL_WNDPROC);
                if (Location == IntPtr.Zero) { return null; }
                try
                {
                    var test = (WinAPI.WndProc)Marshal.GetDelegateForFunctionPointer(Location, typeof(WinAPI.WndProc));
                    return test;
                }
                catch
                {
                    return null;
                }
            }
            set
            {
                SetWindowLongPtr(this.hWnd, (int)GWL.GWL_WNDPROC, Marshal.GetFunctionPointerForDelegate(value));
            }
        }
        */
       
        public Icon Icon
        {
            get
            {
                IntPtr IconLocation = GetClassLongPtr(this.hWnd, (int)GCLP.HICON);
                if (IconLocation == IntPtr.Zero) { return null; }
                return Icon.FromHandle(IconLocation);
            }
            set
            {
                const int GCL_HICON = -14;
                const int GCL_HICONSM = -34;
                SendMessage((int)WinAPI.WM.SETICON, 1, value.Handle.ToInt32());
                SendMessage((int)WinAPI.WM.SETICON, 0, value.Handle.ToInt32());
                SetClassLong(this, GCL_HICON, value.Handle);
                SetClassLong(this, GCL_HICONSM, value.Handle);
            }
        }
        public Font Font
        {
            get
            {
                return Font.FromHfont(SendMessage((int)WinAPI.WM.GETFONT, 0, 0));
            }
            set
            {
                SendMessage((int)WinAPI.WM.SETFONT, value.ToHfont().ToInt32(), 1).ToInt64();
            }
        }
        public WinAPI.WindowStyles Style
        {
            get 
            {
                return (WinAPI.WindowStyles)GetWindowLongPtr(hWnd, (int)GWL.GWL_STYLE).ToInt64();
            }
            set 
            {
                SetWindowLongPtr(this.hWnd, (int)GWL.GWL_STYLE, new IntPtr((long)value));
            }
        }
        public WinAPI.WindowStylesEx ExtendedStyle
        {
            get
            {
                return (WinAPI.WindowStylesEx)GetWindowLongPtr(hWnd, (int)GWL.GWL_EXSTYLE).ToInt64();
            }
            set
            {
                SetWindowLongPtr(this.hWnd, (int)GWL.GWL_EXSTYLE, new IntPtr((long)value));
            }
        }
        public delegate void WindowsMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
        public event WindowsMessage WndProc = delegate { };
        public event MouseEventHandler MouseDown = delegate { };
        public event MouseEventHandler MouseUp = delegate { };
        public event MouseEventHandler MouseMove = delegate { };
        public event MouseEventHandler MouseScroll = delegate { };
        public event MouseEventHandler Click = delegate { };
        public event KeyEventHandler KeyDown = delegate { };
        public event KeyEventHandler KeyUp = delegate { };
        public event KeyEventHandler KeyPress = delegate { };
        MouseButtons LastPressedButton;
        MouseEventArgs CreateMouseEvent(MSG msg)
        {
            uint xy = unchecked(IntPtr.Size == 8 ? (uint)msg.lParam.ToInt64() : (uint)msg.lParam.ToInt32());
            int x = unchecked((short)xy);
            int y = unchecked((short)(xy >> 16));
            int button=msg.wParam.ToInt32();
            int delta = 0;
            int clicks = 1;
            MouseButtons Button;
            //mousewheel
            if (msg.message == 0x20a)
            {
                uint buttondelta = unchecked(IntPtr.Size == 8 ? (uint)msg.wParam.ToInt64() : (uint)msg.wParam.ToInt32());
                button = unchecked((short)buttondelta);
                delta = unchecked((short)(buttondelta >> 16));
            }
            if (msg.message == 0x0209 || msg.message == 0x0203 || msg.message == 0x0206 || msg.message == 0x020D)
            {
                clicks = 2;
            }
            switch (button)
            {
                case 0x0001:
                    Button=MouseButtons.Left;break;
                case 0x0010:
                    Button=MouseButtons.Middle;break;
                case 0x0002:
                    Button=MouseButtons.Right;break;
                case 0x0020:
                    Button=MouseButtons.XButton1;break;
                case 0x0040:
                    Button=MouseButtons.XButton2;break;
                default:
                    Button=MouseButtons.None;break;
            }
            return new MouseEventArgs(Button, clicks, x, y, delta);
        }
        KeyEventArgs CreateKeyEvent(MSG msg)
        {
            return new KeyEventArgs((Keys)msg.wParam.ToInt32());
        }
        public void MessageLoop()
        {
            MSG msg;
            while (GetMessage(out msg, hWnd, 0, 0) != 0)
            {
                WndProc(this.hWnd, msg.message, msg.wParam, msg.lParam);
                TranslateMessage(ref msg);
                DispatchMessage(ref msg);
               
                switch((WinAPI.WM)msg.message)
                {
                    case WinAPI.WM.RBUTTONDOWN:
                    case WinAPI.WM.XBUTTONDOWN:
                    case WinAPI.WM.MBUTTONDOWN:
                    case WinAPI.WM.LBUTTONDOWN:
                    case WinAPI.WM.RBUTTONDBLCLK:
                    case WinAPI.WM.LBUTTONDBLCLK:
                    case WinAPI.WM.XBUTTONDBLCLK:
                    case WinAPI.WM.MBUTTONDBLCLK:
                    {
                        var arg=CreateMouseEvent(msg);
                        MouseDown(this, arg);
                        LastPressedButton = arg.Button; break;
                    }
                    case WinAPI.WM.LBUTTONUP:
                    case WinAPI.WM.RBUTTONUP:
                    case WinAPI.WM.XBUTTONUP:
                    case WinAPI.WM.MBUTTONUP:
                    {
                        MouseUp(this, CreateMouseEvent(msg));
                        if (LastPressedButton==MouseButtons.Left)
                        {
                            var arg=CreateMouseEvent(msg);
                            var rectangle=(Rectangle)this.Position;
                            rectangle.X = 0;
                            rectangle.Y = 0;
                            if (rectangle.Contains(new Point(arg.X, arg.Y)))
                            {
                                Click(this, arg);
                            }
                        }
                        break;
                    }
                    case WinAPI.WM.MOUSEHWHEEL:
                    {
                        MouseScroll(this, CreateMouseEvent(msg)); break;
                    }
                    case WinAPI.WM.MOUSEMOVE:
                    {
                        MouseMove(this, CreateMouseEvent(msg)); break;
                    }
                    case WinAPI.WM.KEYDOWN:
                    {
                        KeyDown(this, CreateKeyEvent(msg)); break;
                    }
                    case WinAPI.WM.KEYUP:
                    {
                        KeyUp(this, CreateKeyEvent(msg)); break;
                    }
                    case WinAPI.WM.CHAR:
                    {
                        KeyPress(this, CreateKeyEvent(msg)); break;
                    }
                }
            }
        }
       
        
        public IntPtr SendMessage(Message Msg)
        {
            return SendMessage(this.hWnd, Msg.Msg, Msg.WParam, Msg.LParam);
        }
        public IntPtr SendMessage(int Msg,int WParam,int Lparam)
        {
            return SendMessage(this.hWnd, Msg, new IntPtr(WParam), new IntPtr(Lparam));
        }
        public enum WindowState
        {
            Minimized,
            Maximized
        }
        public WindowState State
        {
            get 
            {
                WINDOWPLACEMENT place = new WINDOWPLACEMENT();
                
                GetWindowPlacement(this.hWnd, ref place);
                if (place.showCmd == 9||place.showCmd==1) { return WindowState.Maximized; }
                else return WindowState.Minimized;
            }
            set 
            {
                if (value == WindowState.Minimized) { ShowWindow(hWnd, 6); }
                if (value == WindowState.Maximized) { ShowWindow(hWnd, 9); }
            }
        }
        public string Title
        {
            get
            {
                StringBuilder sb = new StringBuilder(GetWindowTextLength(hWnd) + 1);
                GetWindowText(hWnd, sb, sb.Capacity);
                return sb.ToString();
            }
            set
            {
                SetWindowText(hWnd, value);
                UpdateWindow(hWnd);
            }
        }
        public string Text
        {
            get
            {
                StringBuilder data = new StringBuilder(32768);
                SendMessage(hWnd, WM_GETTEXT, data.Capacity, data);
                return data.ToString();
            }
            set
            {
                SendMessage(hWnd, WM_SETTEXT, 0, value);
            }
        }
        // I hate recursive programming haha
        static Win32Window everycontrol(Win32Window cursor,Func<Win32Window,bool> function)
        {
            var Children=cursor.Children;
            if (function(cursor) == true) { return cursor; }
            foreach (Win32Window child in Children)
            {
                if (everycontrol(child, function) != null) { return everycontrol(child, function); }
            }
            return null;
        }
        
        public static Win32Window FromWindowWhere(Func<Win32Window,bool> function)
        {
            return everycontrol(Win32Window.FromDesktop(), function);
        }
        public static Win32Window FromDesktop()
        {
            return new Win32Window(GetDesktopWindow());
        }
        public static Win32Window FromPoint(Point pos)
        {
            return new Win32Window(WindowFromPoint(pos));
        }
        public static Win32Window FromProcessName(string ProcessName)
        {
            if (Process.GetProcessesByName(ProcessName).Length==0){throw new Exception("No Process with name "+ProcessName+" found");}
            Process MainWnd = Process.GetProcessesByName(ProcessName)[0];
            return FromProcess(MainWnd);
        }
        public static Win32Window FromProcess(Process Process)
        {
            var Handle = Process.MainWindowHandle;
            if (Handle == IntPtr.Zero) { throw new Exception("Process does not have a Mainwindow"); }
            return new Win32Window(Handle);
        }
        public string ClassName
        {
            get
            {
                if (hWnd.ToInt64() == 0) { return String.Empty; }
                int length = 64;
                while (true)
                {
                    StringBuilder sb = new StringBuilder(length);
                    int OK = GetClassName(hWnd, sb, sb.Capacity);
                    if (OK == 0) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                    if (sb.Length != length - 1)
                    {
                        return sb.ToString();
                    }
                    length *= 2;
                }
            }
        }
        public String ModuleFileName
        {
            get
            {
                StringBuilder fileName = new StringBuilder(2000);
                GetWindowModuleFileName(hWnd, fileName, 2000);
                //if (fileName.Length == 0) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                return fileName.ToString();
            }
            private set{ }
        }
        delegate bool EnumedWindow(IntPtr handleWindow, ArrayList handles);
        List<Win32Window> GetAllWindows()
        {
            var windowHandles = new ArrayList();
            EnumedWindow callBackPtr = GetWindowHandle;
            EnumChildWindows(hWnd, callBackPtr, windowHandles);
            var tmp=new List<IntPtr>(windowHandles.ToArray(typeof(IntPtr)) as IntPtr[]);
            List<Win32Window> returnee=new List<Win32Window>();
            for (int i=0;i<tmp.Count;i++)
            {
                returnee.Add(new Win32Window(tmp[i]));
            }
            return returnee;
        }
        private static bool GetWindowHandle(IntPtr windowHandle, ArrayList windowHandles)
        {
            windowHandles.Add(windowHandle);
            return true;
        }
        
        public List<Win32Window> Children
        {
            get
            {
                return GetAllWindows();
            }
            private set { }
        }
        Graphics _Graphics;
        public Graphics Graphics
        {
            get 
            {
                if (_Graphics == null)
                {
                    var Hdc = GetDC(this.hWnd);
                    if (Hdc == IntPtr.Zero) { return null; }
                    _Graphics = Graphics.FromHdc(Hdc);
                }
                return _Graphics;
            }
            private set { }
        }
        /// <summary>
        /// Be sure to set Style to WS_CHILD for ordinary Win32Controls or call .Add
        /// </summary>
        public Win32Window Parent
        {
            get
            {
                IntPtr parent_hWnd = GetParent(this.hWnd);
                if (parent_hWnd==IntPtr.Zero)
                {
                    int err = Marshal.GetLastWin32Error();
                    if (err == 0) { return new Win32Window(IntPtr.Zero); }//DESKTOP 
                    throw new Win32Exception(err);
                }
                return new Win32Window(parent_hWnd);
            }
            set
            {
                IntPtr newparent_hWnd = SetParent(this.hWnd, value.hWnd);
                if (newparent_hWnd == IntPtr.Zero)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                value.Refresh();
            }
        }
        public void Refresh()
        {
            SendMessage((int)WinAPI.WM.PAINT, 0, 0);
            UpdateWindow(hWnd);
        }
        public Bitmap Image
        {
            get
            {
                try
                {
                    if (Position.Width == Position.Height && Position.Height == 0) { return null; }
                    Bitmap bmp = new Bitmap(Position.Width, Position.Height, PixelFormat.Format32bppArgb);
                    Graphics gfxBmp = Graphics.FromImage(bmp);
                    IntPtr hdcBitmap = gfxBmp.GetHdc();
                    PrintWindow(hWnd, hdcBitmap, 0);
                    gfxBmp.ReleaseHdc(hdcBitmap);
                    gfxBmp.Dispose();
                    return bmp;
                }
                catch(Exception e)
                {
                    Debug.WriteLine(e);
                    return null;
                }
            }
            private set { }
        }
        public void EnableVisuals()
        {
            SetWindowTheme(this.hWnd, "explorer", "");
        }
        public bool TopMost
        {
            get
            {
                if ((GetWindowLong(hWnd, -20) & 0x00000008L) != 0)
                {
                    return true;
                }
                return false;
            }
            set
            {
                if (value==true)
                {
                    SetWindowPos(hWnd, new IntPtr(-1), 0, 0, 0, 0, 3);
                    BringWindowToTop(hWnd);
                }
                else
                {
                    SetWindowPos(hWnd, new IntPtr(-2), 0, 0, 0, 0, 3);
                }
            }
        }
        public bool Visible
        {
            get
            {
                return IsWindowVisible(hWnd);
            }
            set
            {
                if (value == false)
                {
                    ShowWindow(this.hWnd, 0);
                }
                else
                {
                    ShowWindow(this.hWnd, 9);
                }
            }
        }
        public int Width
        {
            get { return Position.Width; }
            set { var tmp = Position; tmp.Width = value; Position = tmp; }
        }
        public int Height
        {
            get { return Position.Height; }
            set { var tmp = Position; tmp.Height = value; Position = tmp; }
        }
        public int Pos_X
        {
            get { return Position.X; }
            set { var tmp = Position; tmp.X = value; Position = tmp; }
        }
        public int Pos_Y
        {
            get { return Position.Y; }
            set { var tmp = Position; tmp.Y = value; Position = tmp; }
        }
        public RECT Position
        {
            get
            {
                WINDOWPLACEMENT wp = new WINDOWPLACEMENT();
                wp.length = Marshal.SizeOf(wp);
                GetWindowPlacement(hWnd, ref wp);
                return wp.rcNormalPosition;
            }
            set
            {
                WINDOWPLACEMENT wp = new WINDOWPLACEMENT();
                wp.length = Marshal.SizeOf(wp);
                GetWindowPlacement(hWnd, ref wp);
                wp.rcNormalPosition = value;
                SetWindowPlacement(hWnd, ref wp);
            }
        }
        Process _prc;
        public Process Process
        {
            get
            {
                if (_prc == null)
                {
                    int pid;
                    GetWindowThreadProcessId(hWnd, out pid);
                    _prc=Process.GetProcessById(pid);
                }
                return _prc;
            }
        }
        public ProcessThread GUIthread
        {
            get
            {
                int pid;
                int tid = GetWindowThreadProcessId(hWnd, out pid);
                var Threads=Process.GetProcessById(pid).Threads;
                foreach (ProcessThread t in Threads)
                {
                    if (t.Id == tid) return t;
                }
                throw new Exception("Thread not found");
            }
        }
        public override string ToString()
        {
            return "Window: " + Process.ProcessName + " Title=" + Title + " " + "X: " + Position.X + ",Y: " + Position.Y;
            //return hWnd.ToString();
        }
        public void Destroy()
        {
            if (this.Process.Id == Process.GetCurrentProcess().Id)
            {
                if (!DestroyWindow(this.hWnd))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            else
            {
                SendMessage((int)WinAPI.WM.CLOSE, 0, 0);    //closes
                SendMessage((int)WinAPI.WM.DESTROY, 0, 0);  //kills no race
            }
        }
        public static implicit operator IntPtr(Win32Window instance)
        {
            return instance.hWnd;
        }
        #region PInvoke Declarations
        [DllImport("user32.dll")]
        static extern bool UpdateWindow(IntPtr hWnd);
        [DllImport("user32")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EnumChildWindows(IntPtr window, EnumedWindow callback, ArrayList lParam);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool DestroyWindow(IntPtr hwnd);
        [DllImport("user32.dll", SetLastError = true)]
        static extern int GetWindowLong(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll")]
        static extern IntPtr DispatchMessage([In] ref MSG lpmsg);
        [DllImport("user32.dll")]
        static extern bool TranslateMessage([In] ref MSG lpMsg);
        [DllImport("user32.dll")]
        static extern sbyte GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);
        [DllImport("user32.dll", SetLastError = true)]
        static extern IntPtr SetParent(IntPtr hWndChild, IntPtr hWndNewParent);
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        static extern uint GetWindowModuleFileName(IntPtr hwnd,StringBuilder lpszFileName, uint cchFileNameMax);
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        private static extern int GetWindowText(IntPtr hWnd, [Out] StringBuilder lpString, int nMaxCount);
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        private static extern int GetWindowTextLength(IntPtr hWnd);
        [DllImport("user32.dll")]
        static extern bool SetWindowText(IntPtr hWnd, string lpString);
        [DllImport("user32.dll")]
        private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")]
        private static extern bool IsWindowEnabled(IntPtr hWnd);
        [DllImport("user32.dll")]
        private static extern bool EnableWindow(IntPtr hWnd, bool bEnable);
        [DllImport("user32.dll", EntryPoint = "GetWindowLong")]
        private static extern IntPtr GetWindowLongPtr32(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")]
        private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);
        static IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex)
        {
            if (IntPtr.Size == 8)
                return GetWindowLongPtr64(hWnd, nIndex);
            else
                return GetWindowLongPtr32(hWnd, nIndex);
        }
        static IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong)
        {
            if (IntPtr.Size == 8)
                return SetWindowLongPtr64(hWnd, nIndex, dwNewLong);
            else
                return new IntPtr(SetWindowLong32(hWnd, nIndex, dwNewLong.ToInt32()));
        }
        public static IntPtr SetClassLong(IntPtr hWnd, int nIndex, IntPtr dwNewLong)
        {
            if (IntPtr.Size > 4)
                return SetClassLongPtr64(hWnd, nIndex, dwNewLong);
            else
                return new IntPtr(SetClassLongPtr32(hWnd, nIndex, unchecked((uint)dwNewLong.ToInt32())));
        }
        [DllImport("user32.dll", EntryPoint = "SetClassLong", SetLastError = true)]
        public static extern uint SetClassLongPtr32(IntPtr hWnd, int nIndex, uint dwNewLong);
        [DllImport("user32.dll", EntryPoint = "SetClassLongPtr", SetLastError = true)]
        public static extern IntPtr SetClassLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);
        public static IntPtr GetClassLongPtr(IntPtr hWnd, int nIndex)
        {
            if (IntPtr.Size > 4)
                return GetClassLongPtr64(hWnd, nIndex);
            else
                return new IntPtr(GetClassLongPtr32(hWnd, nIndex));
        }
        [DllImport("user32.dll", EntryPoint = "GetClassLong", SetLastError = true)]
        public static extern uint GetClassLongPtr32(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll", EntryPoint = "GetClassLongPtr", SetLastError = true)]
        public static extern IntPtr GetClassLongPtr64(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll", EntryPoint = "SetWindowLong", SetLastError = true)]
        private static extern int SetWindowLong32(IntPtr hWnd, int nIndex, int dwNewLong);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr", SetLastError = true)]
        private static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);
        private enum GCLP:int
        {
            ATOM=-32,
            HICON = -14,
            HICONSM = -34
        }
        private enum GWL : int
        {
            GWL_WNDPROC = (-4),
            GWL_HINSTANCE = (-6),
            GWL_HWNDPARENT = (-8),
            GWL_STYLE = (-16),
            GWL_EXSTYLE = (-20),
            GWL_USERDATA = (-21),
            GWL_ID = (-12)
        }
        [Flags]
        public enum WindowStyles : uint
        {
            WS_OVERLAPPED = 0x00000000,
            WS_POPUP = 0x80000000,
            WS_CHILD = 0x40000000,
            WS_MINIMIZE = 0x20000000,
            WS_VISIBLE = 0x10000000,
            WS_DISABLED = 0x08000000,
            WS_CLIPSIBLINGS = 0x04000000,
            WS_CLIPCHILDREN = 0x02000000,
            WS_MAXIMIZE = 0x01000000,
            WS_BORDER = 0x00800000,
            WS_DLGFRAME = 0x00400000,
            WS_VSCROLL = 0x00200000,
            WS_HSCROLL = 0x00100000,
            WS_SYSMENU = 0x00080000,
            WS_THICKFRAME = 0x00040000,
            WS_GROUP = 0x00020000,
            WS_TABSTOP = 0x00010000,
            WS_MINIMIZEBOX = 0x00020000,
            WS_MAXIMIZEBOX = 0x00010000,
            WS_CAPTION = WS_BORDER | WS_DLGFRAME,
            WS_TILED = WS_OVERLAPPED,
            WS_ICONIC = WS_MINIMIZE,
            WS_SIZEBOX = WS_THICKFRAME,
            WS_TILEDWINDOW = WS_OVERLAPPEDWINDOW,
            WS_OVERLAPPEDWINDOW = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX,
            WS_POPUPWINDOW = WS_POPUP | WS_BORDER | WS_SYSMENU,
            WS_CHILDWINDOW = WS_CHILD,
            BS_RADIOBUTTON=0x00000004,
            BS_CHECKBOX=0x00000002,
            /*
             #define BS_PUSHBUTTON       0x00000000L
             #define BS_DEFPUSHBUTTON    0x00000001L
             #define BS_CHECKBOX         0x00000002L
             #define BS_AUTOCHECKBOX     0x00000003L
             #define 
             #define BS_3STATE           0x00000005L
             #define BS_AUTO3STATE       0x00000006L
             #define BS_GROUPBOX         0x00000007L
             #define BS_USERBUTTON       0x00000008L
             #define BS_AUTORADIOBUTTON  0x00000009L
             #define BS_PUSHBOX          0x0000000AL
             #define BS_OWNERDRAW        0x0000000BL
             #define BS_TYPEMASK         0x0000000FL
             #define BS_LEFTTEXT         0x00000020L
             #if(WINVER >= 0x0400)
             #define BS_TEXT             0x00000000L
             #define BS_ICON             0x00000040L
             #define BS_BITMAP           0x00000080L
             #define BS_LEFT             0x00000100L
             #define BS_RIGHT            0x00000200L
             #define BS_CENTER           0x00000300L
             #define BS_TOP              0x00000400L
             #define BS_BOTTOM           0x00000800L
             #define BS_VCENTER          0x00000C00L
             #define BS_PUSHLIKE         0x00001000L
             #define BS_MULTILINE        0x00002000L
             #define BS_NOTIFY           0x00004000L
             #define BS_FLAT             0x00008000L
             #define BS_RIGHTBUTTON      BS_LEFTTEXT
             */
        }
        [Flags]
        public enum WindowStylesEx : uint
        {
            //Extended Window Styles
            WS_EX_DLGMODALFRAME = 0x00000001,
            WS_EX_NOPARENTNOTIFY = 0x00000004,
            WS_EX_TOPMOST = 0x00000008,
            WS_EX_ACCEPTFILES = 0x00000010,
            WS_EX_TRANSPARENT = 0x00000020,
            //#if(WINVER >= 0x0400)
            WS_EX_MDICHILD = 0x00000040,
            WS_EX_TOOLWINDOW = 0x00000080,
            WS_EX_WINDOWEDGE = 0x00000100,
            WS_EX_CLIENTEDGE = 0x00000200,
            WS_EX_CONTEXTHELP = 0x00000400,
            WS_EX_RIGHT = 0x00001000,
            WS_EX_LEFT = 0x00000000,
            WS_EX_RTLREADING = 0x00002000,
            WS_EX_LTRREADING = 0x00000000,
            WS_EX_LEFTSCROLLBAR = 0x00004000,
            WS_EX_RIGHTSCROLLBAR = 0x00000000,
            WS_EX_CONTROLPARENT = 0x00010000,
            WS_EX_STATICEDGE = 0x00020000,
            WS_EX_APPWINDOW = 0x00040000,
            WS_EX_OVERLAPPEDWINDOW = (WS_EX_WINDOWEDGE | WS_EX_CLIENTEDGE),
            WS_EX_PALETTEWINDOW = (WS_EX_WINDOWEDGE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST),
            //#endif /* WINVER >= 0x0400 */
            //#if(WIN32WINNT >= 0x0500)
            WS_EX_LAYERED = 0x00080000,
            //#endif /* WIN32WINNT >= 0x0500 */
            //#if(WINVER >= 0x0500)
            WS_EX_NOINHERITLAYOUT = 0x00100000, // Disable inheritence of mirroring by children
            WS_EX_LAYOUTRTL = 0x00400000, // Right to left mirroring
            //#endif /* WINVER >= 0x0500 */
            //#if(WIN32WINNT >= 0x0500)
            WS_EX_COMPOSITED = 0x02000000,
            WS_EX_NOACTIVATE = 0x08000000
            //#endif /* WIN32WINNT >= 0x0500 */
        }
        [DllImport("uxtheme.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
        static extern int SetWindowTheme(IntPtr hWnd, String pszSubAppName, String pszSubIdList);
        [DllImport("uxtheme.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
        static extern int SetWindowTheme(IntPtr hWnd, int pszSubAppName, String pszSubIdList);
        [DllImport("uxtheme.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
        static extern int SetWindowTheme(IntPtr hWnd, String pszSubAppName, int pszSubIdList);
        [DllImport("uxtheme.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
        static extern int SetWindowTheme(IntPtr hWnd, int pszSubAppName, int pszSubIdList);
        [DllImport("kernel32.dll")]
        static extern IntPtr OpenThread(uint dwDesiredAccess, bool bInheritHandle, uint dwThreadId);
        [DllImport("kernel32.dll")]
        static extern bool TerminateThread(IntPtr hThread, uint dwExitCode);
        
        [Flags()]
        private enum SetWindowPosFlags : uint
        {
            /// <summary>If the calling thread and the thread that owns the window are attached to different input queues,
            /// the system posts the request to the thread that owns the window. This prevents the calling thread from
            /// blocking its execution while other threads process the request.</summary>
            /// <remarks>SWP_ASYNCWINDOWPOS</remarks>
            AsynchronousWindowPosition = 0x4000,
            /// <summary>Prevents generation of the WM_SYNCPAINT message.</summary>
            /// <remarks>SWP_DEFERERASE</remarks>
            DeferErase = 0x2000,
            /// <summary>Draws a frame (defined in the window's class description) around the window.</summary>
            /// <remarks>SWP_DRAWFRAME</remarks>
            DrawFrame = 0x0020,
            /// <summary>Applies new frame styles set using the SetWindowLong function. Sends a WM_NCCALCSIZE message to
            /// the window, even if the window's size is not being changed. If this flag is not specified, WM_NCCALCSIZE
            /// is sent only when the window's size is being changed.</summary>
            /// <remarks>SWP_FRAMECHANGED</remarks>
            FrameChanged = 0x0020,
            /// <summary>Hides the window.</summary>
            /// <remarks>SWP_HIDEWINDOW</remarks>
            HideWindow = 0x0080,
            /// <summary>Does not activate the window. If this flag is not set, the window is activated and moved to the
            /// top of either the topmost or non-topmost group (depending on the setting of the hWndInsertAfter
            /// parameter).</summary>
            /// <remarks>SWP_NOACTIVATE</remarks>
            DoNotActivate = 0x0010,
            /// <summary>Discards the entire contents of the client area. If this flag is not specified, the valid
            /// contents of the client area are saved and copied back into the client area after the window is sized or
            /// repositioned.</summary>
            /// <remarks>SWP_NOCOPYBITS</remarks>
            DoNotCopyBits = 0x0100,
            /// <summary>Retains the current position (ignores X and Y parameters).</summary>
            /// <remarks>SWP_NOMOVE</remarks>
            IgnoreMove = 0x0002,
            /// <summary>Does not change the owner window's position in the Z order.</summary>
            /// <remarks>SWP_NOOWNERZORDER</remarks>
            DoNotChangeOwnerZOrder = 0x0200,
            /// <summary>Does not redraw changes. If this flag is set, no repainting of any kind occurs. This applies to
            /// the client area, the nonclient area (including the title bar and scroll bars), and any part of the parent
            /// window uncovered as a result of the window being moved. When this flag is set, the application must
            /// explicitly invalidate or redraw any parts of the window and parent window that need redrawing.</summary>
            /// <remarks>SWP_NOREDRAW</remarks>
            DoNotRedraw = 0x0008,
            /// <summary>Same as the SWP_NOOWNERZORDER flag.</summary>
            /// <remarks>SWP_NOREPOSITION</remarks>
            DoNotReposition = 0x0200,
            /// <summary>Prevents the window from receiving the WM_WINDOWPOSCHANGING message.</summary>
            /// <remarks>SWP_NOSENDCHANGING</remarks>
            DoNotSendChangingEvent = 0x0400,
            /// <summary>Retains the current size (ignores the cx and cy parameters).</summary>
            /// <remarks>SWP_NOSIZE</remarks>
            IgnoreResize = 0x0001,
            /// <summary>Retains the current Z order (ignores the hWndInsertAfter parameter).</summary>
            /// <remarks>SWP_NOZORDER</remarks>
            IgnoreZOrder = 0x0004,
            /// <summary>Displays the window.</summary>
            /// <remarks>SWP_SHOWWINDOW</remarks>
            ShowWindow = 0x0040,
        }
        [DllImport("user32.dll")]
        private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
        [DllImport("user32.dll", ExactSpelling = true, CharSet = CharSet.Auto)]
        private static extern IntPtr GetParent(IntPtr hWnd);
        [DllImport("user32.dll")]
        static extern bool IsChild(IntPtr hWndParent, IntPtr hWnd);
        [StructLayout(LayoutKind.Sequential)]
        private struct WINDOWPLACEMENT
        {
            public int length;
            public int flags;
            public int showCmd;
            public POINT ptMinPosition;
            public POINT ptMaxPosition;
            public RECT rcNormalPosition;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct MSG
        {
            public IntPtr hwnd;
            public UInt32 message;
            public IntPtr wParam;
            public IntPtr lParam;
            public UInt32 time;
            public POINT pt;
        }
        [DllImport("user32.dll", SetLastError = true)]
        static extern bool BringWindowToTop(IntPtr hWnd);
        [DllImport("user32.dll")]
        static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT lpwndpl);
        [DllImport("user32.dll")]
        static extern bool SetWindowPlacement(IntPtr hWnd, [In] ref WINDOWPLACEMENT lpwndpl);
        [DllImport("user32.dll")]
        private static extern IntPtr WindowFromPoint(POINT Point);
        [DllImport("user32.dll", SetLastError = true)]
        static extern int GetWindowThreadProcessId(IntPtr hWnd, out int lpdwProcessId);
        [DllImport("user32.dll")]
        static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
        [DllImport("user32.dll")]
        static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("gdi32.dll")]
        static extern IntPtr CreateRectRgn(int nLeftRect, int nTopRect, int nRightRect, int nBottomRect);
        [DllImport("user32.dll")]
        static extern int GetWindowRgn(IntPtr hWnd, IntPtr hRgn);
        [DllImport("user32.dll")]
        static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool bRedraw);
        [DllImport("gdi32.dll")]
        static extern bool BitBlt(IntPtr hObject, int nXDest, int nYDest, int nWidth,
           int nHeight, IntPtr hObjSource, int nXSrc, int nYSrc, int dwRop);
        [DllImport("user32.dll", SetLastError = true)]
        static extern bool PrintWindow(IntPtr hwnd, IntPtr hDC, uint nFlags);
        [DllImport("user32.dll")]
        static extern IntPtr GetWindowDC(IntPtr hWnd);
        [DllImport("user32.dll")]
        static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
        [DllImport("gdi32.dll", ExactSpelling = true, SetLastError = true)]
        static extern IntPtr CreateCompatibleDC(IntPtr hdc);
        [DllImport("gdi32.dll", ExactSpelling = true, SetLastError = true)]
        static extern bool DeleteDC(IntPtr hdc);
        [DllImport("gdi32.dll", ExactSpelling = true, SetLastError = true)]
        static extern IntPtr SelectObject(IntPtr hdc, IntPtr hgdiobj);
        [DllImport("gdi32.dll", ExactSpelling = true, SetLastError = true)]
        static extern bool DeleteObject(IntPtr hObject);
        enum TernaryRasterOperations : uint
        {
            SRCCOPY = 0x00CC0020,
            SRCPAINT = 0x00EE0086,
            SRCAND = 0x008800C6,
            SRCINVERT = 0x00660046,
            SRCERASE = 0x00440328,
            NOTSRCCOPY = 0x00330008,
            NOTSRCERASE = 0x001100A6,
            MERGECOPY = 0x00C000CA,
            MERGEPAINT = 0x00BB0226,
            PATCOPY = 0x00F00021,
            PATPAINT = 0x00FB0A09,
            PATINVERT = 0x005A0049,
            DSTINVERT = 0x00550009,
            BLACKNESS = 0x00000042,
            WHITENESS = 0x00FF0062
        }
        enum GetWindowRegnReturnValues : int
        {
            ERROR = 0,
            NULLREGION = 1,
            SIMPLEREGION = 2,
            COMPLEXREGION = 3
        }
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = false)]
        internal static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = false)]
        internal static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, int wParam, [Out] StringBuilder lParam);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = false)]
        internal static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, int wParam, [MarshalAs(UnmanagedType.LPWStr)] string lParam);
        [DllImport("user32.dll")]
        private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X,
           int Y, int cx, int cy, uint uFlags);
        [DllImport("user32.dll")]
        private static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
        [DllImport("user32.dll", SetLastError = false)]
        static extern IntPtr GetDesktopWindow();
        [DllImport("user32.dll")]
        static extern IntPtr GetDC(IntPtr hWnd);
        private const int WM_CLOSE = 16;
        private const int WM_GETTEXT = 0x000D;
        private const int WM_SETTEXT = 0x000C;
        private enum GetWindow_Cmd
        {
            GW_HWNDFIRST = 0,
            GW_HWNDLAST = 1,
            GW_HWNDNEXT = 2,
            GW_HWNDPREV = 3,
            GW_OWNER = 4,
            GW_CHILD = 5,
            GW_ENABLEDPOPUP = 6
        }
        [DllImport("user32.dll")]
        private static extern bool InvalidateRect(IntPtr hWnd, IntPtr lpRect, bool bErase);
        private enum RDW : uint
        {
            RDW_INVALIDATE = 0x0001,
            RDW_INTERNALPAINT = 0x0002,
            RDW_ERASE = 0x0004,
            RDW_VALIDATE = 0x0008,
            RDW_NOINTERNALPAINT = 0x0010,
            RDW_NOERASE = 0x0020,
            RDW_NOCHILDREN = 0x0040,
            RDW_ALLCHILDREN = 0x0080,
            RDW_UPDATENOW = 0x0100,
            RDW_ERASENOW = 0x0200,
            RDW_FRAME = 0x0400,
            RDW_NOFRAME = 0x0800,
        }
        [DllImport("user32.dll")]
        private static extern bool RedrawWindow(IntPtr hWnd, IntPtr lprcUpdate, IntPtr hrgnUpdate, RDW flags);
        #endregion
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left, Top, Right, Bottom;
        public RECT(int left, int top, int right, int bottom)
        {
            Left = left;
            Top = top;
            Right = right;
            Bottom = bottom;
        }
        public RECT(System.Drawing.Rectangle r) : this(r.Left, r.Top, r.Right, r.Bottom) { }
        public int X
        {
            get { return Left; }
            set { Right -= (Left - value); Left = value; }
        }
        public int Y
        {
            get { return Top; }
            set { Bottom -= (Top - value); Top = value; }
        }
        public int Height
        {
            get { return Bottom - Top; }
            set { Bottom = value + Top; }
        }
        public int Width
        {
            get { return Right - Left; }
            set { Right = value + Left; }
        }
        public System.Drawing.Point Location
        {
            get { return new System.Drawing.Point(Left, Top); }
            set { X = value.X; Y = value.Y; }
        }
        public System.Drawing.Size Size
        {
            get { return new System.Drawing.Size(Width, Height); }
            set { Width = value.Width; Height = value.Height; }
        }
        public static implicit operator System.Drawing.Rectangle(RECT r)
        {
            return new System.Drawing.Rectangle(r.Left, r.Top, r.Width, r.Height);
        }
        public static implicit operator RECT(System.Drawing.Rectangle r)
        {
            return new RECT(r);
        }
        public static bool operator ==(RECT r1, RECT r2)
        {
            return r1.Equals(r2);
        }
        public static bool operator !=(RECT r1, RECT r2)
        {
            return !r1.Equals(r2);
        }
        public bool Equals(RECT r)
        {
            return r.Left == Left && r.Top == Top && r.Right == Right && r.Bottom == Bottom;
        }
        public override bool Equals(object obj)
        {
            if (obj is RECT)
                return Equals((RECT)obj);
            else if (obj is System.Drawing.Rectangle)
                return Equals(new RECT((System.Drawing.Rectangle)obj));
            return false;
        }
        public override int GetHashCode()
        {
            return ((System.Drawing.Rectangle)this).GetHashCode();
        }
        public override string ToString()
        {
            return string.Format(System.Globalization.CultureInfo.CurrentCulture, "{{Left={0},Top={1},Right={2},Bottom={3}}}", Left, Top, Right, Bottom);
        }
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
        public POINT(int x, int y)
        {
            this.X = x;
            this.Y = y;
        }
        public POINT(System.Drawing.Point pt) : this(pt.X, pt.Y) { }
        public static implicit operator System.Drawing.Point(POINT p)
        {
            return new System.Drawing.Point(p.X, p.Y);
        }
        public static implicit operator POINT(System.Drawing.Point p)
        {
            return new POINT(p.X, p.Y);
        }
    }
    
}
'@ -ReferencedAssemblies 'System.Windows.Forms.dll', 'System.Drawing.dll', 'Microsoft.CSharp.dll' , 'System.Xml.Linq.dll', 'System.Xml.dll'

###
#Endregion
###
