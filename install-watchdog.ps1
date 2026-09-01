<#
.SYNOPSIS
  Register (or remove) the scheduled task that runs watchdog.ps1.

.DESCRIPTION
  Creates a task that runs every 15 minutes, and again at logon, for the current
  user. It runs only while that user is logged on, on purpose: the watchdog uses
  the user's Docker Desktop engine and the user's gh credentials, neither of
  which exists in a SYSTEM session.

.EXAMPLE
  ./install-watchdog.ps1
  ./install-watchdog.ps1 -Fleet edtok,leetspeak
  ./install-watchdog.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [ValidateSet('edtok', 'leetspeak')]
    [string[]]$Fleet = @('edtok'),

    [int]$IntervalMinutes = 15,

    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$taskName = 'local-gh-runner watchdog'
$root = Split-Path -Parent $PSCommandPath
$watchdog = Join-Path $root 'watchdog.ps1'

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "removed scheduled task '$taskName'"
    } else {
        Write-Host "no scheduled task named '$taskName'"
    }
    exit 0
}

if (-not (Test-Path $watchdog)) { throw "missing $watchdog" }

$fleetArg = $Fleet -join ','
$argument = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Fleet {1}' -f $watchdog, $fleetArg

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument -WorkingDirectory $root

# Two triggers: a repeating one for steady-state, and one at logon so a reboot
# does not leave the fleet down until the first interval elapses.
$repeating = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$atLogon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

$principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask -TaskName $taskName `
    -Action $action `
    -Trigger @($repeating, $atLogon) `
    -Settings $settings `
    -Principal $principal `
    -Description "Restarts local GitHub Actions runner fleet(s) whose containers have gone missing. See watchdog.ps1." `
    -Force | Out-Null

Write-Host "registered '$taskName': every $IntervalMinutes min + at logon, fleets=$fleetArg"
Write-Host "log: $(Join-Path $root 'watchdog.log')"
