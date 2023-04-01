BeforeAll {
  . $PSScriptRoot/_TestHelpers.ps1
}

Describe 'Testing Scheduled Task install' {
  BeforeAll {
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
  }

  It 'Process should exit with code 0' {
    $testScript.ExitCode | Should -Be 0
  }

  It 'Should install the scheduled task' {
    $st = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $st | Should -Not -BeNullOrEmpty
    $st.State | Should -Be 'Running'
  }

  It 'PowerShell process should be RUNNING' {
    $process = Get-WmiObject Win32_Process | Where-Object Commandline -Like "*$TaskName*"
    $process | Should -Not -BeNullOrEmpty
  }
  
  It 'Stopping the Scheduled Task should end the script' {
    $process = Get-WmiObject Win32_Process | Where-Object Commandline -Like "*$TaskName*"
    $process | Should -Not -BeNullOrEmpty
    Stop-ScheduledTask -TaskName $TaskName
    Write-Debug 'Stopped Scheduled Task. Waiting for the PowerShell script to exit.'
    $result = Start-SleepUntilTrue -Condition { !(Get-WmiObject Win32_Process | Where-Object Commandline -Like "*$TaskName*") } -Seconds 30
    $result | Should -Be $true
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
    $testScript.ExitCode | Should -Be 0
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $task | Should -BeNullOrEmpty
  }

  It 'Uninstall should end the script' {
    Write-Debug 'Waiting for the PowerShell script to stop..'
    $result = Start-SleepUntilTrue -Condition { !(Get-WmiObject Win32_Process | Where-Object Commandline -Like "*$TaskName*") }
    $result | Should -Be $true
  }
}
