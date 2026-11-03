param(
    [Parameter(Mandatory = $true)] [string]$Root,
    [Parameter(Mandatory = $true)] [string]$Peer,
    [Parameter(Mandatory = $true)] [string]$Drive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$memfs = Join-Path ${env:ProgramFiles(x86)} 'WinFsp\bin\memfs-a64.exe'
$process = $null
$start = [DateTimeOffset]::UtcNow
New-Item -ItemType Directory -Path $Root -Force | Out-Null
if (Test-Path "${Drive}:\") { throw "Drive ${Drive}: is occupied" }

function Wait-For([string]$Path) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $Path)) {
        if ($process.HasExited) { throw "memfs exited $($process.ExitCode)" }
        if ($timer.Elapsed.TotalSeconds -gt 120) { throw "Timed out waiting for $Path" }
        Start-Sleep -Milliseconds 50
    }
}

try {
    $process = Start-Process -FilePath $memfs -ArgumentList @('-i', '-F', 'NTFS', '-m', "${Drive}:") `
        -PassThru -NoNewWindow -RedirectStandardOutput "$Root\memfs.out" -RedirectStandardError "$Root\memfs.err"
    $null = $process.Handle
    Wait-For "${Drive}:\"
    Set-Content -LiteralPath "$Root\ready" -Value $Drive
    Wait-For "$Peer\ready"
    foreach ($index in 1..100) {
        Set-Content -LiteralPath "${Drive}:\file-$index.txt" -Value "$Root-$index"
    }
    Set-Content -LiteralPath "$Root\written" -Value complete
    Wait-For "$Peer\written"
    foreach ($index in 1..100) {
        if ((Get-Content -LiteralPath "${Drive}:\file-$index.txt") -ne "$Root-$index") {
            throw "Another run changed ${Drive}:\file-$index.txt"
        }
    }
    [ordered]@{
        root = $Root; peer = $Peer; drive = $Drive; files_verified = 100
        start_utc = $start.ToString('o'); end_utc = [DateTimeOffset]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath "$Root\result.json"
    '100 files verified with a second mounted run'
}
finally {
    if ($null -ne $process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
    }
}
