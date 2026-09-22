# Unit/regression tests for scripts/vm/matrix-run-lock.ps1.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$lockScript = Join-Path $repoRoot 'scripts/vm/matrix-run-lock.ps1'
$workdir = Join-Path ([IO.Path]::GetTempPath()) ("fswth-vm-lock-" + [Guid]::NewGuid())
$capture = Join-Path ([IO.Path]::GetTempPath()) ("fswth-vm-lock-output-" + [Guid]::NewGuid())

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "assertion failed: $Message"
    }
}

function Invoke-Lock {
    param(
        [string]$Action,
        [string]$RunId,
        [string]$Token
    )

    Remove-Item -LiteralPath $capture -Force -ErrorAction SilentlyContinue
    & powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $lockScript `
        -Action $Action `
        -Workdir $workdir `
        -RunId $RunId `
        -OwnerHost 'test-host' `
        -OwnerPid '1234' `
        -OwnerToken $Token *> $capture
    $exitCode = $LASTEXITCODE
    $output = if (Test-Path -LiteralPath $capture) {
        Get-Content -LiteralPath $capture -Raw
    }
    else {
        ''
    }
    return @{ ExitCode = $exitCode; Output = $output }
}

try {
    $first = Invoke-Lock Acquire 'run-a' 'token-a'
    Assert-True ($first.ExitCode -eq 0) 'the first owner acquires the lock'

    $ownerPath = Join-Path $workdir '.fswth-matrix.lock/owner.json'
    Assert-True (Test-Path -LiteralPath $ownerPath -PathType Leaf) 'owner metadata is written'
    $owner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json
    Assert-True ($owner.run_id -eq 'run-a') 'owner metadata records the run id'
    Assert-True ($owner.host -eq 'test-host') 'owner metadata records the host'
    Assert-True ($owner.pid -eq '1234') 'owner metadata records the pid'

    $contender = Invoke-Lock Acquire 'run-b' 'token-b'
    Assert-True ($contender.ExitCode -eq 73) 'a second owner is rejected'
    Assert-True ($contender.Output -match 'a matrix is already running') 'contention is explained'
    Assert-True ($contender.Output -match 'run_id=run-a') 'contention names the current run'

    $wrongRelease = Invoke-Lock Release 'run-b' 'token-b'
    Assert-True ($wrongRelease.ExitCode -eq 74) 'a non-owner cannot release the lock'
    Assert-True (Test-Path -LiteralPath $ownerPath -PathType Leaf) 'failed release preserves the lock'

    $release = Invoke-Lock Release 'run-a' 'token-a'
    Assert-True ($release.ExitCode -eq 0) 'the owner releases the lock'
    Assert-True (-not (Test-Path -LiteralPath (Split-Path -Parent $ownerPath))) 'release removes the lock directory'

    $afterRelease = Invoke-Lock Acquire 'run-b' 'token-b'
    Assert-True ($afterRelease.ExitCode -eq 0) 'a later run can acquire after release'
    $finalRelease = Invoke-Lock Release 'run-b' 'token-b'
    Assert-True ($finalRelease.ExitCode -eq 0) 'the later owner releases cleanly'

    Write-Output 'vm-lock tests passed'
}
finally {
    Remove-Item -LiteralPath $workdir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $capture -Force -ErrorAction SilentlyContinue
}
