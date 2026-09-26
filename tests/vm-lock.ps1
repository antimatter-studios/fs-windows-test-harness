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
        [string]$Token,
        [string]$Command = '',
        [int]$LeaseSeconds = 300
    )

    Remove-Item -LiteralPath $capture -Force -ErrorAction SilentlyContinue
    & powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $lockScript `
        -Action $Action `
        -Workdir $workdir `
        -RunId $RunId `
        -OwnerHost 'test-host' `
        -OwnerPid '99999999' `
        -OwnerToken $Token `
        -LeaseSeconds $LeaseSeconds `
        -Command $Command *> $capture
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
    Assert-True ($owner.pid -eq '99999999') 'owner metadata records the untrusted orchestrator pid'

    $contender = Invoke-Lock Acquire 'run-b' 'token-b'
    Assert-True ($contender.ExitCode -eq 73) 'a second owner is rejected'
    Assert-True ($contender.Output -match 'a matrix is already running') 'contention is explained'
    Assert-True ($contender.Output -match 'run_id=run-a') 'contention names the current run'

    # Renew a nearly expired lease without waiting for wall-clock time.
    $owner.renewed_utc = [DateTime]::UtcNow.AddMinutes(-4).ToString('o')
    $owner | ConvertTo-Json | Set-Content -LiteralPath $ownerPath -Encoding UTF8
    $renew = Invoke-Lock Renew 'run-a' 'token-a'
    Assert-True ($renew.ExitCode -eq 0) "live owner renews its lease: $($renew.Output)"
    $renewed = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json
    Assert-True (([DateTime]::UtcNow - [DateTime]::Parse($renewed.renewed_utc).ToUniversalTime()).TotalSeconds -lt 30) 'renewal refreshes VM time'
    Assert-True ($renewed.token -eq 'token-a' -and $renewed.run_id -eq 'run-a') 'renewal preserves ownership'
    Assert-True (@(Get-ChildItem -LiteralPath (Split-Path -Parent $ownerPath) -Filter '.owner-*.json' -Force).Count -eq 0) 'renewal removes temporary metadata'
    Assert-True ((Invoke-Lock Acquire 'run-b' 'token-b').ExitCode -eq 73) 'renewed lease prevents reclamation'
    $wrongRenew = Invoke-Lock Renew 'run-b' 'token-b'
    Assert-True ($wrongRenew.ExitCode -eq 74) 'non-owner cannot renew'
    $verify = Invoke-Lock Verify 'run-a' 'token-a'
    Assert-True ($verify.ExitCode -eq 0) 'live owner can pass a mutation fence'
    $marker = Join-Path $workdir 'mutation.txt'
    $invoke = Invoke-Lock Invoke 'run-a' 'token-a' "Set-Content -LiteralPath '$marker' -Value owned"
    Assert-True ($invoke.ExitCode -eq 0) 'live owner can mutate under the gate'
    Assert-True ((Get-Content -LiteralPath $marker -Raw).Trim() -eq 'owned') 'guarded command ran'

    # A second scenario must wait through a long VM command. The old 15-second
    # operation-gate deadline rejected it even though both shared one owner.
    $started = Join-Path $workdir 'long-operation-started.txt'
    $holder = Start-Job -ScriptBlock {
        param($Script, $Dir, $Marker)
        & powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $Script -Action Invoke -Workdir $Dir -RunId 'run-a' `
            -OwnerHost 'test-host' -OwnerPid '99999999' -OwnerToken 'token-a' `
            -LeaseSeconds 60 -Command "Set-Content -LiteralPath '$Marker' -Value ready; Start-Sleep -Seconds 17" *> $null
        $LASTEXITCODE
    } -ArgumentList $lockScript, $workdir, $started
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $started) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
        Assert-True (Test-Path -LiteralPath $started) 'the first command holds the operation gate'
        $waiting = Invoke-Lock Invoke 'run-a' 'token-a' "Set-Content -LiteralPath '$marker' -Value waited" -LeaseSeconds 60
        Assert-True ($waiting.ExitCode -eq 0) "second command waits beyond 15 seconds: $($waiting.Output)"
        Assert-True ((Get-Content -LiteralPath $marker -Raw).Trim() -eq 'waited') 'waiting command ran after gate release'
    }
    finally {
        $holderResult = @($holder | Wait-Job | Receive-Job)
        $holder | Remove-Job
    }
    Assert-True ($holderResult.Count -eq 1 -and $holderResult[0] -eq 0) 'first long command completed'

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

    # A command holds the operation gate, so no contender can reclaim while it
    # runs. Its owner must still be live when that command returns.
    Assert-True ((Invoke-Lock Acquire 'long-run' 'long-token' -LeaseSeconds 3).ExitCode -eq 0) 'short lease acquires'
    $long = Invoke-Lock Invoke 'long-run' 'long-token' 'Start-Sleep -Seconds 4' -LeaseSeconds 3
    Assert-True ($long.ExitCode -eq 0) 'long guarded command completes'
    $afterLong = Invoke-Lock Verify 'long-run' 'long-token' -LeaseSeconds 3
    Assert-True ($afterLong.ExitCode -eq 0) "long command preserves its lease: $($afterLong.Output)"
    Assert-True ((Invoke-Lock Release 'long-run' 'long-token' -LeaseSeconds 3).ExitCode -eq 0) 'long command owner releases'

    # Expiry uses the VM clock, not the reported orchestrator PID.
    $old = Invoke-Lock Acquire 'stale' 'stale-token'
    Assert-True ($old.ExitCode -eq 0) 'stale fixture acquires'
    $owner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json
    $owner.renewed_utc = [DateTime]::UtcNow.AddMinutes(-20).ToString('o')
    $owner | ConvertTo-Json | Set-Content -LiteralPath $ownerPath -Encoding UTF8
    $recovered = Invoke-Lock Acquire 'replacement' 'new-token'
    Assert-True ($recovered.ExitCode -eq 0) 'expired owner can be replaced'
    Assert-True ((Invoke-Lock Verify 'stale' 'stale-token').ExitCode -eq 74) 'stale owner cannot mutate'
    $staleInvoke = Invoke-Lock Invoke 'stale' 'stale-token' "Set-Content -LiteralPath '$marker' -Value stale"
    Assert-True ($staleInvoke.ExitCode -eq 74) 'stale command is rejected'
    Assert-True ((Get-Content -LiteralPath $marker -Raw).Trim() -eq 'owned') 'stale command made no mutation'
    Assert-True ((Invoke-Lock Renew 'stale' 'stale-token').ExitCode -eq 74) 'stale owner cannot renew'
    Assert-True ((Invoke-Lock Release 'stale' 'stale-token').ExitCode -eq 74) 'stale owner cannot release replacement'
    Assert-True ((Invoke-Lock Verify 'replacement' 'new-token').ExitCode -eq 0) 'replacement still owns lock'
    Assert-True ((Invoke-Lock Release 'replacement' 'new-token').ExitCode -eq 0) 'replacement releases'

    # Concurrent recovery must have exactly one winner.
    Assert-True ((Invoke-Lock Acquire 'race-old' 'race-old-token').ExitCode -eq 0) 'race fixture acquires'
    $owner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json
    $owner.renewed_utc = [DateTime]::UtcNow.AddMinutes(-20).ToString('o')
    $owner | ConvertTo-Json | Set-Content -LiteralPath $ownerPath -Encoding UTF8
    $jobs = 1..6 | ForEach-Object {
        $n = $_
        Start-Job -ScriptBlock {
            param($Script, $Dir, $Number)
            & powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
                -File $Script -Action Acquire -Workdir $Dir -RunId "race-$Number" `
                -OwnerHost test-host -OwnerPid 99999999 -OwnerToken "race-token-$Number" `
                -LeaseSeconds 300 *> $null
            $LASTEXITCODE
        } -ArgumentList $lockScript, $workdir, $n
    }
    $results = @($jobs | Wait-Job | Receive-Job)
    $jobs | Remove-Job
    Assert-True (@($results | Where-Object { $_ -eq 0 }).Count -eq 1) 'exactly one contender reclaims'
    Assert-True (@($results | Where-Object { $_ -eq 73 }).Count -eq 5) 'other contenders see a live lease'
    $winner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json
    Assert-True ((Invoke-Lock Release $winner.run_id $winner.token).ExitCode -eq 0) 'winner releases'

    foreach ($bad in @('missing', 'corrupt')) {
        Assert-True ((Invoke-Lock Acquire "bad-$bad" "bad-$bad-token").ExitCode -eq 0) "$bad fixture acquires"
        if ($bad -eq 'missing') { Remove-Item -LiteralPath $ownerPath }
        else { Set-Content -LiteralPath $ownerPath -Value '{bad json' }
        $tooSoon = Invoke-Lock Acquire 'too-soon' 'too-soon-token'
        Assert-True ($tooSoon.ExitCode -eq 73) "fresh $bad metadata is fenced: $($tooSoon.Output)"
        if ($bad -eq 'corrupt') {
            (Get-Item -LiteralPath $ownerPath -Force).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-20)
        }
        (Get-Item -LiteralPath (Split-Path -Parent $ownerPath) -Force).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-20)
        Assert-True ((Invoke-Lock Acquire "after-$bad" "after-$bad-token").ExitCode -eq 0) "aged $bad metadata recovers"
        Assert-True ((Invoke-Lock Release "after-$bad" "after-$bad-token").ExitCode -eq 0) "aged $bad replacement releases"
    }

    Write-Output 'vm-lock tests passed'
}
finally {
    Remove-Item -LiteralPath $workdir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $capture -Force -ErrorAction SilentlyContinue
}
