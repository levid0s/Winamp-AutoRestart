<#
.VERSION 2023.11.18

.SYNOPSIS
The script sets the colours on the F1 - F5 keys, according to the currently playing song's rating in Winamp.

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

function Write-SongRatingLog {
    [CmdletBinding()]
    param(
        [string]$Title,
        [int]$Rating,
        [string]$LogPath
    )
    $timestampIso = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    $logLine = "$timestampIso,$title,$rating"
    Write-Verbose "Logging: $logLine"
    Add-Content -Path $LogPath -Value $logLine    
}


[CmdletBinding()]

$DebugPreference = 'Continue'
$host.UI.RawUI.WindowTitle = 'Set-KeyColorBySongRating.ps1'

$RatingsLogPath = 'N:\Tools\Winamp-58portable\Ratings\Ratings.log'
$LogiSetKeyPath = 'N:\src\Logi-SetRGB\Logi_SetTargetZone_Sample_CS\obj\x64\Debug\Logi_SetTargetZone_Sample_CS_old.exe'
$LogiSetKeyName = [System.IO.Path]::GetFileNameWithoutExtension($LogiSetKeyPath)

$CheckProcess = Get-Process $LogiSetKeyName -ErrorAction SilentlyContinue
if ($null -eq $CheckProcess) {
    Write-Debug "Starting $LogiSetKeyName."
    $LogiSetKey = Start-Process $LogiSetKeyPath -WindowStyle Minimized -PassThru
}
else {
    Write-Debug "$LogiSetKeyName already running."
}

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

$DebugPreference = 'SilentlyContinue'
. "$PSScriptRoot/_Winamp-AutoRestartHelpers.ps1"

. "$PSScriptRoot/_PlexHelpers.ps1"

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


$color_ON = [System.Drawing.ColorTranslator]::FromHtml('#FF0000')
$color_OFF = [System.Drawing.ColorTranslator]::FromHtml('#000000')

$pipeName = 'MyNamedPipe'
$pipePath = "\\.\pipe\$pipeName"


try {
    Write-Debug "Attempting to connect to named pipe: $pipePath"
    Write-Verbose 'Creating Pipe..'
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName, [System.IO.Pipes.PipeDirection]::Out)
    $timeout = 5000
    Write-Verbose "Connecting to pipe with timeout ${timeout}ms.."
    $pipe.Connect($timeout)

    Write-Verbose 'Creating writer..'
    $writer = New-Object System.IO.StreamWriter($pipe)
    $writer.AutoFlush = $true

    Write-Information "Connected to named pipe: $pipePath"

    $lastRating = $null
    $song = $null

    $proc = $null

    while ($true) {
        while ($null -eq $proc -or $proc.HasExited -eq $true) {
            $pw = Get-Process winamp -ErrorAction SilentlyContinue
            if ($pw.Count -gt 1) {
                Write-Warning "Multiple Winamp processes detected: $($pw | Select-Object -ExpandProperty Id)"
                Continue
            }
            if ($pw) {
                $proc = $pw
                Continue
            }

            $pp = Get-Process -Name plexamp -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowhandle -ne 0 }
            if ($pp) {
                $proc = $pp
                Continue
            }
            Write-Warning 'Waiting for Winamp or Plexamp to start..'
            Start-Sleep -Seconds 2
        }


        Start-Sleep -Milliseconds 200
        
        $lastSong = $song
        $lastRating = $rating

        switch ($proc.ProcessName) {
            'winamp' {
                $song = Get-WinampSongTitle -ErrorAction SilentlyContinue
                $rating = Get-WinampSongRating -ErrorAction SilentlyContinue
            }
            'plexamp' {
                $NowPlaying = Get-PlexNowPlaying
                $song = "$($NowPlaying.Artist) - $($NowPlaying.Album) - $($NowPlaying.Title)"
                $rating = $NowPlaying.Rating / 2
            }
        }
        
        if ($rating -eq $lastRating) {
            continue
        }
        if ($song -eq $lastsong -and $Rating -ne $lastRating -and $null -ne $Song) {
            Write-Debug "Rated song: $song [$Rating]"
            Write-SongRatingLog -Title $song -Rating $Rating -LogPath $RatingsLogPath
        }
        Write-Host "Rating: $rating"

        switch ($true) {
            { $rating -ge 1 } { Set-KeyColor -writer $writer -key $LOGI.F1 -color $color_ON }
            { $rating -ge 2 } { Set-KeyColor -writer $writer -key $LOGI.F2 -color $color_ON }
            { $rating -ge 3 } { Set-KeyColor -writer $writer -key $LOGI.F3 -color $color_ON }
            { $rating -ge 4 } { Set-KeyColor -writer $writer -key $LOGI.F4 -color $color_ON }
            { $rating -ge 5 } { Set-KeyColor -writer $writer -key $LOGI.F5 -color $color_ON }
        }

        switch ($true) {
            { $rating -lt 5 } { Set-KeyColor -writer $writer -key $LOGI.F5 -color $color_OFF }
            { $rating -lt 4 } { Set-KeyColor -writer $writer -key $LOGI.F4 -color $color_OFF }
            { $rating -lt 3 } { Set-KeyColor -writer $writer -key $LOGI.F3 -color $color_OFF }
            { $rating -lt 2 } { Set-KeyColor -writer $writer -key $LOGI.F2 -color $color_OFF }
            { $rating -lt 1 } { Set-KeyColor -writer $writer -key $LOGI.F1 -color $color_OFF }
        }

    }
    else {
        Write-Host 'Connection attempt timed out.'
    }
}
catch {
    Write-Host "Error: $($_.Exception.Message)"
}
finally {
    $writer.Close()
    $pipe.Close()

    Stop-Process $LogiSetKey -ErrorAction SilentlyContinue
}
