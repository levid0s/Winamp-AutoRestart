. ./_TestHelpers.ps1

Describe "Wait-WinampInit Tests" {

  $testWinamp = Start-TestWinamp

  It "It should wait for Winamp to start." {
    $window = Wait-WinampInit
    $process = Get-Process 'winamp'
    $window.hwnd | Should Be $process.MainWindowHandle
    Wait-WinampInit $window
  }

  Stop-TestWinamp
}


