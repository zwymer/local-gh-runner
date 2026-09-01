<#
.SYNOPSIS
  Bring a runner fleet back up if its containers have gone missing.

.DESCRIPTION
  `restart: unless-stopped` handles a crashed or stopped container and an engine
  restart. It cannot handle a container that no longer exists - and that is the
  failure that actually took the EdTok fleet down between 2026-08-31 and
  2026-09-01, along with the only edtok-production deploy runner. Nothing
  noticed until a production promotion had nowhere to schedule.

  This script closes that gap. It is deliberately conservative:

    * It acts only on containers that are ABSENT. A container that exists but is
      stopped is left alone - `unless-stopped` means a manual stop was intended,
      and ephemeral runners briefly exit between jobs by design. Recreating a
      container mid-job would kill a running deploy.
    * If the Docker engine is unreachable it starts Docker Desktop and returns.
      The next tick does the rest.
    * The GitHub cross-check is advisory only. If the containers are present but
      no runner is registered, `up -d` would be a no-op anyway, so it logs and
      leaves it for a human.

.PARAMETER Fleet
  Which fleet(s) to check. Defaults to edtok, the one production depends on.

.PARAMETER WhatIfOnly
  Report what would happen without starting anything.
#>
[CmdletBinding()]
param(
    [ValidateSet('edtok', 'leetspeak')]
    [string[]]$Fleet = @('edtok'),

    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$logFile = Join-Path $root 'watchdog.log'

$fleets = @{
    'edtok' = @{
        Project    = 'local-gh-runner'
        Containers = @('gh-runner-1', 'gh-runner-2', 'gh-runner-prod')
        Repo       = 'zwymer/EdTok'
        # The label EdTok's deploy.yml schedules its promotion job on.
        Label      = 'edtok-production'
    }
    'leetspeak' = @{
        Project    = 'leetspeak-gh-runner'
        Containers = @('ls-gh-runner-1', 'ls-gh-runner-2', 'ls-gh-runner-3')
        Repo       = 'zwymer/leetspeak'
        Label      = $null
    }
}

function Write-Log {
    param([string]$Level, [string]$Message)
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'), $Level, $Message
    Write-Host $line
    try { Add-Content -Path $logFile -Value $line -Encoding utf8 } catch { }
}

# Keep the log from growing without bound; this runs every 15 minutes forever.
try {
    if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 1MB)) {
        $keep = Get-Content $logFile -Tail 2000
        Set-Content -Path $logFile -Value $keep -Encoding utf8
    }
} catch { }

# docker-credential-wincred is not on PATH by default; without it compose fails
# during image metadata resolution with an opaque credentials error.
$dockerBin = 'C:\Program Files\Docker\Docker\resources\bin'
if ((Test-Path $dockerBin) -and ($env:PATH -notlike "*$dockerBin*")) {
    $env:PATH = "$env:PATH;$dockerBin"
}

# --- Is the engine up? ------------------------------------------------------
$engineUp = $false
try {
    $null = & docker info --format '{{.ServerVersion}}' 2>$null
    if ($LASTEXITCODE -eq 0) { $engineUp = $true }
} catch { $engineUp = $false }

if (-not $engineUp) {
    Write-Log 'WARN' 'docker engine unreachable'
    if ($WhatIfOnly) { Write-Log 'INFO' 'WhatIfOnly: would start Docker Desktop'; exit 0 }
    $dd = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
    if (Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue) {
        Write-Log 'INFO' 'Docker Desktop is running but the engine is not ready yet; leaving it to finish'
    } elseif (Test-Path $dd) {
        Write-Log 'INFO' 'starting Docker Desktop'
        Start-Process -FilePath $dd | Out-Null
    } else {
        Write-Log 'ERROR' "Docker Desktop not found at $dd"
    }
    exit 0
}

# --- Per-fleet check --------------------------------------------------------
$exitCode = 0
foreach ($name in $Fleet) {
    $cfg = $fleets[$name]

    $present = @()
    try {
        $present = @(& docker ps -a --format '{{.Names}}' 2>$null)
    } catch {
        Write-Log 'ERROR' "could not list containers: $($_.Exception.Message)"
        exit 1
    }

    $missing = @($cfg.Containers | Where-Object { $present -notcontains $_ })

    if ($missing.Count -gt 0) {
        Write-Log 'WARN' ("fleet={0} missing container(s): {1}" -f $name, ($missing -join ', '))
        if ($WhatIfOnly) {
            Write-Log 'INFO' "WhatIfOnly: would run fleet.ps1 $name up -d"
            continue
        }
        try {
            & (Join-Path $root 'fleet.ps1') $name up -d
            if ($LASTEXITCODE -eq 0) {
                Write-Log 'INFO' "fleet=$name recovered"
            } else {
                # The usual cause is a missing image plus a build that cannot
                # reach the Ubuntu archive (Mullvad SERVFAILs *.ubuntu.com).
                Write-Log 'ERROR' "fleet=$name 'up -d' exited $LASTEXITCODE; image may need a rebuild"
                $exitCode = 1
            }
        } catch {
            Write-Log 'ERROR' "fleet=$name 'up -d' threw: $($_.Exception.Message)"
            $exitCode = 1
        }
        continue
    }

    # Containers are all present. Advisory GitHub cross-check only.
    if ($cfg.Label -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        try {
            $json = & gh api ("repos/{0}/actions/runners" -f $cfg.Repo) 2>$null
            if ($LASTEXITCODE -eq 0 -and $json) {
                $runners = ($json | ConvertFrom-Json).runners
                $online = @($runners | Where-Object {
                    $_.status -eq 'online' -and ($_.labels | ForEach-Object { $_.name }) -contains $cfg.Label
                })
                if ($online.Count -eq 0) {
                    Write-Log 'WARN' ("fleet={0} containers are up but no ONLINE runner carries label '{1}' - needs a human" -f $name, $cfg.Label)
                    $exitCode = 1
                } else {
                    Write-Log 'INFO' ("fleet={0} healthy ({1} container(s), {2} online '{3}' runner(s))" -f $name, $cfg.Containers.Count, $online.Count, $cfg.Label)
                }
            } else {
                Write-Log 'INFO' "fleet=$name containers present; gh query unavailable, skipping registration check"
            }
        } catch {
            Write-Log 'INFO' "fleet=$name containers present; gh check failed: $($_.Exception.Message)"
        }
    } else {
        Write-Log 'INFO' ("fleet={0} healthy ({1} container(s) present)" -f $name, $cfg.Containers.Count)
    }
}

exit $exitCode
