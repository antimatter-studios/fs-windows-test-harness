param(
    [Parameter(Mandatory = $true)] [string]$Root,
    [int]$Rounds = 3
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$memfs = Join-Path ${env:ProgramFiles(x86)} 'WinFsp\bin\memfs-a64.exe'
if (-not (Test-Path -LiteralPath $memfs)) { throw "WinFsp ARM64 memfs is required: $memfs" }
$owned = [Collections.Generic.List[System.Diagnostics.Process]]::new()
$results = [Collections.Generic.List[object]]::new()
$sequence = 0
New-Item -ItemType Directory -Path $Root -Force | Out-Null

function Start-Memfs([string]$Workdir, [string]$Target) {
    New-Item -ItemType Directory -Path $Workdir -Force | Out-Null
    $script:sequence++
    $log = Join-Path $Workdir "memfs-$script:sequence"
    $process = Start-Process -FilePath $memfs -ArgumentList @('-i', '-F', 'NTFS', '-m', $Target) `
        -PassThru -NoNewWindow -RedirectStandardOutput "$log.out" -RedirectStandardError "$log.err"
    $null = $process.Handle
    $owned.Add($process)
    return $process
}

function Mounted([string]$Target) {
    if ($Target -match '^[A-Z]:$') { return Test-Path -LiteralPath "$Target\" }
    $item = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
    return ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Wait-Mount($Process, [string]$Target) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Mounted $Target)) {
        if ($Process.HasExited) { throw "memfs exited $($Process.ExitCode) before mounting $Target" }
        if ($timer.Elapsed.TotalSeconds -gt 30) { throw "memfs mount timed out: $Target" }
        Start-Sleep -Milliseconds 50
    }
}

function Stop-Memfs($Process, [string]$Target) {
    if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force }
    $Process.WaitForExit()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (Mounted $Target) {
        if ($timer.Elapsed.TotalSeconds -gt 30) { throw "memfs unmount timed out: $Target" }
        Start-Sleep -Milliseconds 50
    }
}

try {
    foreach ($round in 1..$Rounds) {
        foreach ($kind in @('drive', 'directory')) {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $firstDir = Join-Path $Root "$round-$kind-a"
            $secondDir = Join-Path $Root "$round-$kind-b"
            $firstTarget = if ($kind -eq 'drive') { 'X:' } else { Join-Path $firstDir 'mount' }
            $secondTarget = if ($kind -eq 'drive') { 'Y:' } else { Join-Path $secondDir 'mount' }
            if ((Mounted $firstTarget) -or (Mounted $secondTarget)) { throw 'Test mount target is already in use' }
            $first = Start-Memfs $firstDir $firstTarget
            Wait-Mount $first $firstTarget
            $second = Start-Memfs $secondDir $secondTarget
            Wait-Mount $second $secondTarget
            Set-Content -LiteralPath "$firstDir\run.txt" -Value first
            Set-Content -LiteralPath "$secondDir\run.txt" -Value second
            Set-Content -LiteralPath "$firstTarget\sentinel.txt" -Value first
            Set-Content -LiteralPath "$secondTarget\sentinel.txt" -Value second
            if ((Get-Content -LiteralPath "$firstTarget\sentinel.txt") -ne 'first' -or
                (Get-Content -LiteralPath "$secondTarget\sentinel.txt") -ne 'second' -or
                (Get-Content -LiteralPath "$firstDir\run.txt") -ne 'first' -or
                (Get-Content -LiteralPath "$secondDir\run.txt") -ne 'second') {
                throw 'Disjoint workdirs or mounts interfered'
            }
            $results.Add([ordered]@{
                round = $round; kind = $kind; case = 'disjoint'; passed = $true
                elapsed_seconds = $timer.Elapsed.TotalSeconds
                first_pid = $first.Id; second_pid = $second.Id
                first_target = $firstTarget; second_target = $secondTarget
            })
            Stop-Memfs $second $secondTarget
            $timer.Restart()
            $collision = Start-Memfs $secondDir $firstTarget
            if (-not $collision.WaitForExit(30000)) { throw "Conflicting mount did not exit: $firstTarget" }
            if ($null -eq $collision.ExitCode -or $collision.ExitCode -eq 0) {
                throw 'Conflicting mount did not report a nonzero exit code'
            }
            if ($first.HasExited -or (Get-Content -LiteralPath "$firstTarget\sentinel.txt") -ne 'first') {
                throw 'Conflicting mount damaged the first run'
            }
            $results.Add([ordered]@{
                round = $round; kind = $kind; case = 'collision'; passed = $true
                elapsed_seconds = $timer.Elapsed.TotalSeconds; exit_code = $collision.ExitCode
                first_target = $firstTarget; second_target = $firstTarget
            })
            Stop-Memfs $first $firstTarget
        }
    }
    $results | ConvertTo-Json -Depth 5
}
finally {
    foreach ($process in $owned) {
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction Continue }
    }
}
