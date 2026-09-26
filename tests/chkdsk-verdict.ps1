$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\scripts\vm\chkdsk-verdict.ps1"

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw "$Message (got '$Actual', want '$Expected')" }
}

function Invoke-Fixture([hashtable]$Runs, [string[]]$Modes = @('/scan')) {
    $runner = {
        param($Mode, $Suffix)
        $key = "$Mode$Suffix"
        if (-not $Runs.ContainsKey($key)) { throw "unexpected invocation: $key" }
        return $Runs[$key]
    }.GetNewClosure()
    return Invoke-ChkdskVerdict -Modes $Modes -InvokeMode $runner
}

$snapshot11 = Invoke-Fixture @{ '/scan' = @{ Exit = 11; Report = 'A snapshot error occured while scanning this drive.' }; '/F /X-offline-fallback' = @{ Exit = 0; Report = 'Windows has scanned the file system and found no problems.' } }
Assert-Equal $snapshot11.modes['/scan'].state 'not-scanned' 'exit 11 snapshot failure state'
Assert-Equal $snapshot11.modes['/scan-offline-fallback'].state 'scanned' 'exit 11 fallback state'
Assert-Equal $snapshot11.passed $true 'successful exit 11 fallback gates as passed'

$vss13 = Invoke-Fixture @{ '/scan' = @{ Exit = 13; Report = 'VSS could not create a shadow copy.' }; '/F /X-offline-fallback' = @{ Exit = 0; Report = 'complete' } }
Assert-Equal $vss13.modes['/scan'].state 'not-scanned' 'exit 13 VSS failure state'
Assert-Equal $vss13.passed $true 'successful exit 13 fallback gates as passed'

$fallbackFailure = Invoke-Fixture @{ '/scan' = @{ Exit = 11; Report = 'Insufficient storage for shadow copy data.' }; '/F /X-offline-fallback' = @{ Exit = 8; Report = 'could not repair' } }
Assert-Equal $fallbackFailure.modes['/scan-offline-fallback'].state 'failed' 'fallback failure state'
Assert-Equal $fallbackFailure.passed $false 'fallback failure gates as failed'

$ceiling = Invoke-Fixture @{ '/scan' = @{ Exit = 11; Report = 'Errors found. Correcting error in index $I30 for file 60F.' } }
Assert-Equal $ceiling.modes['/scan'].state 'scanned' '60f ceiling remains scanned'
Assert-Equal $ceiling.passed $true '60f ceiling remains accepted'

$success = Invoke-Fixture @{ 'readonly' = @{ Exit = 0; Report = 'clean' }; '/scan' = @{ Exit = 0; Report = 'clean' } } @('readonly', '/scan')
Assert-Equal $success.modes['readonly'].state 'scanned' 'readonly success state'
Assert-Equal $success.modes['/scan'].state 'scanned' 'scan success state'
Assert-Equal $success.passed $true 'normal success'

$trueFailure = Invoke-Fixture @{ '/scan' = @{ Exit = 13; Report = 'The disk contains errors.' } }
Assert-Equal $trueFailure.modes['/scan'].state 'failed' 'non-VSS exit 13 is a true failure'
Assert-Equal $trueFailure.passed $false 'true failure gates as failed'

$json = $snapshot11 | ConvertTo-Json -Depth 6 -Compress | ConvertFrom-Json
Assert-Equal $json.verdict_shape 'clean' 'schema verdict shape'
Assert-Equal $json.modes.'/scan'.state 'not-scanned' 'schema preserves original state'
Assert-Equal $json.modes.'/scan-offline-fallback'.reason 'offline /F /X fallback completed after snapshot/VSS failure' 'schema fallback reason'

Write-Output 'chkdsk verdict tests: ok'
