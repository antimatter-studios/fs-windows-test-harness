# matrix-run-lock.ps1 -- exclusive ownership of one VM workdir.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Acquire', 'Release')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$Workdir,

    [Parameter(Mandatory = $true)]
    [string]$RunId,

    [Parameter(Mandatory = $true)]
    [string]$OwnerHost,

    [Parameter(Mandatory = $true)]
    [string]$OwnerPid,

    [Parameter(Mandatory = $true)]
    [string]$OwnerToken
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$lockPath = Join-Path $Workdir '.fswth-matrix.lock'
$ownerPath = Join-Path $lockPath 'owner.json'

function Read-OwnerSummary {
    if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf)) {
        return 'owner metadata unavailable'
    }

    try {
        $owner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json
        return "run_id=$($owner.run_id), host=$($owner.host), pid=$($owner.pid), acquired_utc=$($owner.acquired_utc)"
    }
    catch {
        return "owner metadata unreadable: $($_.Exception.Message)"
    }
}

if ($Action -eq 'Acquire') {
    New-Item -ItemType Directory -Path $Workdir -Force | Out-Null

    try {
        # New-Item without -Force is the atomic claim: exactly one process
        # can create this directory in a shared Windows workdir.
        New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null
    }
    catch {
        $ownerSummary = Read-OwnerSummary
        [Console]::Error.WriteLine(
            "[run-tests] a matrix is already running in VM workdir '$Workdir' ($ownerSummary)"
        )
        exit 73
    }

    try {
        $owner = [ordered]@{
            run_id      = $RunId
            host        = $OwnerHost
            pid         = $OwnerPid
            token       = $OwnerToken
            acquired_utc = [DateTime]::UtcNow.ToString('o')
        }
        $owner | ConvertTo-Json | Set-Content -LiteralPath $ownerPath -Encoding UTF8
        Write-Output "[run-tests] VM matrix lock acquired: $lockPath (run_id=$RunId, host=$OwnerHost, pid=$OwnerPid)"
    }
    catch {
        Remove-Item -LiteralPath $lockPath -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }

    exit 0
}

if (-not (Test-Path -LiteralPath $lockPath -PathType Container)) {
    exit 0
}

$ownerTokenOnDisk = $null
try {
    $ownerTokenOnDisk = (Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json).token
}
catch {
    [Console]::Error.WriteLine(
        "[run-tests] refusing to release VM matrix lock '$lockPath': $($_.Exception.Message)"
    )
    exit 74
}

if ($ownerTokenOnDisk -ne $OwnerToken) {
    [Console]::Error.WriteLine(
        "[run-tests] refusing to release VM matrix lock '$lockPath': ownership changed ($(Read-OwnerSummary))"
    )
    exit 74
}

Remove-Item -LiteralPath $lockPath -Recurse -Force
Write-Output "[run-tests] VM matrix lock released: $lockPath (run_id=$RunId)"
