BeforeAll {
  . $PSScriptRoot/_TestHelpers.ps1
  $FlushAfterSeconds = 3
  $MaxWait = $FlushAfterSeconds * 3 + 1
}

Describe 'Test Invoke-WinampAutoRestart.ps1' -Skip {
  $Parameters = @(
    '-nologo',
    '-File',
    "$ScriptPath",
    '-FlushAfterSeconds',
    "$FlushAfterSeconds",
    '-LogLevel',
    'Verbose'
  )
  $CurrentTrack = Get-Random -Minimum 1 -Maximum ($MaxTestFiles - 1)

  # Start Script
  $testScript = Start-Process -FilePath $PsShell -ArgumentList $Parameters -WorkingDirectory "${PSScriptRoot}\Fixtures" -PassThru

  It 'AutoRestart Script: Should start correclty' {
    $testScript.HasExited | Should Be $false
  }

  Start-Sleep 2

  It 'AutoRestart Script: Should wait for Winamp to start' {
    $testScript.HasExited | Should Be $false
  }

  # Starting Winamp
  $testWinamp = Start-Process -FilePath $WinampPath -ArgumentList $TestPlaylist -WorkingDirectory "${PSScriptRoot}\Fixtures" -PassThru
  Start-SleepOrCondition -Condition { [long]$testWinamp.MainWindowHandle -gt 0 } -Seconds 30
  $window = Wait-WinampInit

  if (!([long]$testWinamp.MainWindowHandle -gt 0)) {
    Throw 'Test instance of Winamp did not start.'
  }

  It 'Winamp: hWnd should be retrievable using the WinAPI' {
    $testWinamp = Get-Process 'winamp'
    $window.hWnd | Should Be $testWinamp.MainWindowHandle
  }

  It 'AutoRestart Script: should NOT restart Winamp when song is playing' {
    Write-Debug "Waiting $MaxWait seconds.."
    Start-Sleep -Seconds $MaxWait
    $testWinamp.HasExited | Should Be $false
  }

  Set-WinampPlaylistIndex -Window $window -PlaylistIndex $CurrentTrack

  Invoke-WinampPause -Window $window
  $SeekPosMS = Get-WinampSeekPos -Window $window
  Write-Debug "Current Winamp song position: $SeekPosMS"

  It 'Winamp: Should be PAUSED successfully' {
    $playStatus = Get-WinampPlayStatus -Window $window # 0: stopped, 1: playing, 3: paused
    $playStatus | Should Be 3
  }

  It 'AutoRestart Script: Should RESTART Winamp when song is paused' {
    Write-Debug 'Waiting for the old Winamp to be STOPPED..'
    Start-SleepOrCondition -Condition { $testWinamp.HasExited } -Seconds 30
    $testWinamp.HasExited | Should Be $true
    Write-Debug 'Waiting for the new Winamp to be STARTED..'
    $process = Start-SleepOrCondition -Condition { Get-Process 'winamp' -ErrorAction SilentlyContinue } -Seconds 30
    Write-Debug "Waiting for the new Winamp's hWnd to initialise.."
    Start-SleepOrCondition -Condition { [long]$process.MainWindowHandle -gt 0 } -Seconds 30 | Out-Null
    [long]$process.MainWindowHandle | Should BeGreaterThan 0
  }

  $window = Wait-WinampInit
  $process = Get-Process 'winamp'
  Start-Sleep 2

  It "Playback position should be seeked back to: $SeekPosMS" {
    $window = Wait-WinampInit $window
    $SeekPosNew = $window.SendMessage($WM_USER, 0, 105)
    Write-Debug "SeekPosNew: $SeekPosNew"
    # Math Abs difference between the two should be less than 2 seconds:
    [Math]::Abs($SeekPosNew - $SeekPosMS) | Should BeLessThan 2000
  }

  It 'Playpack status shoulde be PAUSED' {
    $playStatus = $window.SendMessage($WM_USER, 0, 104)
    $playStatus | Should Be 3
  }

  It 'Winamp should NOT be restarted the second time' {
    Write-Debug "Waiting $MaxWait seconds.."
    Start-Sleep -Seconds $MaxWait
    $processTest = Get-Process 'winamp'
    $processTest.Id | Should Be $process.Id
  }

  # Seek to another track and see if Winamp will be restarted
  $CurrentTrack = ($CurrentTrack + 5) % $MaxTestFiles
  Set-WinampPlaylistIndex -Window $window -PlaylistIndex $CurrentTrack

  It 'Winamp should be restarted the third time' {
    Invoke-WinampPlay -Window $window
    Invoke-WinampPause -Window $window
    Write-Debug "Waiting $MaxWait seconds.."
    Start-Sleep -Seconds $MaxWait
    $processTest = Get-Process 'winamp'
    $processTest.Id | Should Not Be $process.Id
  }

  It 'AutoRestart Script: Should stop correctly' {
    $testScript.Kill()
    $testScript.WaitForExit()
    $testScript.HasExited | Should Be $true
  }

  ## Stop Winamp
  &$WinampPath /close
  Start-SleepOrCondition -Seconds 30 -Condition { $testWinamp.HasExited }
  if (!$testWinamp.HasExited) {
    $testWinamp.Kill()
    $testWinamp.WaitForExit()
  }
}

Describe 'Testing Scheduled Task install' {
  $TaskName = Split-Path $ScriptPath -Leaf
  $Parameters = @(
    '-nologo',
    '-File',
    "$ScriptPath",
    '-FlushAfterSeconds',
    '3',
    '-LogLevel',
    'Verbose',
    '-Install CurrentUser'
  )

  # Start Script
  $testScript = Start-Process -FilePath $PsShell -ArgumentList $Parameters -WorkingDirectory "${PSScriptRoot}\Fixtures" -PassThru -NoNewWindow -Wait
  It 'Process should exit with code 0' {
    $testScript.ExitCode | Should Be 0
  }

  It 'Should install the scheduled task' {
    $st = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $st | Should Not BeNullOrEmpty
    $st.State | Should Be 'Running'
  }

  It 'PowerShell process should be RUNNING' {
    $process = Get-WmiObject Win32_Process | Where-Object Commandline -Like "*$TaskName*"
    $process | Should Not BeNullOrEmpty
  }
  
  It 'Stopping the Scheduled Task should end the script' {
    $process = Get-WmiObject Win32_Process | Where-Object Commandline -Like "*$TaskName*"
    $process | Should Not BeNullOrEmpty
    Stop-ScheduledTask -TaskName $TaskName
    Write-Debug 'Stopped Scheduled Task. Waiting for the PowerShell script to exit.'
    $result = Start-SleepUntilTrue -Condition { !(Get-WmiObject Win32_Process | Where-Object Commandline -Like "*$TaskName*") } -Seconds 30
    $result | Should Be $true
  }

  It 'Should uninstall the scheduled task' {
    Write-Debug 'Waiting for the PowerShell script to start..'
    Start-ScheduledTask -TaskName $TaskName
    Start-SleepUntilTrue -Seconds 30 -Condition { Get-WmiObject Win32_Process | Where-Object Commandline -Like "*$TaskName*" } | Out-Null
    Start-Sleep 2
    $Parameters = @(
      '-nologo',
      '-File',
      "$ScriptPath",
      '-Uninstall'
    )
    $testScript = Start-Process -FilePath $PsShell -ArgumentList $Parameters -WorkingDirectory "${PSScriptRoot}\Fixtures" -PassThru -NoNewWindow -Wait
    $testScript.ExitCode | Should Be 0
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $task | Should BeNullOrEmpty
  }

  It 'Uninstall should end the script' {
    Write-Debug 'Waiting for the PowerShell script to stop..'
    $result = Start-SleepUntilTrue -Condition { !(Get-WmiObject Win32_Process | Where-Object Commandline -Like "*$TaskName*") }
    $result | Should Be $true
  }
}
