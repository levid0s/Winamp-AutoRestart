## Winamp-AutoRestart

Script for monitoring Winamp, and restart it when idle, to get the Media Library written to disk.

Can be run in the console, but ideally it should be installed as a scheduled task.

See the PowerShell script header for more info.

### Usage (Scheduled Task)

This will install the script as a Scheduled task and will start it at Logon.
Check `%TEMP%\Invoke-WinampAutoRestart.ps1-TIMESTAMP.log` to see if the playback status is detected correctly.

```
Invoke-WinampAutoRestart.ps1 -Install CurrentUser

Invoke-WinampAutoRestart.ps1 -Uninstall
```

### Usage (Inline)

```
Invoke-WinampAutoRestart.ps1
```

### Usage (Debug)

```
Invoke-WinampAutoRestart.ps1 -FlushAfterSeconds 10 -LogLevel Verbose
```

## Set-KeyColorBySongRating

Script that changes the colours of the F1 - F5 keys, according to the current song's rating in Winamp.

**Needs:**
* Logitech G LightSync keyboard
* [Logitech G Hub](https://www.logitechg.com/en-us/innovation/g-hub.html)
* https://github.com/levid0s/Logi-SetRGB
* Winamp title format set to: `[%artist% - ]$if2(%title%,$filepart(%filename%))[  $repeat(★,%rating%) ]`

## Usage

```
.\Set-KeyColorBySongRating.ps1

DEBUG: Attempting to connect to named pipe: \\.\pipe\MyNamedPipe
Rating: 5
Rating: 4
```
