# Structured chkdsk verdicts shared by filesystem consumers.

function Test-ChkdskSnapshotFailure {
    param([AllowEmptyString()] [string]$Report)

    return $Report -match '(?i)snapshot\s+error|shadow\s+cop(?:y|ies)|\bVSS\b|volume\s+shadow\s+copy'
}

function New-ChkdskModeResult {
    param(
        [Parameter(Mandatory=$true)] [string]$Mode,
        [Parameter(Mandatory=$true)] [int]$Exit,
        [AllowEmptyString()] [string]$Report = ''
    )

    if ($Mode -eq '/scan' -and $Exit -in 11, 13 -and (Test-ChkdskSnapshotFailure $Report)) {
        return [ordered]@{
            exit = $Exit
            state = 'not-scanned'
            reason = 'snapshot/VSS failure prevented the online scan'
        }
    }
    if ($Exit -eq 0) {
        return [ordered]@{ exit = $Exit; state = 'scanned'; reason = 'chkdsk completed successfully' }
    }
    if ($Mode -eq '/scan' -and $Exit -eq 11) {
        return [ordered]@{
            exit = $Exit
            state = 'scanned'
            reason = 'accepted known frs.cxx 60f ceiling'
        }
    }
    return [ordered]@{ exit = $Exit; state = 'failed'; reason = "chkdsk exited $Exit" }
}

function Invoke-ChkdskVerdict {
    param(
        [Parameter(Mandatory=$true)] [string[]]$Modes,
        [Parameter(Mandatory=$true)] [scriptblock]$InvokeMode,
        [ValidateSet('Clean', 'RepairRequired')] [string]$VerdictShape = 'Clean'
    )

    $modeResults = [ordered]@{}
    $passed = $true

    if ($VerdictShape -eq 'Clean') {
        foreach ($mode in $Modes) {
            $run = & $InvokeMode $mode ''
            $result = New-ChkdskModeResult -Mode $mode -Exit $run.Exit -Report $run.Report
            $modeResults[$mode] = $result

            if ($result.state -eq 'not-scanned') {
                # /F /X forces an offline check and avoids the snapshot path.
                # Keep the failed online attempt as not-scanned and record the
                # fallback separately so evidence consumers can see both.
                $fallbackRun = & $InvokeMode '/F /X' '-offline-fallback'
                $fallback = New-ChkdskModeResult -Mode '/F /X' -Exit $fallbackRun.Exit -Report $fallbackRun.Report
                if ($fallback.state -eq 'scanned') {
                    $fallback.reason = 'offline /F /X fallback completed after snapshot/VSS failure'
                } else {
                    $fallback.reason = "offline /F /X fallback failed (exit $($fallbackRun.Exit))"
                }
                $modeResults['/scan-offline-fallback'] = $fallback
                if ($fallback.state -ne 'scanned') { $passed = $false }
            } elseif ($result.state -ne 'scanned') {
                $passed = $false
            }
        }
    } else {
        $preScan = $null
        foreach ($mode in $Modes) {
            $run = & $InvokeMode $mode ''
            $result = New-ChkdskModeResult -Mode $mode -Exit $run.Exit -Report $run.Report
            $modeResults[$mode] = $result
            if ($mode -eq '/scan') { $preScan = $result }
        }
        if ($null -eq $preScan) { throw "RepairRequired requires '/scan' in -Modes" }

        $fixRun = & $InvokeMode '/F /X' '-fix'
        $fix = New-ChkdskModeResult -Mode '/F /X' -Exit $fixRun.Exit -Report $fixRun.Report
        $modeResults['/F /X'] = $fix
        $postRun = & $InvokeMode '/scan' '-post'
        $post = New-ChkdskModeResult -Mode '/scan' -Exit $postRun.Exit -Report $postRun.Report
        $modeResults['/scan-post'] = $post
        $passed = $preScan.state -eq 'failed' -and $fix.state -eq 'scanned' -and $post.state -eq 'scanned'
    }

    return [ordered]@{
        passed = $passed
        verdict_shape = $VerdictShape.ToLowerInvariant().Replace('repairrequired', 'repair-required')
        modes = $modeResults
    }
}
