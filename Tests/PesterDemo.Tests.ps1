BeforeAll {
  . $PSCommandPath.Replace('.Tests.ps1', '.ps1')
}

Describe "Get-Emoji" {
  Context "Lookup by whole name" {
    It "Returns <expected> (<name>)" -TestCases @(
      @{ Name = "cactus"; Expected = '🌵' }
      @{ Name = "giraffe"; Expected = '🦒' }
    ) {
      Get-Emoji -Name $name | Should -Be $expected
    }
  }

  Context "Lookup by wildcard" {
    Context "by prefix" {
      BeforeAll {
        $emojis = Get-Emoji -Name pen*
      }

      It "Returns <expected> (<name>)" -TestCases @(
        @{ Name = "pencil"; Expected = '✏️' }
        @{ Name = "penguin"; Expected = '🐧' }
        @{ Name = "pensive"; Expected = '😔' }
      ) {
        $emojis | Should -Contain $expected
      }
    }

    Context "by contains" {
      BeforeAll {
        $emojis = Get-Emoji -Name *smiling*
      }

      It "Returns <expected> (<name>)" -TestCases @(
        @{ Name = "slightly smiling face"; Expected = '🙂' }
        @{ Name = "beaming face with smiling eyes"; Expected = '😁' }
        @{ Name = "smiling face with smiling eyes"; Expected = '😊' }
      ) {
        $emojis | Should -Contain $expected
      }
    }
  }
}
