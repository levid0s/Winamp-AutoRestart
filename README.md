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
