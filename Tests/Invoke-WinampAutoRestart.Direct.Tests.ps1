BeforeAll {
  . $PSScriptRoot/_TestHelpers.ps1
}

Describe 'Basic Test' {
  BeforeAll {
    $Parameters = @(
      '-nologo',
      '-File',
      "$ScriptPath"
    )
    $AutoRestartScript = Start-Process -FilePath $PsShell -ArgumentList $Parameters -WorkingDirectory "${PSScriptRoot}\Fixtures" -PassThru
  }

  It 'should start correctly' {
    $AutoRestartScript.HasExited | Should -Be $false
  }

  It 'should wait for Winamp to start' {
    Start-Sleep 2
    $AutoRestartScript.HasExited | Should -Be $false
  }

  AfterAll {
    $AutoRestartScript.Kill()
    $AutoRestartScript.WaitForExit()
    $AutoRestartScript.HasExited | Should -Be $true
  }
}

Describe 'Test AutoRestart script' {
  BeforeAll {
    $FlushAfterSeconds = 1
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
    $AutoRestartScript = Start-Process -FilePath $PsShell -ArgumentList $Parameters -WorkingDirectory "${PSScriptRoot}\Fixtures" -PassThru
  }

  It 'should start correctly' {
    $AutoRestartScript.HasExited | Should -Be $false
  }

  It 'should wait for Winamp to start' {
    Start-Sleep 2
    $AutoRestartScript.HasExited | Should -Be $false
  }

  ####
  #Region Direct copy TO: SchTask.Test
  ####

  Context 'Test Winamp Behaviour' {
    BeforeAll {
      $FixturesPath = "${PSScriptRoot}\Fixtures"

      $WinampStaging = New-WinampStagingArea -FixturesPath $FixturesPath -TestMP3 $TestMP3
      $testWinamp = Start-TestWinamp -WinampPath $WinampPath -WorkingDirectory $WinampStaging
      $window = Wait-WinampInit    
    }

    It 'should start correctly' {
      $testWinamp.HasExited | Should -Be $false
      [long]$testWinamp.MainWindowHandle | Should -BeGreaterThan 0
    }

    It 'hWnd should be retrievable using the WinAPI' {
      $testWinamp = Get-Process 'winamp' -ErrorAction Stop
      $window.hWnd | Should -Be $testWinamp.MainWindowHandle
    }

    It 'AutoRestart Script should NOT restart Winamp when song is playing' {
      Write-Debug "Waiting $MaxWait seconds.."
      Start-Sleep -Seconds $MaxWait
      $testWinamp.HasExited | Should -Be $false
    }

    Context 'Restarting Winamp when Paused: round <_>/7' -ForEach 1, 2, 3, 5, 6, 7 {
      BeforeAll {
        $oldWinamp = Get-Process 'winamp' -ErrorAction Stop
        $window = Wait-WinampInit
        $RandomTrack = Get-Random -Minimum 1 -Maximum 29
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
          $newWinamp = Get-Process 'winamp' -ErrorAction Stop
          $window = Wait-WinampInit
          Start-Sleep 1
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
          $processTest = Get-Process 'winamp' -ErrorAction Stop
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
      Remove-WinampStagingArea -Path $WinampStaging
    }
  }


  ####
  #Endregion
  ####

  AfterAll {
    $AutoRestartScript.Kill()
    $AutoRestartScript.WaitForExit()
    $AutoRestartScript.HasExited | Should -Be $true
  }
}
