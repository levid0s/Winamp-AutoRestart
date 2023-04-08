BeforeDiscovery {
  $PesterPreference = [PesterConfiguration]::Default
  $PesterPreference.Output.Verbosity = 'Detailed'
}

BeforeAll {
  . $PSScriptRoot/_TestHelpers.ps1

  Write-Debug "TestDrive is: $TestDrive"

  $FixturesPath = "${PSScriptRoot}\Fixtures"
  $WinampStaging = New-WinampStagingArea -FixturesPath $FixturesPath -TestMP3 $TestMP3
}

Describe 'Get-WinampSongRating' {
  It 'should return null if Winamp is not running' {
    Get-WinampSongRating | Should -Be $null
  }

  Context 'Winamp running' {
    BeforeAll {
      $DelayMS = 500
      $testWinamp = Start-TestWinamp -WinampPath $WinampPath -WorkingDirectory $WinampStaging -NoAPI
      [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
    }
    
    It 'No rating: 0' {
      [System.Windows.Forms.SendKeys]::SendWait('^%{F10}')
      Start-Sleep -Milliseconds $DelayMS
      Get-WinampSongRating | Should -Be 0
    }

    It 'Rating: <_>' -ForEach @(1, 2, 3, 4, 5) {
      [System.Windows.Forms.SendKeys]::SendWait("^%{F$_}")
      Start-Sleep -Milliseconds $DelayMS
      Get-WinampSongRating | Should -Be $_
    }

    AfterAll {
      Remove-WinampStagingArea -Path $WinampStaging
    }
  }
}
