# Run chkdsk against an already-mounted drive and emit a structured verdict.
param(
    [Parameter(Mandatory=$true)] [ValidatePattern('^[A-Za-z]$')] [string]$DriveLetter,
    [string]$Modes = 'readonly',
    [Parameter(Mandatory=$true)] [string]$Diag,
    [ValidateSet('Clean', 'RepairRequired')] [string]$VerdictShape = 'Clean'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\chkdsk-verdict.ps1"
New-Item -ItemType Directory -Path $Diag -Force | Out-Null

$invokeMode = {
    param([string]$Mode, [string]$LabelSuffix)
    $modeFile = ($Mode -replace '[/\\ ]', '-') + $LabelSuffix
    $log = Join-Path $Diag "chkdsk-$modeFile.txt"
    $exitFile = Join-Path $Diag "chkdsk-$modeFile-exit.txt"
    $arguments = @("${DriveLetter}:")
    if ($Mode -ne 'readonly') { $arguments += $Mode -split ' ' }
    $proc = Start-Process -FilePath chkdsk -ArgumentList $arguments -NoNewWindow -PassThru -Wait -RedirectStandardOutput $log
    "$($proc.ExitCode)" | Out-File $exitFile -Encoding ASCII
    return @{ Exit = $proc.ExitCode; Report = (Get-Content -Raw -LiteralPath $log -EA SilentlyContinue) }
}

try {
    $requestedModes = @($Modes.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $verdict = Invoke-ChkdskVerdict -Modes $requestedModes -InvokeMode $invokeMode -VerdictShape $VerdictShape
    $verdict | ConvertTo-Json -Depth 6 -Compress | Out-File (Join-Path $Diag 'verdict.json') -Encoding ASCII
    if ($verdict.passed) { exit 0 }
    exit 1
} catch {
    [Console]::Error.WriteLine($_)
    exit 2
}
