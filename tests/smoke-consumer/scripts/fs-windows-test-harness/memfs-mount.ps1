# memfs-mount.ps1 -- the smoke consumer's "driver mount" command.
#
# Mounts a tar-archive image on a drive letter using WinFsp's sample
# memfs, a real user-mode WinFsp filesystem, and stays in the
# foreground until it is killed -- the same contract a real driver's
# `mount` subcommand has with the harness's Invoke-WithMount
# (scripts/vm/_lib.ps1): print a ready line once the volume is usable,
# then keep serving until the process tree is killed.
#
# memfs keeps everything in memory and has no image format, while the
# harness remounts the image for every recipe step. So this launcher
# does the image I/O a real driver does inside itself:
#
#   * mount:   start memfs on the drive, wait for the volume, extract
#              the image into it, then print the ready line.
#   * serving: poll the volume; whenever its tree changes, copy it out
#              and repack it into the image (written to a temp file, then swapped in
#              with a rename, so the image is never half-written).
#
# Invoke-WithMount unmounts by force-killing the process tree after a
# fixed quiesce window (2.5 s after the op returns). That window is the
# harness's own flush contract for WinFsp drivers; this launcher meets
# it by polling every -SyncIntervalMs (default 100 ms) and only writing
# when something changed, so a volume at rest is never mid-repack when
# the kill lands.
#
# Args:
#   -Image           Path to the tar image on this host. Must exist.
#   -Drive           Drive letter, no colon.
#   -SyncIntervalMs  Poll interval for image write-back.
#   -ReadyTimeoutSeconds  How long to wait for memfs to expose the drive.

param(
    [Parameter(Mandatory = $true)] [string]$Image,
    [Parameter(Mandatory = $true)] [string]$Drive,
    [int]$SyncIntervalMs = 100,
    [int]$ReadyTimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'

function Fail([string]$msg) {
    [Console]::Error.WriteLine("memfs-mount: $msg")
    [Console]::Error.Flush()
    exit 1
}

# WinFsp records its install dir in the registry (32-bit view); fall back
# to the default location. Pick the memfs build matching this machine.
$winfsp = $null
foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\WinFsp', 'HKLM:\SOFTWARE\WinFsp') {
    $dir = (Get-ItemProperty -Path $key -Name InstallDir -ErrorAction SilentlyContinue).InstallDir
    if ($dir) { $winfsp = $dir; break }
}
if (-not $winfsp) { $winfsp = Join-Path ${env:ProgramFiles(x86)} 'WinFsp' }
$arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' { 'a64' } 'x86' { 'x86' } default { 'x64' } }
$memfs = Join-Path $winfsp "bin\memfs-$arch.exe"
if (-not (Test-Path -LiteralPath $memfs)) { Fail "memfs not found at $memfs -- is WinFsp installed?" }

# Windows' bsdtar, by full path: a GNU tar earlier on PATH (Git for
# Windows) reads "C:/..." as a remote host.
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'

$Image = [System.IO.Path]::GetFullPath($Image)
if (-not (Test-Path -LiteralPath $Image -PathType Leaf)) { Fail "image not found: $Image" }
$root = "${Drive}:\"
if (Test-Path -LiteralPath $root) { Fail "drive ${Drive}: is already in use" }

$log = "$Image.memfs.log"
$proc = Start-Process -FilePath $memfs `
    -ArgumentList @('-i', '-F', 'NTFS', '-m', "${Drive}:") `
    -NoNewWindow -PassThru `
    -RedirectStandardOutput "$log.out" -RedirectStandardError $log

$deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
while (-not (Test-Path -LiteralPath $root)) {
    if ($proc.HasExited) {
        Fail "memfs exited before mounting (code $($proc.ExitCode)): $(Get-Content -Raw -LiteralPath $log -EA SilentlyContinue)"
    }
    if ((Get-Date) -gt $deadline) {
        Stop-Process -Id $proc.Id -Force -EA SilentlyContinue
        Fail "drive ${Drive}: did not appear within ${ReadyTimeoutSeconds}s"
    }
    Start-Sleep -Milliseconds 50
}

$out = & $tar -xf $Image -C $root 2>&1
if ($LASTEXITCODE -ne 0) {
    Stop-Process -Id $proc.Id -Force -EA SilentlyContinue
    Fail "could not load image $Image into ${Drive}: (tar exit $LASTEXITCODE): $out"
}

function Get-TreeSignature {
    # Path, size and mtime of every entry. A write, create, rename or
    # delete on the volume changes at least one of them. Enumeration can
    # race an op in flight; a partial answer just differs from the last
    # saved one and is retaken on the next poll.
    $lines = Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            $len = if ($_.PSIsContainer) { 'd' } else { $_.Length }
            "$($_.FullName)|$len|$($_.LastWriteTimeUtc.Ticks)"
        } | Sort-Object
    return ($lines -join "`n")
}

$syncLog = "$Image.sync.log"
function Write-SyncLog([string]$msg) {
    Add-Content -LiteralPath $syncLog -Value "$((Get-Date).ToString('HH:mm:ss.fff')) [pid $PID] $msg"
}

function Save-Image {
    # Copy the volume out to a staging dir on the system drive and pack
    # that: bsdtar cannot walk a WinFsp drive root itself (it fails with
    # "Couldn't visit directory" on the \\?\X:\ path). Build the new
    # image beside the old one, then swap it in, so a kill at any instant
    # leaves either the previous image or the new one.
    $stage = "$Image.stage"
    $tmp = "$Image.saving"
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage | Out-Null
    Get-ChildItem -LiteralPath $root -Force |
        Copy-Item -Destination $stage -Recurse -Force
    $out = & $tar -cf $tmp -C $stage . 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-SyncLog "tar -cf failed (exit $LASTEXITCODE): $out"
        return $false
    }
    Move-Item -LiteralPath $tmp -Destination $Image -Force
    return $true
}

$saved = Get-TreeSignature
Write-SyncLog "mounted ${Drive}: from $Image ($((($saved -split "`n") | Where-Object { $_ }).Count) entries)"
[Console]::Out.WriteLine("memfs mounted at ${Drive}: (image $Image, memfs pid $($proc.Id))")
[Console]::Out.Flush()

while ($true) {
    if ($proc.HasExited) { Fail "memfs exited while mounted (code $($proc.ExitCode))" }
    $sig = Get-TreeSignature
    if ($sig -ne $saved) {
        try {
            if (Save-Image) {
                $saved = $sig
                Write-SyncLog "saved image ($((($sig -split "`n") | Where-Object { $_ }).Count) entries)"
            }
        } catch {
            # A file still open for writing, typically. Retry next poll.
            Write-SyncLog "save failed, retrying: $_"
        }
    }
    Start-Sleep -Milliseconds $SyncIntervalMs
}
