BeforeAll {
  Function ExponentialBackoff {
    param(
      [int]$Rounds = 3,
      [int]$InitialDelayMs = 100,
      [scriptblock]$Do,
      [scriptblock]$Check
    )

    for ($round = 1; $round -le $rounds; $round++) {
      if ($round -gt 1) {
        Write-Debug "Operatoin failed, retrying with exponential backoff, round $round. Sleeping for $InitialDelayMs ms.."
        Start-Sleep -Milliseconds $InitialDelayMs  
        $InitialDelayMs *= 2
      }
      try {
        $result = & $Do
      }
      catch {
      }

      if (& $Check) {
        Write-Debug 'Check returned true, exiting.'
        break
      }
    }
  }

  $DebugPreference = 'Continue'
  $conf = [PesterConfiguration]::Default
  $conf.Output.Verbosity = 'Detailed'
}

Describe 'ExponentialBackoff' {
  BeforeAll { 
    Function DoSomething {
      Write-Host 'Invoking real DoSomething'
    }
  }

  BeforeEach {
    Mock DoSomething -MockWith { return 1 }
  }

  It 'should do all rounds (<Rounds>) * <InitialDelayMs>ms' -ForEach @(
    @{ Rounds = 1; InitialDelayMs = 10000 } 
    @{ Rounds = 3; InitialDelayMs = 100 } 
    @{ Rounds = 5; InitialDelayMs = 123 }
    @{ Rounds = Get-Random -Minimum 1 -Maximum 7; InitialDelayMs = Get-Random -Minimum 30 -Maximum 200 }
  ) {
    $time = Measure-Command { 
      ExponentialBackoff -Rounds $Rounds -InitialDelayMs $initialDelayMs -Do {
        DoSomething } -Check {
        $false
      }
    }

    Should -Invoke DoSomething -Exactly -Times $Rounds -Scope It
  }

  It 'should do just one round (<Rounds>) * <InitialDelayMs>ms' -ForEach @(
    @{ Rounds = 1; InitialDelayMs = 10000 } 
    @{ Rounds = 3; InitialDelayMs = 100 } 
    @{ Rounds = 5; InitialDelayMs = 123 }
    @{ Rounds = Get-Random -Minimum 1 -Maximum 7; InitialDelayMs = Get-Random -Minimum 30 -Maximum 200 }
  ) {
    $time = Measure-Command { 
      ExponentialBackoff -Rounds $Rounds -InitialDelayMs $initialDelayMs -Do {
        DoSomething } -Check {
        $true
      }
    }

    Should -Invoke DoSomething -Exactly -Times 1 -Scope It
  }


  It 'should complete the backoff: <Rounds> * <InitialDelayMs>' -Skip -ForEach @(
    @{ Rounds = 3; InitialDelayMs = 100 } 
    @{ Rounds = 5; InitialDelayMs = 123 }
    @{ Rounds = Get-Random -Minimum 1 -Maximum 7; InitialDelayMs = Get-Random -Minimum 30 -Maximum 200 }
  ) {
    Write-Debug "Should complete the command in $()"
    $time = Measure-Command { 
      ExponentialBackoff -Rounds $Rounds -InitialDelayMs $initialDelayMs -Do {
        Write-Debug "Doing round: $Round"
      } -Check {
        $false
      }
    }

    $timeMin = $initialDelayMs * [math]::Pow(2, $Rounds - 2)
    $timeMax = $initialDelayMs * [math]::Pow(2, $Rounds - 2) * 1.1
    Write-Debug "TimeMin: $timeMin; TimeMax: $timeMax"
    $time.TotalMilliseconds | Should -BeGreaterThan $timeMin
    # $endTime.Subtract($startTime).TotalMilliseconds | Should -BeLessThan $timeMax
  }

  It 'should exit the backoff in the first round' -Skip -ForEach @(
    @{ Rounds = 3; InitialDelayMs = 100 } 
    @{ Rounds = 5; InitialDelayMs = 123 }
    @{ Rounds = Get-Random -Minimum 1 -Maximum 7; InitialDelayMs = Get-Random -Minimum 30 -Maximum 200 }
  ) {

    $startTime = Get-Date

    ExponentialBackoff -Rounds $Rounds -InitialDelayMs 100 -Do {
      Write-Debug "Doing round: $Round"
    } -Check {
      $false
    }
    $endTime = Get-Date
    $timeMin = $initialDelayMs * [math]::Pow(2, $Rounds - 2)
    $timeMax = $initialDelayMs * [math]::Pow(2, $Rounds - 1)
    $endTime.Subtract($startTime).TotalMilliseconds | Should -BeGreaterThan $timeMin
    $endTime.Subtract($startTime).TotalMilliseconds | Should -BeLessThan $timeMax
  }
}
