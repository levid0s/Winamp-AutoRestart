BeforeAll {
  . $PSScriptRoot/_TestHelpers.ps1
  $TaskName = Split-Path $ScriptPath -Leaf
  $st = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($st) {
    Throw 'Scheduled task already exists. Please delete manually.'
  }
}

Describe 'Testing Scheduled Task install' {
  BeforeAll {
    $TaskName = Split-Path $ScriptPath -Leaf
    $LogDir = "$env:LOCALAPPDATA\Temp"
    $LogLevel = 'Verbose'
    $FlushAfterSeconds = 3
    $MaxWait = $FlushAfterSeconds * 3 + 1
    $Parameters = @(
      '-nologo',
      '-File',
      "$ScriptPath",
      '-FlushAfterSeconds',
      $FlushAfterSeconds,
      '-LogLevel',
      $LogLevel,
      '-Install CurrentUser'
    )
  
    # Start Script
    $testScript = Start-Process -FilePath $PsShell -ArgumentList $Parameters -WorkingDirectory "${PSScriptRoot}\Fixtures" -PassThru -NoNewWindow -Wait
  }

  It 'Process should exit with code 0' {
    $testScript.ExitCode | Should -Be 0
  }

  It 'Should install the scheduled task' {
    $st = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $st | Should -Not -BeNullOrEmpty
    $st.State | Should -Be 'Running'
  }

  It 'Parameters should be correct' {
    $st = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $vbsPath = $st.Actions[0].Execute
    $vbs = Get-Content $vbsPath
    Select-String -InputObject $vbs -SimpleMatch "-LogLevel $LogLevel" | Should -Not -BeNullOrEmpty
    Select-String -InputObject $vbs -SimpleMatch "-FlushAfterSeconds $FlushAfterSeconds" | Should -Not -BeNullOrEmpty
  }

  It 'PowerShell process should be RUNNING' {
    $process = Get-WmiObject Win32_Process | Where-Object Commandline -Like "*$TaskName*"
    $process | Should -Not -BeNullOrEmpty
  }
  
  Context 'Checking the log file' {
    BeforeAll {
      $LogFile = Get-ChildItem -Path "$LogDir\Invoke-WinampAutoRestart.ps1*.log" | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
    }

    It 'Logging continuously' {
      $snapshot1 = (Get-Content $LogFile).Count
      Start-SleepUntilTrue -Condition { $snapshot1 -ne (Get-Content $LogFile).Count } -Seconds $FlushAfterSeconds * 10
      $snapshot2 = (Get-Content $LogFile).Count
      $snapshot1 | Should -Not -Be $snapshot2
    }
  }


  ####
  #Region Direct copy from Invoke-WinampAutoRestart.Tests.ps1
  ####


  Context 'Test Winamp Behaviour' {
    BeforeAll {
      $testWinamp = Start-Process -FilePath $WinampPath -ArgumentList $TestPlaylist -WorkingDirectory "${PSScriptRoot}\Fixtures" -PassThru
      Start-SleepUntilTrue -Condition { [long]$testWinamp.MainWindowHandle -gt 0 } -Seconds 30
      $window = Wait-WinampInit    
    }

    It 'should start correctly' {
      $testWinamp.HasExited | Should -Be $false
      [long]$testWinamp.MainWindowHandle | Should -BeGreaterThan 0
    }

    It 'hWnd should be retrievable using the WinAPI' {
      $testWinamp = Get-Process 'winamp'
      $window.hWnd | Should -Be $testWinamp.MainWindowHandle
    }

    It 'AutoRestart Script should NOT restart Winamp when song is playing' {
      Write-Debug "Waiting $MaxWait seconds.."
      Start-Sleep -Seconds $MaxWait
      $testWinamp.HasExited | Should -Be $false
    }

    Context 'Restarting Winamp when Paused: round <_>' -ForEach 1, 2, 3, 5, 6, 7 {
      BeforeAll {
        $oldWinamp = Get-Process 'winamp'
        if (!$oldWinamp) {
          Throw 'Winamp not running'
        }
        $window = Wait-WinampInit
        $RandomTrack = Get-Random -Minimum 1 -Maximum ($MaxTestFiles - 1)
        Set-WinampPlaylistIndex -Window $window -PlaylistIndex $RandomTrack
        Invoke-WinampPause -Window $window
        $SeekPosMS = Get-WinampSeekPos -Window $window
        Write-Debug "Winamp song seek position before restart: $SeekPosMS"
      }

      It 'should be PAUSED successfully' {
        $playStatus = Get-WinampPlayStatus -Window $window # 0: stopped, 1: playing, 3: paused
        $playStatus | Should -Be 3
      }
    
      It 'old Winamp process should be stopped' {
        Write-Debug 'Waiting for the old Winamp to be STOPPED..'
        Start-SleepUntilTrue -Condition { $oldWinamp.HasExited } -Seconds 30
        $oldWinamp.HasExited | Should -Be $true
      }

      It 'new Winamp instance should start' {
        Write-Debug 'Waiting for the new Winamp to be STARTED..'
        $newWinamp = Start-SleepUntilTrue -Condition { Get-Process 'winamp' -ErrorAction SilentlyContinue } -Seconds 30
        Write-Debug "Waiting for the new Winamp's hWnd to initialise.."
        Start-SleepUntilTrue -Condition { [long]$newWinamp.MainWindowHandle -gt 0 } -Seconds 30 | Out-Null
        [long]$newWinamp.MainWindowHandle | Should -BeGreaterThan 0
      }

      Context 'Testing new Winamp instance' {
        BeforeAll {
          $newWinamp = Get-Process 'winamp'
          $window = Wait-WinampInit
          Start-Sleep 2  
        }

        It 'new process should be different to the old one' {
          $newWinamp.Id | Should -Not -Be $oldWinamp.Id
        }

        It 'new Winamp API should start up' {
          $window | Should -Not -Be $null
        }

        It 'Playback seek position should be restored to: <SeekPosMS>' {
          Start-Sleep 1
          $SeekPosNew = Get-WinampSeekPos -Window $window
          Write-Debug "SeekPosNew: $SeekPosNew"
          # Math Abs difference between the two should be less than 2 seconds:
          [Math]::Abs($SeekPosNew - $SeekPosMS) | Should -BeLessThan 2000  
        }

        It 'Playpack status should be PAUSED' {
          $playStatus = Get-WinampPlayStatus -Window $window
          $playStatus | Should -Be 3
        }

        It 'should NOT be restarted the second time' {
          Write-Debug "Waiting $MaxWait seconds.."
          Start-Sleep -Seconds $MaxWait
          $processTest = Get-Process 'winamp'
          $processTest.Id | Should -Be $newWinamp.Id
          $newWinamp.HasExited | Should -Be $false
        }

        It 'should NOT restart when song is playing' {
          Invoke-WinampPlay -Window $window
          Write-Debug "Waiting $MaxWait seconds.."
          Start-Sleep -Seconds $MaxWait
          $newWinamp.HasExited | Should -Be $false
        }
    
      }
    }

    AfterAll {
      ## Stop Winamp
      &$WinampPath /close
      Start-SleepUntilTrue -Seconds 30 -Condition { $testWinamp.HasExited }
      if (!$testWinamp.HasExited) {
        $testWinamp.Kill()
        $testWinamp.WaitForExit()
      }  
    }
  }

  ####
  #Endregion
  ####

  It 'Stopping the Scheduled Task should end the script' {
    $process = Get-WmiObject Win32_Process | Where-Object { $_.Commandline -Like "*$TaskName*" -and $_.CommandLine -NotLike "*$env:LOCALAPPDATA\Temp\*.log*" }
    $process | Should -Not -BeNullOrEmpty
    Stop-ScheduledTask -TaskName $TaskName
    Write-Debug 'Stopped Scheduled Task. Waiting for the PowerShell script to exit.'
    $result = Start-SleepUntilTrue -Condition { !(Get-WmiObject Win32_Process | Where-Object { $_.Commandline -Like "*$TaskName*" -and $_.CommandLine -NotLike "*$env:LOCALAPPDATA\Temp\*.log*" }) } -Seconds 30
    $result | Should -Be $true
  }

  It 'Should uninstall the scheduled task' {
    Write-Debug 'Waiting for the PowerShell script to start..'
    Start-ScheduledTask -TaskName $TaskName
    Start-SleepUntilTrue -Seconds 30 -Condition { Get-WmiObject Win32_Process | Where-Object { $_.Commandline -Like "*$TaskName*" -and $_.CommandLine -NotLike "*$env:LOCALAPPDATA\Temp\*.log*" } } | Out-Null
    Start-Sleep 2
    $Parameters = @(
      '-nologo',
      '-File',
      "$ScriptPath",
      '-Uninstall'
    )
    $testScript = Start-Process -FilePath $PsShell -ArgumentList $Parameters -WorkingDirectory "${PSScriptRoot}\Fixtures" -PassThru -NoNewWindow -Wait
    $testScript.ExitCode | Should -Be 0
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $task | Should -BeNullOrEmpty
  }

  It 'Uninstall should end the script' {
    Write-Debug 'Waiting for the PowerShell script to stop..'
    $result = Start-SleepUntilTrue -Condition { !(Get-WmiObject Win32_Process | Where-Object { $_.Commandline -Like "*$TaskName*" -and $_.CommandLine -NotLike "*$env:LOCALAPPDATA\Temp\*.log*" }) }
    $result | Should -Be $true
  }

  AfterAll {
    $st = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($st) {
      Stop-ScheduledTask -TaskName $TaskName
      Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
  }
}
