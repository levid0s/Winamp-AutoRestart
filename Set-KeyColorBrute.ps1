<#
.VERSION 20230409

.SYNOPSIS
Change set the colours of the F1 - F5 keys according to the current song's rating in Winamp.

.DESCRIPTION
Script that checks Winamp song ratings, and sets the colours on the F1 - F5 keys, on a Logitech G815 keyboard.

Needs:
* https://github.com/levid0s/Logi-SetRGB
* Winamp title format: `[%artist% - ]$if2(%title%,$filepart(%filename%))[  $repeat(★,%rating%) ]`

.EXAMPLE
.\Set-KeyColorBySongRating.ps1
DEBUG: Attempting to connect to named pipe: \\.\pipe\MyNamedPipe
Rating: 5
Rating: 4
#>

$LogiSetKeyPath = 'N:\src\Logi-SetRGB\Logi_SetTargetZone_Sample_CS\bin\x64\Debug\Logi_SetTargetZone_Sample_CS.exe'
# Get process name of exe:
$LogiSetKeyProcessName = Split-Path $LogiSetKeyPath -Leaf
$LogiSetKeyProcessName = $LogiSetKeyProcessName -replace '\.[^.]*$'
if (Get-Process $LogiSetKeyProcessName -ErrorAction SilentlyContinue) {
  Throw "Process $LogiSetKeyProcessName is already running."
}

$LogiSetKey = Start-Process $LogiSetKeyPath -WindowStyle Minimized -PassThru

$LOGI = @{
  ESC                = '0x01'
  F1                 = '0x3b'
  F2                 = '0x3c'
  F3                 = '0x3d'
  F4                 = '0x3e'
  F5                 = '0x3f'
  F6                 = '0x40'
  F7                 = '0x41'
  F8                 = '0x42'
  F9                 = '0x43'
  F10                = '0x44'
  F11                = '0x57'
  F12                = '0x58'
  PRINT_SCREEN       = '0x137'
  SCROLL_LOCK        = '0x46'
  PAUSE_BREAK        = '0x145'
  TILDE              = '0x29'
  ONE                = '0x02'
  TWO                = '0x03'
  THREE              = '0x04'
  FOUR               = '0x05'
  FIVE               = '0x06'
  SIX                = '0x07'
  SEVEN              = '0x08'
  EIGHT              = '0x09'
  NINE               = '0x0A'
  ZERO               = '0x0B'
  MINUS              = '0x0C'
  EQUALS             = '0x0D'
  BACKSPACE          = '0x0E'
  INSERT             = '0x152'
  HOME               = '0x147'
  PAGE_UP            = '0x149'
  NUM_LOCK           = '0x45'
  NUM_SLASH          = '0x135'
  NUM_ASTERISK       = '0x37'
  NUM_MINUS          = '0x4A'
  TAB                = '0x0F'
  Q                  = '0x10'
  W                  = '0x11'
  E                  = '0x12'
  r                  = '0x13'
  T                  = '0x14'
  Y                  = '0x15'
  U                  = '0x16'
  I                  = '0x17'
  O                  = '0x18'
  P                  = '0x19'
  OPEN_BRACKET       = '0x1A'
  CLOSE_BRACKET      = '0x1B'
  BACKSLASH          = '0x2B'
  KEYBOARD_DELETE    = '0x153'
  END                = '0x14F'
  PAGE_DOWN          = '0x151'
  NUM_SEVEN          = '0x47'
  NUM_EIGHT          = '0x48'
  NUM_NINE           = '0x49'
  NUM_PLUS           = '0x4E'
  CAPS_LOCK          = '0x3A'
  A                  = '0x1E'
  S                  = '0x1F'
  D                  = '0x20'
  F                  = '0x21'
  G                  = '0x22'
  h                  = '0x23'
  J                  = '0x24'
  K                  = '0x25'
  L                  = '0x26'
  SEMICOLON          = '0x27'
  APOSTROPHE         = '0x28'
  ENTER              = '0x1C'
  NUM_FOUR           = '0x4B'
  NUM_FIVE           = '0x4C'
  NUM_SIX            = '0x4D'
  LEFT_SHIFT         = '0x2A'
  Z                  = '0x2C'
  X                  = '0x2D'
  C                  = '0x2E'
  V                  = '0x2F'
  B                  = '0x30'
  N                  = '0x31'
  M                  = '0x32'
  COMMA              = '0x33'
  PERIOD             = '0x34'
  FORWARD_SLASH      = '0x35'
  RIGHT_SHIFT        = '0x36'
  ARROW_UP           = '0x148'
  NUM_ONE            = '0x4F'
  NUM_TWO            = '0x50'
  NUM_THREE          = '0x51'
  NUM_ENTER          = '0x11C'
  LEFT_CONTROL       = '0x1D'
  LEFT_WINDOWS       = '0x15B'
  LEFT_ALT           = '0x38'
  SPACE              = '0x39'
  RIGHT_ALT          = '0x138'
  RIGHT_WINDOWS      = '0x15C'
  APPLICATION_SELECT = '0x15D'
  RIGHT_CONTROL      = '0x11D'
  ARROW_LEFT         = '0x14B'
  ARROW_DOWN         = '0x150'
  ARROW_RIGHT        = '0x14D'
  NUM_ZERO           = '0x52'
  NUM_PERIOD         = '0x53'
  G_1                = '0xFFF1'
  G_2                = '0xFFF2'
  G_3                = '0xFFF3'
  G_4                = '0xFFF4'
  G_5                = '0xFFF5'
  G_6                = '0xFFF6'
  G_7                = '0xFFF7'
  G_8                = '0xFFF8'
  G_9                = '0xFFF9'
  G_LOGO             = '0xFFFF1'
  G_BADGE            = '0xFFFF2'
}

Add-Type -AssemblyName System.Drawing

. "$PSScriptRoot/_Winamp-AutoRestartHelpers.ps1"

function Set-KeyColor {
  param(
    $writer,
    $key,
    $color
  )
  $writer.WriteLine("setkey,$key,$($color.R),$($color.G),$($color.B)")
}

$InformationPreference = 'Continue'
$DebugPreference = 'Continue'
$VerbosePreference = 'Continue'

$color_ON = [System.Drawing.ColorTranslator]::FromHtml('#FF0000')
$color_OFF = [System.Drawing.ColorTranslator]::FromHtml('#000000')
$color_blink = [System.Drawing.ColorTranslator]::FromHtml('#ff00ff')

$pipeName = 'MyNamedPipe'
$pipePath = "\\.\pipe\$pipeName"

try {
  Write-Debug "Attempting to connect to named pipe: $pipePath"
  $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName, [System.IO.Pipes.PipeDirection]::Out)
  $pipe.Connect()

  $writer = New-Object System.IO.StreamWriter($pipe)
  $writer.AutoFlush = $true

  Write-Information "Connected to named pipe: $pipePath"

  $prevLeading = $null
  $blink = $null

  for ($i = 0x01; $i -le 0xFFFFFF; $i++) {
    # Convert i to hex with padding
    $hex = '0x' + $i.ToString('X').PadLeft(6, '0')
    $leading = $i.ToString('X').PadLeft(6, '0')[0, 2] -join ''
    if ($leading -ne $prevLeading) {
      Write-Host "$hex"
      if ($blink -eq $color_blink) {
        $blink = $color_OFF
      }
      else {
        $blink = $color_blink
      }
      Set-KeyColor -writer $writer -key '0xffff1' -color $blink
      $prevLeading = $leading
    }
    # Write-Host "$hex " -NoNewline
    # Split $i into bits and do AND

    Set-KeyColor -writer $writer -key $hex -color $color_OFF
  }
  Write-Host "`nRun completed, press any key to continue" -NoNewline
  Read-Host | Out-Null
}
catch {
  Write-Host "Error: $($_.Exception.Message)"
}
finally {
  $writer.Close()
  $pipe.Close()

  Stop-Process $LogiSetKey -Force
}
