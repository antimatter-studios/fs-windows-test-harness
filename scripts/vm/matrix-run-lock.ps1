# matrix-run-lock.ps1 -- renewable, fenced ownership of one VM workdir.
# A metadata gate serializes ownership changes; a second gate spans VM
# commands. A crashed process releases both Windows file locks automatically.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Acquire', 'Renew', 'Verify', 'Invoke', 'Release')]
    [string]$Action,
    [Parameter(Mandatory = $true)] [string]$Workdir,
    [Parameter(Mandatory = $true)] [string]$RunId,
    [Parameter(Mandatory = $true)] [string]$OwnerHost,
    [Parameter(Mandatory = $true)] [string]$OwnerPid,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9-]{1,128}$')]
    [string]$OwnerToken,
    [ValidateRange(1, 86400)] [int]$LeaseSeconds = 1800,
    [string]$Command = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$lockPath = Join-Path $Workdir '.fswth-matrix.lock'
$ownerPath = Join-Path $lockPath 'owner.json'
$gatePath = Join-Path $Workdir '.fswth-matrix.guard'
$operationGatePath = Join-Path $Workdir '.fswth-matrix.operation'

function Read-Owner {
    try {
        $value = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json
        foreach ($field in @('run_id', 'host', 'pid', 'token', 'renewed_utc', 'lease_seconds')) {
            if ($null -eq $value.$field -or [string]$value.$field -eq '') { return $null }
        }
        # ConvertFrom-Json may return a DateTime; Parse stringifies it without
        # its UTC kind and then treats it as local time.
        $timestamp = [DateTimeOffset]$value.renewed_utc
        $seconds = [int]$value.lease_seconds
        if ($seconds -lt 1 -or $seconds -gt 86400) { return $null }
        return @{ Value = $value; Renewed = $timestamp; Seconds = $seconds }
    }
    catch { return $null }
}

function Write-Owner($value) {
    # A crash while writing a replacement cannot leave a half-written JSON
    # file: the old owner.json remains valid until the rename succeeds.
    $temp = Join-Path $lockPath ('.owner-' + [Guid]::NewGuid().ToString('N') + '.json')
    $backup = Join-Path $lockPath ('.owner-backup-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        $value | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding UTF8
        if (Test-Path -LiteralPath $ownerPath) {
            [IO.File]::Replace($temp, $ownerPath, $backup)
        }
        else {
            [IO.File]::Move($temp, $ownerPath)
        }
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
}

function Reject-Owner($reason) {
    [Console]::Error.WriteLine("[run-tests] refusing VM matrix $Action in '$Workdir': $reason")
    exit 74
}

if ($Action -eq 'Acquire') {
    New-Item -ItemType Directory -Path $Workdir -Force | Out-Null
}
elseif (-not (Test-Path -LiteralPath $Workdir -PathType Container)) {
    Reject-Owner 'workdir is missing'
}

function Open-Gate($path) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ($true) {
        try {
            return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate,
                                   [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
}

# A running mutation holds operationGate, preventing reclamation. Renewal
# only needs metadataGate, so long matrix operations do not starve heartbeats.
$operationGate = $null
$gate = $null
if ($Action -in @('Acquire', 'Invoke', 'Release')) {
    $operationGate = Open-Gate $operationGatePath
}
$gate = Open-Gate $gatePath

try {
    $now = [DateTimeOffset]::UtcNow
    $exists = Test-Path -LiteralPath $lockPath -PathType Container
    $stored = if ($exists) { Read-Owner } else { $null }

    if ($Action -eq 'Acquire') {
        if ($exists) {
            if ($null -ne $stored) {
                $age = ($now - $stored.Renewed).TotalSeconds
                $expired = $age -gt $stored.Seconds
                $summary = "run_id=$($stored.Value.run_id), host=$($stored.Value.host), pid=$($stored.Value.pid), renewed_utc=$($stored.Value.renewed_utc)"
            }
            else {
                # Missing/corrupt metadata may be an acquisition interrupted
                # before owner.json was written. Never immediately reclaim it.
                $lastMutation = (Get-Item -LiteralPath $lockPath -Force).LastWriteTimeUtc
                if (Test-Path -LiteralPath $ownerPath -PathType Leaf) {
                    $ownerModified = (Get-Item -LiteralPath $ownerPath -Force).LastWriteTimeUtc
                    if ($ownerModified -gt $lastMutation) { $lastMutation = $ownerModified }
                }
                $age = ($now.UtcDateTime - $lastMutation).TotalSeconds
                $expired = $age -gt $LeaseSeconds
                $summary = 'owner metadata unavailable or corrupt'
            }
            if (-not $expired) {
                [Console]::Error.WriteLine("[run-tests] a matrix is already running in VM workdir '$Workdir' ($summary)")
                exit 73
            }
            Remove-Item -LiteralPath $lockPath -Recurse -Force
        }
        New-Item -ItemType Directory -Path $lockPath | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $lockPath $OwnerToken) | Out-Null
        $owner = [ordered]@{
            run_id = $RunId; host = $OwnerHost; pid = $OwnerPid; token = $OwnerToken
            acquired_utc = $now.ToString('o'); renewed_utc = $now.ToString('o')
            lease_seconds = $LeaseSeconds
        }
        Write-Owner $owner
        Write-Output "[run-tests] VM matrix lock acquired: $lockPath (run_id=$RunId, host=$OwnerHost, pid=$OwnerPid)"
        exit 0
    }

    if (-not $exists -or $null -eq $stored) { Reject-Owner 'owner metadata is missing or corrupt' }
    if ($stored.Value.token -cne $OwnerToken -or $stored.Value.run_id -cne $RunId) {
        Reject-Owner "ownership changed (run_id=$($stored.Value.run_id))"
    }
    if (($now - $stored.Renewed).TotalSeconds -gt $stored.Seconds) {
        Reject-Owner 'lease expired'
    }

    switch ($Action) {
        'Verify' { exit 0 }
        'Renew' {
            $stored.Value.renewed_utc = $now.ToString('o')
            Write-Owner $stored.Value
            exit 0
        }
        'Release' {
            Remove-Item -LiteralPath $lockPath -Recurse -Force
            Write-Output "[run-tests] VM matrix lock released: $lockPath (run_id=$RunId)"
            exit 0
        }
        'Invoke' {
            if ([string]::IsNullOrWhiteSpace($Command)) { throw 'Invoke requires -Command' }
            # Keep operationGate for the command, but let Renew take the
            # metadata gate while a long-running command is in flight.
            $gate.Dispose()
            $gate = $null
            $global:LASTEXITCODE = 0
            & ([ScriptBlock]::Create($Command))
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            exit 0
        }
    }
}
finally {
    if ($null -ne $gate) { $gate.Dispose() }
    if ($null -ne $operationGate) { $operationGate.Dispose() }
}
