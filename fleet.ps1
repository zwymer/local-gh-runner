<#
.SYNOPSIS
  Run a docker compose command against exactly one runner fleet.

.DESCRIPTION
  Every fleet lives in this one directory and shares compose.base.yml, so the
  project name and the -f list have to be right or you act on the wrong fleet.
  This wrapper supplies both, so they cannot be wrong.

  It also prepends Docker's bin directory to PATH. docker-credential-wincred
  lives there and is not on PATH by default; without it every build dies during
  "load metadata for docker.io/library/ubuntu" with an opaque
  "error getting credentials" failure that looks nothing like a PATH problem.

.EXAMPLE
  ./fleet.ps1 edtok up -d
  ./fleet.ps1 edtok ps
  ./fleet.ps1 leetspeak down
  ./fleet.ps1 edtok up -d --build
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('edtok', 'leetspeak')]
    [string]$Fleet,

    [Parameter(Mandatory = $true, Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$ComposeArgs
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath

$projects = @{
    'edtok'     = 'local-gh-runner'
    'leetspeak' = 'leetspeak-gh-runner'
}
$project = $projects[$Fleet]

$dockerBin = 'C:\Program Files\Docker\Docker\resources\bin'
if ((Test-Path $dockerBin) -and ($env:PATH -notlike "*$dockerBin*")) {
    $env:PATH = "$env:PATH;$dockerBin"
}

$base = Join-Path $root 'compose.base.yml'
$overlay = Join-Path $root "compose.$Fleet.yml"
foreach ($f in @($base, $overlay)) {
    if (-not (Test-Path $f)) { throw "missing compose file: $f" }
}

Write-Host "fleet=$Fleet project=$project -> docker compose $($ComposeArgs -join ' ')"
& docker compose -p $project -f $base -f $overlay @ComposeArgs
exit $LASTEXITCODE
