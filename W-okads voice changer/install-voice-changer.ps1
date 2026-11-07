<#
=============================================================================
  install-voice-changer.ps1
  Installs w-okada's Realtime Voice Changer on Windows 10/11 (64-bit).

  - Detects the GPU and picks the right official prebuilt package:
        NVIDIA (CUDA build)  |  AMD / Intel / CPU-only (DirectML build)
  - Installs the Visual C++ runtime and VB-Audio Virtual Cable if missing
  - Resumable download with progress bar, speed and ETA, SHA256 verification
  - Extraction with progress, launcher + desktop shortcut
  - Full log in %USERPROFILE%\voice-changer-logs\
  - Never closes on its own: success, failure or crash, it reports what
    happened and waits for Enter (use -NoPause for unattended runs)

  Easiest way to run it: double-click install-voice-changer.bat
  Or:  powershell -ExecutionPolicy Bypass -File install-voice-changer.ps1 [options]

  Options:
    -InstallDir PATH        Install location (default: C:\VoiceChanger)
    -Backend auto|cuda|dml  Force a package (dml = AMD/Intel/CPU)
    -Version 1.5.3.18a      Install a specific version instead of the latest
    -SkipVBCable            Don't install VB-Audio Virtual Cable
    -NoShortcut             Don't create a desktop shortcut
    -KeepZip                Keep the downloaded zip after extracting
    -AddDefenderExclusion   Exclude the install folder from Defender scanning
                            (much faster extraction and startup)
    -NoPause                Don't wait for Enter at the end
=============================================================================
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "$env:SystemDrive\VoiceChanger",
    [ValidateSet('auto', 'cuda', 'dml')][string]$Backend = 'auto',
    [string]$Version = '',
    [switch]$SkipVBCable,
    [switch]$NoShortcut,
    [switch]$KeepZip,
    [switch]$AddDefenderExclusion,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # built-in progress bars are very slow in PS 5.1

# ------------------------------------------------------------------ constants
$HfRepo          = 'wok000/vcclient000'
$HfApi           = "https://huggingface.co/api/models/$HfRepo/tree/main"
$HfResolve       = "https://huggingface.co/$HfRepo/resolve/main"
$FallbackVersion = '1.5.3.18a'
$VcRedistUrl     = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
$VbCableUrls     = @(
    'https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip',
    'https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack43.zip'
)
$VariantNames    = @{ cuda = 'onnxgpu-cuda'; dml = 'onnxdirectML-cuda' }

# -------------------------------------------------------------------- logging
$LogDir = Join-Path $env:USERPROFILE 'voice-changer-logs'
try { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null } catch { $LogDir = $env:TEMP }
$LogFile = Join-Path $LogDir ("install-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-Log([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    try { [IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine) } catch { }
}

$script:IsConsole = $false
try { $script:IsConsole = (-not [Console]::IsOutputRedirected) -and ([Console]::WindowWidth -gt 20) } catch { }

function Get-ConsoleWidth {
    try { return [Math]::Max([Console]::WindowWidth - 1, 40) } catch { return 100 }
}
function Write-ProgressLine([string]$Text) {
    if (-not $script:IsConsole) { return }
    $w = Get-ConsoleWidth
    if ($Text.Length -gt $w) { $Text = $Text.Substring(0, $w) }
    [Console]::Write("`r" + $Text.PadRight($w))
}
function Clear-ProgressLine {
    if (-not $script:IsConsole) { return }
    $w = Get-ConsoleWidth
    [Console]::Write("`r" + (' ' * $w) + "`r")
}

function Write-Info([string]$m) { Clear-ProgressLine; Write-Host '[*] ' -ForegroundColor Cyan   -NoNewline; Write-Host $m; Write-Log "[*] $m" }
function Write-Ok  ([string]$m) { Clear-ProgressLine; Write-Host '[+] ' -ForegroundColor Green  -NoNewline; Write-Host $m; Write-Log "[+] $m" }
function Write-Warn([string]$m) { Clear-ProgressLine; Write-Host '[!] ' -ForegroundColor Yellow -NoNewline; Write-Host $m; Write-Log "[!] $m" }
function Write-Err ([string]$m) { Clear-ProgressLine; Write-Host '[x] ' -ForegroundColor Red    -NoNewline; Write-Host $m; Write-Log "[x] $m" }

function Format-Bytes([double]$b) {
    $u = 'B', 'KB', 'MB', 'GB', 'TB'; $i = 0
    while ($b -ge 1024 -and $i -lt 4) { $b /= 1024; $i++ }
    if ($i -eq 0) { return ('{0:N0} {1}' -f $b, $u[$i]) }
    return ('{0:N1} {1}' -f $b, $u[$i])
}
function Format-Duration([double]$s) {
    if ($s -lt 0 -or [double]::IsInfinity($s) -or [double]::IsNaN($s)) { return '--:--' }
    $t = [TimeSpan]::FromSeconds([Math]::Round($s))
    if ($t.TotalHours -ge 1) { return ('{0}h{1:00}m' -f [int][Math]::Floor($t.TotalHours), $t.Minutes) }
    return ('{0}m{1:00}s' -f $t.Minutes, $t.Seconds)
}
function Format-Bar([double]$pct, [int]$width = 30) {
    if ($pct -lt 0) { $pct = 0 }; if ($pct -gt 100) { $pct = 100 }
    $f = [int][Math]::Floor($pct / 100 * $width)
    return '[' + ('#' * $f) + ('-' * ($width - $f)) + ']'
}

# ----------------------------------------------------------------- step state
$Steps = @(
    'Preflight checks',
    'Hardware detection',
    'Find latest release',
    'Visual C++ runtime',
    'Download',
    'Verify download',
    'Extract',
    'Launcher and shortcut',
    'VB-Audio Virtual Cable',
    'Final checks'
)
$script:CurrentStep = 'startup'
$script:FailMessage = $null
$script:Status = 'running'

function Start-Step([int]$n) {
    $script:CurrentStep = $Steps[$n - 1]
    $pct = ($n - 1) * 100 / $Steps.Count
    Write-Host ''
    Write-Host ('{0} {1,3:N0}%  Step {2}/{3}: {4}' -f (Format-Bar $pct), $pct, $n, $Steps.Count, $script:CurrentStep) -ForegroundColor White
    Write-Log "================ STEP $n/$($Steps.Count): $($script:CurrentStep) ================"
}

function Stop-Install([string]$Message) {
    $script:FailMessage = $Message
    throw "INSTALLER_FAIL: $Message"
}

function Show-LogTail {
    Write-Host ''
    Write-Host '---- Last 25 lines of the log ----' -ForegroundColor White
    try { Get-Content -LiteralPath $LogFile -Tail 25 | ForEach-Object { Write-Host $_ } } catch { }
    Write-Host '----------------------------------' -ForegroundColor White
}

function Show-Hints {
    Write-Host ''
    Write-Host 'Things to check:' -ForegroundColor White
    switch ($script:CurrentStep) {
        'Preflight checks' {
            Write-Host ' - Make sure the machine has internet access and enough free disk space.' }
        'Find latest release' {
            Write-Host ' - huggingface.co may be blocked or down. Try again later, or use -Version 1.5.3.18a.' }
        'Visual C++ runtime' {
            Write-Host ' - Accept the admin (UAC) prompt, or install it manually from https://aka.ms/vs/17/release/vc_redist.x64.exe' }
        'Download' {
            Write-Host ' - Just run the installer again: the download resumes where it stopped.'
            Write-Host ' - Check free disk space and that huggingface.co is reachable.' }
        'Verify download' {
            Write-Host ' - The file is corrupt. The installer deleted it; run again to re-download.' }
        'Extract' {
            Write-Host ' - Antivirus often locks or slows files here. Try -AddDefenderExclusion.'
            Write-Host ' - "Path too long": use a shorter -InstallDir such as C:\VC' }
        'VB-Audio Virtual Cable' {
            Write-Host ' - Accept the UAC prompt, or install manually from https://vb-audio.com/Cable/' }
        default {
            Write-Host ' - Read the log above. Re-running the installer is safe.' }
    }
}

# ------------------------------------------------------------------- helpers
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

function Invoke-Native([string]$File, [string[]]$ArgList) {
    # Runs a console program without PowerShell turning its stderr into a fatal error.
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $File @ArgList 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } catch {
        $out = @($_.Exception.Message); $code = -1
    } finally {
        $ErrorActionPreference = $old
    }
    Write-Log ("native: $File $($ArgList -join ' ') -> exit $code")
    foreach ($l in @($out)) { Write-Log "    $l" }
    return [pscustomobject]@{ Output = @($out); ExitCode = $code }
}

function Invoke-Elevated([string]$File, [string]$ArgString) {
    # Returns the exit code. Throws if the user declines the UAC prompt.
    Write-Log "elevated: $File $ArgString"
    if ($IsAdmin) {
        $p = Start-Process -FilePath $File -ArgumentList $ArgString -Wait -PassThru
    } else {
        $p = Start-Process -FilePath $File -ArgumentList $ArgString -Verb RunAs -Wait -PassThru
    }
    Write-Log "elevated exit code: $($p.ExitCode)"
    return $p.ExitCode
}

function Save-Download([string]$Url, [string]$OutFile, [long]$ExpectedSize, [string]$Label) {
    $maxAttempts = 6
    $attempt = 0
    $overall = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $attempt++
        [long]$existing = 0
        if (Test-Path -LiteralPath $OutFile) { $existing = (Get-Item -LiteralPath $OutFile).Length }
        if ($ExpectedSize -gt 0 -and $existing -eq $ExpectedSize) {
            Write-Ok "$Label already downloaded ($(Format-Bytes $existing))."
            return
        }
        if ($ExpectedSize -gt 0 -and $existing -gt $ExpectedSize) {
            Write-Warn 'Existing partial file is larger than expected, starting over.'
            Remove-Item -LiteralPath $OutFile -Force; $existing = 0
        }

        $resp = $null; $stream = $null; $fs = $null
        try {
            Write-Log "GET $Url (resume from $existing, attempt $attempt)"
            $req = [Net.HttpWebRequest]::Create($Url)
            $req.UserAgent = 'voice-changer-installer/1.0'
            $req.AllowAutoRedirect = $true
            $req.Timeout = 30000
            $req.ReadWriteTimeout = 120000
            if ($existing -gt 0) { $req.AddRange($existing) }
            $resp = $req.GetResponse()
            $status = [int]$resp.StatusCode
            Write-Log "HTTP $status, content-length $($resp.ContentLength), final url $($resp.ResponseUri.Host)"

            if ($existing -gt 0 -and $status -ne 206) {
                Write-Warn "Server didn't accept resume, restarting download."
                $existing = 0
            } elseif ($existing -gt 0) {
                Write-Info "Resuming from $(Format-Bytes $existing)."
            }

            [long]$total = $ExpectedSize
            if ($resp.ContentLength -gt 0) { $total = $existing + $resp.ContentLength }
            $mode = [IO.FileMode]::Create
            if ($existing -gt 0) { $mode = [IO.FileMode]::Append }

            $fs = New-Object IO.FileStream($OutFile, $mode, [IO.FileAccess]::Write, [IO.FileShare]::None, 1048576)
            $stream = $resp.GetResponseStream()
            $buf = New-Object byte[] 1048576
            [long]$done = $existing
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $lastUi = -1000; $lastLogPct = -10

            while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                $fs.Write($buf, 0, $n)
                $done += $n
                if ($sw.ElapsedMilliseconds - $lastUi -ge 500) {
                    $lastUi = $sw.ElapsedMilliseconds
                    $secs = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
                    $rate = ($done - $existing) / $secs
                    if ($total -gt 0) {
                        $pct = $done * 100.0 / $total
                        $eta = -1; if ($rate -gt 0) { $eta = ($total - $done) / $rate }
                        Write-ProgressLine ('  {0} {1,5:N1}%  {2} / {3}  {4}/s  ETA {5}' -f (Format-Bar $pct), $pct,
                            (Format-Bytes $done), (Format-Bytes $total), (Format-Bytes $rate), (Format-Duration $eta))
                        if ($pct -ge $lastLogPct + 10) {
                            $lastLogPct = [Math]::Floor($pct / 10) * 10
                            Write-Log ('download {0:N0}% ({1} @ {2}/s)' -f $pct, (Format-Bytes $done), (Format-Bytes $rate))
                        }
                    } else {
                        Write-ProgressLine ('  downloaded {0}  {1}/s' -f (Format-Bytes $done), (Format-Bytes $rate))
                    }
                }
            }
            $fs.Flush()
        } catch {
            Clear-ProgressLine
            if ($script:FailMessage) { throw }
            Write-Log ('download error: ' + ($_ | Out-String))

            $we = $_.Exception.InnerException
            if ($we -is [Net.WebException] -and $we.Response) {
                $sc = [int]$we.Response.StatusCode
                # 416 = range not satisfiable: the file is already complete.
                if ($sc -eq 416) { Write-Ok "$Label already fully downloaded."; return }
                if ($sc -eq 401 -or $sc -eq 403 -or $sc -eq 404) {
                    Stop-Install "Server returned HTTP $sc for $Url (file missing or moved)."
                }
            }
            if ($attempt -ge $maxAttempts) {
                Stop-Install "Download failed after $attempt attempts: $($_.Exception.Message)"
            }
            $wait = [Math]::Min(5 * $attempt, 30)
            Write-Warn "Download interrupted: $($_.Exception.Message)"
            Write-Warn "Retrying in ${wait}s (attempt $($attempt + 1)/$maxAttempts). Progress is kept."
            Start-Sleep -Seconds $wait
            continue
        } finally {
            if ($fs) { $fs.Dispose() }
            if ($stream) { $stream.Dispose() }
            if ($resp) { $resp.Close() }
        }

        Clear-ProgressLine
        $final = (Get-Item -LiteralPath $OutFile).Length
        if ($ExpectedSize -gt 0 -and $final -ne $ExpectedSize) {
            if ($attempt -ge $maxAttempts) {
                Stop-Install "Download incomplete: got $(Format-Bytes $final) of $(Format-Bytes $ExpectedSize)."
            }
            Write-Warn "Connection ended early ($(Format-Bytes $final) of $(Format-Bytes $ExpectedSize)). Resuming..."
            Start-Sleep -Seconds 3
            continue
        }
        Write-Ok "$Label downloaded ($(Format-Bytes $final) in $(Format-Duration $overall.Elapsed.TotalSeconds))."
        return
    }
}

function Get-Sha256WithProgress([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::OpenRead($Path)
    try {
        $total = $fs.Length; [long]$done = 0
        $buf = New-Object byte[] 4194304
        $sw = [Diagnostics.Stopwatch]::StartNew(); $lastUi = -1000
        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            [void]$sha.TransformBlock($buf, 0, $n, $null, 0)
            $done += $n
            if ($sw.ElapsedMilliseconds - $lastUi -ge 500) {
                $lastUi = $sw.ElapsedMilliseconds
                $pct = $done * 100.0 / [Math]::Max($total, 1)
                Write-ProgressLine ('  {0} {1,5:N1}%  hashing {2} / {3}' -f (Format-Bar $pct), $pct, (Format-Bytes $done), (Format-Bytes $total))
            }
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        Clear-ProgressLine
        return ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLowerInvariant()
    } finally {
        $fs.Dispose(); $sha.Dispose()
    }
}

function Expand-ZipWithProgress([string]$Zip, [string]$Dest) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $entries = $archive.Entries
        [long]$total = 0
        foreach ($e in $entries) { $total += $e.Length }
        Write-Info ("{0:N0} files, {1} uncompressed." -f $entries.Count, (Format-Bytes $total))
        $destFull = [IO.Path]::GetFullPath($Dest).TrimEnd('\') + '\'
        [long]$done = 0; $count = 0
        $sw = [Diagnostics.Stopwatch]::StartNew(); $lastUi = -1000; $lastLogPct = -10

        foreach ($e in $entries) {
            $target = [IO.Path]::GetFullPath([IO.Path]::Combine($destFull, $e.FullName))
            if (-not $target.StartsWith($destFull, [StringComparison]::OrdinalIgnoreCase)) {
                Stop-Install "Unsafe path inside the archive: $($e.FullName)"
            }
            if ($e.FullName.EndsWith('/') -or $e.FullName.EndsWith('\')) {
                [void][IO.Directory]::CreateDirectory($target); continue
            }
            $dir = [IO.Path]::GetDirectoryName($target)
            if (-not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
            try {
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
            } catch {
                $inner = $_.Exception.InnerException
                if ($inner -is [IO.PathTooLongException] -or $_.Exception.Message -match 'too long') {
                    Stop-Install "Path too long while extracting $($e.FullName). Use a shorter -InstallDir (e.g. C:\VC) or enable Windows long paths."
                }
                Stop-Install "Could not extract $($e.FullName): $($_.Exception.Message)"
            }
            $done += $e.Length; $count++
            if ($sw.ElapsedMilliseconds - $lastUi -ge 500) {
                $lastUi = $sw.ElapsedMilliseconds
                $pct = $done * 100.0 / [Math]::Max($total, 1)
                Write-ProgressLine ('  {0} {1,5:N1}%  {2:N0}/{3:N0} files  {4}' -f (Format-Bar $pct), $pct, $count, $entries.Count,
                    (Format-Duration $sw.Elapsed.TotalSeconds))
                if ($pct -ge $lastLogPct + 10) {
                    $lastLogPct = [Math]::Floor($pct / 10) * 10
                    Write-Log ('extract {0:N0}% ({1} files)' -f $pct, $count)
                }
            }
        }
        Clear-ProgressLine
        Write-Ok ("Extracted {0:N0} files in {1}." -f $count, (Format-Duration $sw.Elapsed.TotalSeconds))
    } finally {
        $archive.Dispose()
    }
}

function Find-NvidiaSmi {
    $candidates = @(
        (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'),
        (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')
    )
    $cmd = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

function Test-VBCable {
    try {
        $dev = Get-CimInstance Win32_SoundDevice -ErrorAction Stop | Where-Object { $_.Name -match 'VB-Audio|CABLE' }
        return [bool]$dev
    } catch { return $false }
}

# ======================================================================= steps

function Step-Preflight {
    Write-Info "Log file: $LogFile"
    $script:InstallDir = [IO.Path]::GetFullPath($InstallDir)

    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $ramGb = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    Write-Info "OS: $($os.Caption) $($os.Version) ($($os.OSArchitecture))"
    Write-Info "CPU: $("$($cpu.Name)".Trim()) ($([Environment]::ProcessorCount) threads), RAM: $ramGb GB"
    Write-Info "PowerShell $($PSVersionTable.PSVersion), admin: $IsAdmin"
    Write-Log "params: InstallDir=$($script:InstallDir) Backend=$Backend Version=$Version SkipVBCable=$SkipVBCable KeepZip=$KeepZip DefenderExcl=$AddDefenderExclusion"

    if (-not [Environment]::Is64BitOperatingSystem) { Stop-Install '64-bit Windows is required.' }
    if ([Environment]::OSVersion.Version.Major -lt 10) { Stop-Install 'Windows 10 or later is required.' }
    if ($ramGb -lt 6) { Write-Warn "Only $ramGb GB RAM. The voice changer may run poorly." }

    if ($script:InstallDir -match '\s') { Write-Warn 'Install path contains spaces. Upstream batch files may not like that. Consider -InstallDir C:\VoiceChanger' }
    if ($script:InstallDir -match '[^\x00-\x7F]') { Write-Warn 'Install path contains non-ASCII characters, which can break the server.' }

    $longPaths = 0
    try { $longPaths = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -ErrorAction Stop).LongPathsEnabled } catch { }
    if ($longPaths -ne 1 -and $script:InstallDir.Length -gt 40) {
        Write-Warn 'Long install path and Windows long paths are off. Extraction may hit the 260 character limit.'
    }

    # TLS 1.2 for older PowerShell defaults
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    New-Item -ItemType Directory -Force -Path $script:InstallDir | Out-Null
    $drive = Get-PSDrive -Name $script:InstallDir.Substring(0, 1)
    $freeGb = [Math]::Round($drive.Free / 1GB, 1)
    Write-Info "Free space on $($drive.Name): $freeGb GB"
    if ($freeGb -lt 10) { Stop-Install "Only $freeGb GB free on $($drive.Name):. About 12 GB is needed (3.3 GB download + ~8 GB extracted)." }
    if ($freeGb -lt 14) { Write-Warn 'Disk space is tight. The zip is deleted after extraction unless -KeepZip is used.' }

    try {
        $r = Invoke-WebRequest -Uri 'https://huggingface.co' -Method Head -UseBasicParsing -TimeoutSec 20
        Write-Ok "huggingface.co reachable (HTTP $($r.StatusCode))."
    } catch {
        Write-Log ($_ | Out-String)
        Stop-Install "Cannot reach huggingface.co: $($_.Exception.Message)"
    }
}

function Step-DetectHardware {
    $gpus = @()
    try { $gpus = @(Get-CimInstance Win32_VideoController) } catch { Write-Warn 'Could not query video controllers.' }
    foreach ($g in $gpus) { Write-Info "Display adapter: $($g.Name) (driver $($g.DriverVersion))" }

    if ($Backend -ne 'auto') {
        $script:Backend = $Backend
        Write-Ok "Package forced by option: $($Backend.ToUpper())"
        return
    }

    $script:Backend = 'dml'
    $hasNvidiaAdapter = [bool]($gpus | Where-Object { $_.Name -match 'NVIDIA' })
    $smi = Find-NvidiaSmi

    if ($smi) {
        $r = Invoke-Native $smi @('--query-gpu=name,compute_cap', '--format=csv,noheader')
        if ($r.ExitCode -eq 0 -and $r.Output.Count -gt 0 -and $r.Output[0] -match ',') {
            $parts = $r.Output[0].Split(',')
            $name = $parts[0].Trim(); $cc = $parts[1].Trim()
            Write-Info "NVIDIA GPU: $name (compute capability $cc)"
            [double]$ccNum = 0
            if ([double]::TryParse($cc, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$ccNum)) {
                if ($ccNum -lt 5.0) {
                    Write-Warn "Compute capability $cc is too old for the CUDA build. Using the DirectML/CPU package."
                } elseif ($ccNum -ge 12.0) {
                    Write-Warn 'RTX 50-series cards are not supported by the CUDA build. Using the DirectML package.'
                } else {
                    $script:Backend = 'cuda'
                }
            } else {
                $script:Backend = 'cuda'
            }
        } else {
            # Older drivers can't report compute_cap; fall back to the name.
            $r2 = Invoke-Native $smi @('--query-gpu=name', '--format=csv,noheader')
            if ($r2.ExitCode -eq 0 -and $r2.Output.Count -gt 0) {
                $name = $r2.Output[0].Trim()
                Write-Info "NVIDIA GPU: $name"
                if ($name -match 'K80|K40|K20|K10|GTX 6\d\d|GTX 7\d\d') {
                    Write-Warn 'Kepler-era GPU, not supported by the CUDA build. Using the DirectML/CPU package.'
                } else {
                    $script:Backend = 'cuda'
                }
            } else {
                Write-Warn 'nvidia-smi is present but not working. Using the DirectML/CPU package.'
            }
        }
    } elseif ($hasNvidiaAdapter) {
        Write-Warn 'NVIDIA adapter found but no working driver tools. Install the NVIDIA driver and re-run for the CUDA build.'
    } elseif ($gpus | Where-Object { $_.Name -match 'AMD|Radeon|Intel\(R\) Arc|Intel\(R\) (Iris|UHD|HD)' }) {
        Write-Info 'AMD/Intel GPU found. The DirectML package can accelerate ONNX models on it.'
    } else {
        Write-Info 'No dedicated GPU found. The DirectML package runs on CPU.'
    }

    if ($script:Backend -eq 'cuda') { Write-Ok 'Selected package: NVIDIA CUDA' }
    else { Write-Ok 'Selected package: DirectML / CPU' }
}

function Step-FindRelease {
    $variant = $VariantNames[$script:Backend]
    $pattern = '^MMVCServerSIO_win_' + [regex]::Escape($variant) + '_v\.(\d+\.\d+\.\d+\.\d+)([a-z]?)\.zip$'
    $script:Release = $null

    try {
        Write-Info 'Querying Hugging Face for available releases...'
        $tree = Invoke-RestMethod -Uri $HfApi -UseBasicParsing -TimeoutSec 30
        $found = @()
        foreach ($item in @($tree)) {
            if ($item.path -match $pattern) {
                $size = [long]$item.size; $sha = $null
                if ($item.lfs) { $size = [long]$item.lfs.size; $sha = $item.lfs.oid }
                $found += [pscustomobject]@{
                    File = $item.path; Ver = [version]$Matches[1]; Suffix = $Matches[2]
                    Tag = $Matches[1] + $Matches[2]; Size = $size; Sha = $sha
                }
            }
        }
        Write-Log ("releases found: " + (($found | ForEach-Object { $_.Tag }) -join ', '))
        if ($found.Count -gt 0) {
            if ($Version) {
                $script:Release = $found | Where-Object { $_.Tag -eq $Version } | Select-Object -First 1
                if (-not $script:Release) {
                    Stop-Install "Version $Version not found. Available: $(($found | ForEach-Object { $_.Tag }) -join ', ')"
                }
            } else {
                $script:Release = $found | Sort-Object Ver, Suffix -Descending | Select-Object -First 1
            }
        }
    } catch {
        if ($script:FailMessage) { throw }
        Write-Log ($_ | Out-String)
        Write-Warn "Couldn't query the release list ($($_.Exception.Message))."
    }

    if (-not $script:Release) {
        $tag = $FallbackVersion; if ($Version) { $tag = $Version }
        Write-Warn "Falling back to known version $tag (size and checksum can't be verified)."
        $script:Release = [pscustomobject]@{
            File = "MMVCServerSIO_win_${variant}_v.$tag.zip"; Tag = $tag; Size = 0; Sha = $null
        }
    }

    $script:Release | Add-Member -NotePropertyName Url -NotePropertyValue "$HfResolve/$($script:Release.File)" -Force
    Write-Ok "Release: $($script:Release.File)"
    if ($script:Release.Size -gt 0) { Write-Info "Size: $(Format-Bytes $script:Release.Size)" }
}

function Step-VcRedist {
    $installed = $false
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\X64') {
        try {
            $p = Get-ItemProperty -Path $k -ErrorAction Stop
            if ($p.Installed -eq 1) { $installed = $true; Write-Log "VC++ runtime $($p.Version) at $k" }
        } catch { }
    }
    if ($installed) { Write-Ok 'Visual C++ runtime already installed.'; return }

    $exe = Join-Path $env:TEMP 'vc_redist.x64.exe'
    Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
    try {
        Save-Download $VcRedistUrl $exe 0 'Visual C++ runtime installer'
    } catch {
        $script:FailMessage = $null
        Write-Log ($_ | Out-String)
        Write-Warn "Couldn't download the Visual C++ runtime: $($_.Exception.Message)"
        Write-Warn 'Continuing. If the server fails to start, install it from https://aka.ms/vs/17/release/vc_redist.x64.exe'
        return
    }
    Write-Info 'Installing Visual C++ runtime (accept the admin prompt)...'
    try {
        $code = Invoke-Elevated $exe '/install /quiet /norestart'
    } catch {
        Write-Log ($_ | Out-String)
        Write-Warn "Visual C++ runtime install was cancelled or failed: $($_.Exception.Message)"
        Write-Warn 'Continuing. If the server fails to start, install it from https://aka.ms/vs/17/release/vc_redist.x64.exe'
        return
    }
    switch ($code) {
        0       { Write-Ok 'Visual C++ runtime installed.' }
        1638    { Write-Ok 'A newer Visual C++ runtime is already installed.' }
        3010    { Write-Ok 'Visual C++ runtime installed (reboot recommended).' }
        default { Write-Warn "Visual C++ runtime installer exited with code $code. Continuing." }
    }
}

function Step-Download {
    $dlDir = Join-Path $script:InstallDir 'downloads'
    New-Item -ItemType Directory -Force -Path $dlDir | Out-Null
    $script:ZipPath = Join-Path $dlDir $script:Release.File
    $script:AppDir = Join-Path $script:InstallDir ("{0}-{1}" -f $script:Release.Tag, $script:Backend)

    if (Test-Path -LiteralPath (Join-Path $script:AppDir '.install-complete')) {
        Write-Ok "Version $($script:Release.Tag) ($($script:Backend)) is already installed. Skipping download."
        $script:AlreadyInstalled = $true
        return
    }
    $script:AlreadyInstalled = $false

    if ($script:Release.Size -gt 0) {
        $have = 0; if (Test-Path -LiteralPath $script:ZipPath) { $have = (Get-Item -LiteralPath $script:ZipPath).Length }
        $needGb = ($script:Release.Size - $have) / 1GB + $script:Release.Size * 2.5 / 1GB
        $freeGb = (Get-PSDrive -Name $script:InstallDir.Substring(0, 1)).Free / 1GB
        Write-Log ("space check: need ~{0:N1} GB, free {1:N1} GB" -f $needGb, $freeGb)
        if ($freeGb -lt $needGb) {
            Stop-Install ("Not enough disk space: about {0:N1} GB needed, {1:N1} GB free." -f $needGb, $freeGb)
        }
    }

    Write-Info "Downloading to $($script:ZipPath)"
    Write-Info 'This is a large file. If it stops, re-run the installer and it will resume.'
    Save-Download $script:Release.Url $script:ZipPath $script:Release.Size $script:Release.File
}

function Step-Verify {
    if ($script:AlreadyInstalled) { Write-Ok 'Already installed, nothing to verify.'; return }
    if (-not $script:Release.Sha) {
        Write-Warn 'No checksum available. Testing that the zip opens instead.'
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $z = [IO.Compression.ZipFile]::OpenRead($script:ZipPath); $c = $z.Entries.Count; $z.Dispose()
            Write-Ok "Zip opens correctly ($c entries)."
        } catch {
            Remove-Item -LiteralPath $script:ZipPath -Force -ErrorAction SilentlyContinue
            Stop-Install "The downloaded zip is corrupt and was deleted: $($_.Exception.Message)"
        }
        return
    }
    Write-Info 'Checking SHA256...'
    $hash = Get-Sha256WithProgress $script:ZipPath
    Write-Log "sha256 expected $($script:Release.Sha) got $hash"
    if ($hash -ne $script:Release.Sha.ToLowerInvariant()) {
        Remove-Item -LiteralPath $script:ZipPath -Force -ErrorAction SilentlyContinue
        Stop-Install 'Checksum mismatch: the download is corrupt and was deleted. Run the installer again.'
    }
    Write-Ok 'Checksum matches.'
}

function Step-Extract {
    if ($AddDefenderExclusion) {
        Write-Info 'Adding Windows Defender exclusion (accept the admin prompt)...'
        try {
            $code = Invoke-Elevated 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -Command `"Add-MpPreference -ExclusionPath '$($script:InstallDir)'`""
            if ($code -eq 0) { Write-Ok "Defender exclusion added for $($script:InstallDir)." }
            else { Write-Warn "Adding the Defender exclusion returned code $code." }
        } catch {
            Write-Warn "Defender exclusion not added: $($_.Exception.Message)"
        }
    }

    if ($script:AlreadyInstalled) { Write-Ok 'Already extracted.' }
    else {
        if (Test-Path -LiteralPath $script:AppDir) {
            Write-Warn 'Found a partial previous extraction, removing it first...'
            Remove-Item -LiteralPath $script:AppDir -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $script:AppDir | Out-Null
        Write-Info "Extracting to $($script:AppDir)"
        Write-Info 'Antivirus scanning can make this slow. That is normal.'
        Expand-ZipWithProgress $script:ZipPath $script:AppDir
        Set-Content -LiteralPath (Join-Path $script:AppDir '.install-complete') -Value (Get-Date -Format o)

        # Carry user voice models over from the previous install, if any.
        $prev = Get-ChildItem -LiteralPath $script:InstallDir -Directory |
            Where-Object { $_.FullName -ne $script:AppDir -and (Test-Path -LiteralPath (Join-Path $_.FullName '.install-complete')) } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($prev) {
            $oldModels = Get-ChildItem -LiteralPath $prev.FullName -Recurse -Directory -Filter 'model_dir' -ErrorAction SilentlyContinue | Select-Object -First 1
            $newModels = Get-ChildItem -LiteralPath $script:AppDir -Recurse -Directory -Filter 'model_dir' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($oldModels) {
                $target = $null
                if ($newModels) { $target = $newModels.FullName }
                else { $target = Join-Path $script:AppDir ($oldModels.FullName.Substring($prev.FullName.Length).TrimStart('\')) }
                Write-Info "Copying your voice models from $($prev.Name)..."
                $r = Invoke-Native 'robocopy.exe' @($oldModels.FullName, $target, '/E', '/XC', '/XN', '/XO', '/NFL', '/NDL', '/NJH', '/NJS')
                if ($r.ExitCode -lt 8) { Write-Ok 'Voice models copied.' } else { Write-Warn "Copying models returned code $($r.ExitCode). Copy model_dir manually if needed." }
            }
        }

        if (-not $KeepZip) {
            Remove-Item -LiteralPath $script:ZipPath -Force -ErrorAction SilentlyContinue
            Write-Info 'Deleted the zip to save space (use -KeepZip to keep it).'
        }
    }

    $script:StartBat = Get-ChildItem -LiteralPath $script:AppDir -Recurse -Filter 'start_http.bat' -ErrorAction SilentlyContinue | Select-Object -First 1
    $script:ServerExe = Get-ChildItem -LiteralPath $script:AppDir -Recurse -Filter 'MMVCServerSIO.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $script:ServerExe) {
        Remove-Item -LiteralPath (Join-Path $script:AppDir '.install-complete') -Force -ErrorAction SilentlyContinue
        Stop-Install 'MMVCServerSIO.exe was not found after extraction. Antivirus may have quarantined it. Check Windows Security > Protection history.'
    }
    Write-Ok "Server: $($script:ServerExe.FullName)"
    if ($script:StartBat) { Write-Ok "Start script: $($script:StartBat.FullName)" }
    else { Write-Warn 'start_http.bat not found. The launcher will start MMVCServerSIO.exe directly.' }
}

function Step-Launcher {
    $launcherPs1 = Join-Path $script:InstallDir 'Start-VoiceChanger.ps1'
    $launcherBat = Join-Path $script:InstallDir 'Start-VoiceChanger.bat'

    if ($script:StartBat) {
        $workDir = $script:StartBat.DirectoryName
        $runLine = 'cmd.exe /c "start_http.bat 2>&1" | Tee-Object -FilePath $log -Append'
    } else {
        $workDir = $script:ServerExe.DirectoryName
        $runLine = 'cmd.exe /c "MMVCServerSIO.exe -p 18888 --https false 2>&1" | Tee-Object -FilePath $log -Append'
    }

    $template = @'
# Generated by install-voice-changer.ps1 (package: __BACKEND__, version __TAG__)
$ErrorActionPreference = 'Continue'
$logDir = '__LOGDIR__'
try { New-Item -ItemType Directory -Force -Path $logDir | Out-Null } catch { $logDir = $env:TEMP }
$log = Join-Path $logDir ("server-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$env:PYTHONUNBUFFERED = '1'
$Host.UI.RawUI.WindowTitle = 'w-okada Voice Changer'
Write-Host 'w-okada Voice Changer (__BACKEND__, v__TAG__)' -ForegroundColor White
Write-Host "Server log: $log"
Write-Host 'Open http://localhost:18888 in Chrome or Edge if it does not open by itself.'
Write-Host 'First start downloads extra model files, so give it a few minutes.'
Write-Host 'Close this window or press Ctrl+C to stop the server.'
Write-Host ''
Set-Location -LiteralPath '__WORKDIR__'
__RUNLINE__
$code = $LASTEXITCODE
Write-Host ''
Write-Host "Voice changer stopped (exit code $code)." -ForegroundColor Yellow
Write-Host "Server log: $log"
Read-Host 'Press Enter to close' | Out-Null
'@
    $content = $template.Replace('__BACKEND__', $script:Backend)
    $content = $content.Replace('__TAG__', $script:Release.Tag)
    $content = $content.Replace('__LOGDIR__', $LogDir.Replace("'", "''"))
    $content = $content.Replace('__WORKDIR__', $workDir.Replace("'", "''"))
    $content = $content.Replace('__RUNLINE__', $runLine)
    Set-Content -LiteralPath $launcherPs1 -Value $content -Encoding UTF8

    $bat = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Start-VoiceChanger.ps1`"`r`n"
    [IO.File]::WriteAllText($launcherBat, $bat, [Text.Encoding]::ASCII)
    Write-Ok "Launcher: $launcherBat"

    $info = [ordered]@{
        version = $script:Release.Tag; package = $script:Backend; file = $script:Release.File
        appDir = $script:AppDir; server = $script:ServerExe.FullName; installed = (Get-Date -Format o)
    }
    ($info | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $script:InstallDir 'install-info.json') -Encoding UTF8

    if ($NoShortcut) { Write-Info 'Skipping desktop shortcut (-NoShortcut).'; return }
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $lnkPath = Join-Path $desktop 'Voice Changer.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut($lnkPath)
        $lnk.TargetPath = $launcherBat
        $lnk.WorkingDirectory = $script:InstallDir
        $lnk.IconLocation = "$($script:ServerExe.FullName),0"
        $lnk.Description = 'Start the w-okada Realtime Voice Changer'
        $lnk.Save()
        Write-Ok "Desktop shortcut created: $lnkPath"
    } catch {
        Write-Log ($_ | Out-String)
        Write-Warn "Couldn't create the desktop shortcut: $($_.Exception.Message)"
    }
}

function Step-VBCable {
    if ($SkipVBCable) { Write-Info 'Skipping VB-Audio Virtual Cable (-SkipVBCable).'; return }
    if (Test-VBCable) { Write-Ok 'VB-Audio Virtual Cable already installed.'; return }

    Write-Info 'VB-Audio Virtual Cable lets Discord/games use the changed voice as a microphone.'
    $zip = Join-Path $env:TEMP 'VBCABLE_Driver_Pack.zip'
    $ok = $false
    foreach ($u in $VbCableUrls) {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        try {
            Save-Download $u $zip 0 'VB-Cable driver pack'
            $ok = $true; break
        } catch {
            if ($script:FailMessage) { $script:FailMessage = $null }
            Write-Warn "Couldn't download $u, trying the next source."
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $ok) {
        Write-Warn 'VB-Cable could not be downloaded. Install it manually from https://vb-audio.com/Cable/'
        return
    }

    $dir = Join-Path $env:TEMP 'VBCABLE_Driver_Pack'
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
    $setup = Get-ChildItem -LiteralPath $dir -Recurse -Filter 'VBCABLE_Setup_x64.exe' | Select-Object -First 1
    if (-not $setup) {
        Write-Warn "VBCABLE_Setup_x64.exe not found in the pack. Install manually from $dir"
        return
    }

    Write-Info 'Installing VB-Cable driver (accept the admin prompt; Windows may also ask to trust the driver)...'
    try {
        $code = Invoke-Elevated $setup.FullName '-i -h'
    } catch {
        Write-Log ($_ | Out-String)
        Write-Warn "VB-Cable install was cancelled or failed: $($_.Exception.Message)"
        Write-Warn "You can run it later: $($setup.FullName) (right-click > Run as administrator)"
        return
    }
    Start-Sleep -Seconds 3
    if (Test-VBCable) {
        Write-Ok 'VB-Audio Virtual Cable installed. Reboot before using it.'
    } else {
        Write-Warn "VB-Cable installer finished (code $code) but the device isn't visible yet. Reboot, and if it's still missing run $($setup.FullName) as administrator."
    }
    $script:NeedsReboot = $true
}

function Step-Final {
    $problems = 0
    foreach ($p in @($script:ServerExe.FullName, (Join-Path $script:InstallDir 'Start-VoiceChanger.bat'))) {
        if (Test-Path -LiteralPath $p) { Write-Ok "Found $p" } else { Write-Err "Missing $p"; $problems++ }
    }
    if ($problems -gt 0) { Stop-Install 'Some installed files are missing. See above.' }
}

# ======================================================================== main
$exitCode = 0
$script:NeedsReboot = $false
$start = [Diagnostics.Stopwatch]::StartNew()
Write-Log '===== install-voice-changer.ps1 started ====='

try {
    try { $Host.UI.RawUI.WindowTitle = 'w-okada Voice Changer installer' } catch { }
    Write-Host 'w-okada Voice Changer installer (Windows)' -ForegroundColor White
    Write-Host "Log: $LogFile"

    Start-Step 1;  Step-Preflight
    Start-Step 2;  Step-DetectHardware
    Start-Step 3;  Step-FindRelease
    Start-Step 4;  Step-VcRedist
    Start-Step 5;  Step-Download
    Start-Step 6;  Step-Verify
    Start-Step 7;  Step-Extract
    Start-Step 8;  Step-Launcher
    Start-Step 9;  Step-VBCable
    Start-Step 10; Step-Final

    $script:Status = 'success'
    Write-Log '===== INSTALL SUCCEEDED ====='
    Write-Host ''
    Write-Host ('{0} 100%  Install complete in {1}' -f (Format-Bar 100), (Format-Duration $start.Elapsed.TotalSeconds)) -ForegroundColor Green
    Write-Host ''
    $pkg = 'DirectML / CPU'; if ($script:Backend -eq 'cuda') { $pkg = 'NVIDIA CUDA' }
    Write-Host "   Package: $pkg, version $($script:Release.Tag)"
    Write-Host "   Folder:  $($script:AppDir)"
    Write-Host "   Start:   'Voice Changer' shortcut on the desktop, or $(Join-Path $script:InstallDir 'Start-VoiceChanger.bat')"
    Write-Host '   Open:    http://localhost:18888 in Chrome or Edge'
    Write-Host '   First start downloads extra model files, so give it a few minutes.'
    if ($script:NeedsReboot) {
        Write-Host ''
        Write-Warn 'Reboot before using VB-Cable. Then in Discord/games pick "CABLE Output" as the microphone,'
        Write-Warn 'and in the voice changer pick "CABLE Input" as the output device.'
    }
    if ($script:Backend -eq 'dml') {
        Write-Host ''
        Write-Warn 'CPU/DirectML tips: use ONNX models, the rmvpe_onnx or crepe_tiny f0 detector,'
        Write-Warn 'and a larger chunk size. Expect more delay than on an NVIDIA GPU.'
    }
} catch {
    $exitCode = 10
    $e = $_
    Clear-ProgressLine
    Write-Log ('EXCEPTION: ' + ($e | Out-String))
    Write-Log ('STACK: ' + $e.ScriptStackTrace)
    Write-Host ''
    if ($script:FailMessage) {
        Write-Err "INSTALL FAILED at step: $($script:CurrentStep)"
        Write-Err $script:FailMessage
    } else {
        Write-Err "Installer stopped unexpectedly during: $($script:CurrentStep)"
        Write-Err $e.Exception.Message
        if ($e.InvocationInfo) { Write-Err ('At line ' + $e.InvocationInfo.ScriptLineNumber + ': ' + $e.InvocationInfo.Line.Trim()) }
    }
    $script:Status = 'failed'
    Show-LogTail
    Show-Hints
} finally {
    Clear-ProgressLine
    if ($script:Status -eq 'running') {
        Write-Host ''
        Write-Warn "Installer was interrupted during: $($script:CurrentStep)"
    }
    Write-Log "===== EXIT status=$($script:Status) code=$exitCode ====="
    Write-Host ''
    Write-Host "Full log: $LogFile"
    if (-not $NoPause) {
        Write-Host ''
        try { Read-Host 'Press Enter to close' | Out-Null } catch { Start-Sleep -Seconds 30 }
    }
}
exit $exitCode
