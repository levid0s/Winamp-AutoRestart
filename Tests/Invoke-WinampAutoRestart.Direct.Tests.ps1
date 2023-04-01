BeforeAll {
  . $PSScriptRoot/_TestHelpers.ps1
}

Describe 'Test AutoRestart script' {
  BeforeAll {
    $FlushAfterSeconds = 3
    $MaxWait = $FlushAfterSeconds * 3 + 1
    $Parameters = @(
      '-nologo',
      '-File',
      "$ScriptPath",
      '-FlushAfterSeconds',
      "$FlushAfterSeconds",
      '-LogLevel',
      'Verbose'
    )
    $testScript = Start-Process -FilePath $PsShell -ArgumentList $Parameters -WorkingDirectory "${PSScriptRoot}\Fixtures" -PassThru
  }

  It 'should start correctly' {
    $testScript.HasExited | Should -Be $false
  }

  It 'should wait for Winamp to start' {
    Start-Sleep 2
    $testScript.HasExited | Should -Be $false
  }

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
          [long]$SeekPosNew = $window.SendMessage($WM_USER, 0, 105)
          Write-Debug "SeekPosNew: $SeekPosNew"
          # Math Abs difference between the two should be less than 2 seconds:
          [Math]::Abs($SeekPosNew - $SeekPosMS) | Should -BeLessThan 2000  
        }

        It 'Playpack status shoulde be PAUSED' {
          $playStatus = $window.SendMessage($WM_USER, 0, 104)
          $playStatus | Should -Be 3
        }

        It 'should NOT be restarted the second time' {
          Write-Debug "Waiting $MaxWait seconds.."
          Start-Sleep -Seconds $MaxWait
          $processTest = Get-Process 'winamp'
          $processTest.Id | Should -Be $newWinamp.Id
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

  AfterAll {
    $testScript.Kill()
    $testScript.WaitForExit()
    $testScript.HasExited | Should -Be $true

  }
}
