# SteamCMD: locate, install, verify login, download depots.
#
# CREDENTIAL POLICY - deliberate, do not "improve":
# This pack NEVER stores, prompts for, or handles a Steam password. SteamCMD
# caches a refresh token after one interactive login, and every later run uses
# it with no password and no Steam Guard prompt. The interactive login is done
# by the user, in their own console window, which this script launches and then
# waits on. A stored password could not work anyway: an account with Steam Guard
# still needs a rotating code, which cannot be stored.

$script:SteamCmdUrl = 'https://media.steampowered.com/client/installer/steamcmd.zip'

function Get-FixedDrives {
    $out = New-Object System.Collections.ArrayList
    foreach ($d in ([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -eq 'Fixed' })) {
        [void]$out.Add([pscustomobject]@{
            Name      = $d.Name
            FreeBytes = $d.AvailableFreeSpace
            FreeGB    = [math]::Round($d.AvailableFreeSpace / 1GB, 1)
            TotalGB   = [math]::Round($d.TotalSize / 1GB, 1)
        })
    }
    return $out
}

function Get-PathQualifier {
    # The drive of a path ("C:"), or $null when it has none.
    #
    # `Split-Path -Qualifier` THROWS on a path with no drive letter. A user typed
    # an install location with the colon missing - "c\SteamCMD" where a rooted path
    # was meant - and it killed their run at STEP 11 OF 11, after a 50 GB download,
    # because a free-space check could not work out which drive to look at.
    # Defect 19.
    #
    # Returning $null lets callers skip a check they cannot perform, instead of
    # ending a run that was otherwise fine.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not [System.IO.Path]::IsPathRooted($Path)) { return $null }
    try { return (Split-Path -Qualifier $Path -ErrorAction Stop) } catch { return $null }
}

function Get-MissingColonHint {
    # A drive letter typed without its colon - "c\SteamCMD" - which is the exact
    # mistake behind defect 19, and an easy one to make at a bare text prompt.
    # Returns the corrected path, or $null when that is not what went wrong.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.Trim()
    if ($p -match '^([A-Za-z])$')            { return ('{0}:\' -f $matches[1].ToUpper()) }
    if ($p -match '^([A-Za-z])[\\/](.*)$')   { return ('{0}:\{1}' -f $matches[1].ToUpper(), $matches[2]) }
    return $null
}

function Find-SteamCmd {
    # Probed dynamically across every fixed drive - never assume a drive letter
    # or a user profile name.
    $candidates = New-Object System.Collections.ArrayList
    foreach ($d in (Get-FixedDrives)) {
        foreach ($sub in @('SteamCMD', 'steamcmd', 'Games\SteamCMD', 'Tools\SteamCMD')) {
            [void]$candidates.Add((Join-Path $d.Name (Join-Path $sub 'steamcmd.exe')))
        }
    }
    foreach ($p in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:USERPROFILE)) {
        if ($p) { [void]$candidates.Add((Join-Path $p 'SteamCMD\steamcmd.exe')) }
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Get-Item -LiteralPath $c).FullName }
    }
    return $null
}

function Invoke-SteamCmd {
    # stdout and stderr go to SEPARATE files on purpose. In PowerShell 5.1,
    # folding a native executable's stderr into stdout wraps each line in an
    # ErrorRecord and sets $? to false even when the exe exited cleanly.
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSec = 3600
    )
    $out = [System.IO.Path]::GetTempFileName()
    $err = [System.IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch { }
            throw "SteamCMD timed out after $TimeoutSec seconds"
        }
        return (Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue)
    } finally {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue
    }
}

function Install-SteamCmd {
    param([Parameter(Mandatory = $true)][string]$TargetDir)
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    $zip = Join-Path $TargetDir 'steamcmd.zip'

    Write-Host '  Downloading SteamCMD from Valve ... ' -NoNewline
    try {
        $old = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $script:SteamCmdUrl -OutFile $zip -UseBasicParsing -ErrorAction Stop
        $ProgressPreference = $old
    } catch {
        Write-Host 'FAILED'
        throw "Could not download SteamCMD: $($_.Exception.Message)"
    }
    Write-Host 'done'

    Write-Host '  Extracting ... ' -NoNewline
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $TargetDir)
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Write-Host 'done'

    $exe = Join-Path $TargetDir 'steamcmd.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "steamcmd.exe not found after extracting to $TargetDir"
    }

    Write-Host '  First run: SteamCMD now downloads the rest of itself. This can take'
    Write-Host '  several minutes and shows nothing while it works. Do not close the window.'
    Write-Host '  working ... ' -NoNewline
    Invoke-SteamCmd -Exe $exe -Arguments @('+quit') -TimeoutSec 900 | Out-Null
    Write-Host 'done'
    return $exe
}

function Test-SteamCmdLogin {
    # Answers one question: is SteamCMD ALREADY signed in? A false answer is never
    # fatal - it just means the interactive login runs next, which is the correct
    # thing to do anyway.
    #
    # This runs SteamCMD with its output redirected, so if SteamCMD replies by
    # ASKING something - a password, or a Steam Guard code on an expired token -
    # the prompt lands in the redirect where nobody can see or answer it, and it
    # waits forever. That is defect 18: a first-time user was stopped at step 6 of
    # 11 by a raw stack trace from the timeout.
    #
    # So a timeout is treated as "not signed in" rather than as an error. SteamCMD
    # sitting silent means it wants to ask something, and Start-InteractiveLogin -
    # a real console with real stdin - is exactly where that question belongs.
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$AccountName,
        [int]$TimeoutSec = 60
    )
    try {
        $o = Invoke-SteamCmd -Exe $Exe -Arguments @('+login', $AccountName, '+quit') -TimeoutSec $TimeoutSec
    } catch {
        return $false
    }
    if ($null -eq $o) { return $false }
    if ($o -match 'Cached credentials not found') { return $false }
    if ($o -match 'to Steam Public\.\.\.OK') { return $true }
    return $false
}

function Start-InteractiveLogin {
    # Opens SteamCMD in its OWN console window. No output redirection and no
    # -NoNewWindow: either one breaks the password prompt, which needs a real
    # console with real stdin. Never attempt to type into it from here.
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$AccountName
    )
    return (Start-Process -FilePath $Exe -ArgumentList @('+login', $AccountName) -PassThru)
}

function Get-DepotDownloadPath {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$AppId,
        [Parameter(Mandatory = $true)][string]$DepotId
    )
    $root = Split-Path -Parent $Exe
    return (Join-Path $root ('steamapps\content\app_' + $AppId + '\depot_' + $DepotId))
}

function Get-DirectorySize {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
    $s = (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
          Measure-Object -Property Length -Sum).Sum
    if ($null -eq $s) { return [long]0 }
    return [long]$s
}

function Get-ProcessBytesWritten {
    # Bytes a process has actually WRITTEN to disk, summed over it and any
    # children (SteamCMD is expected to write in-process, but summing the tree
    # costs nothing and removes the doubt).
    #
    # This exists because folder size is NOT a measure of download progress.
    # SteamCMD preallocates every file at its full final size and then fills it
    # in place, so the folder reaches its final figure early and then sits still
    # while the data is still arriving. This counter ignores preallocation.
    #
    # Measured directly rather than assumed: extending a file to 1 GB moved this
    # counter not at all, and writing 256 MB into that file moved it by exactly
    # 256 MB.
    #
    # Returns -1 when the counter cannot be read, so callers fall back to the
    # older folder-size behaviour rather than losing the display entirely.
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    try {
        $procs = @(Get-CimInstance Win32_Process `
                   -Filter "ProcessId=$ProcessId OR ParentProcessId=$ProcessId" `
                   -ErrorAction Stop)
        if ($procs.Count -eq 0) { return [long](-1) }
        $total = [long]0
        foreach ($pr in $procs) {
            if ($null -ne $pr.WriteTransferCount) { $total += [long]$pr.WriteTransferCount }
        }
        return $total
    } catch {
        return [long](-1)
    }
}

function Format-ProgressBar {
    param([double]$Percent, [int]$Width = 34)
    $p = [math]::Max(0, [math]::Min(100, $Percent))
    $filled = [int][math]::Round($Width * $p / 100.0)
    $bar = ('#' * $filled) + ('-' * ($Width - $filled))
    return '[' + $bar + ']'
}

function Get-DepotContentSize {
    # Size of the depot's actual content, EXCLUDING our own marker file.
    # Measuring the marker would make the recorded byte count disagree with the
    # next measurement, so reuse would never match and we would re-validate
    # every time for no reason.
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
    $s = (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -ne '.sgdh-manifest.json' } |
          Measure-Object -Property Length -Sum).Sum
    if ($null -eq $s) { return [long]0 }
    return [long]$s
}

function Get-DepotMarker {
    # SteamCMD leaves NO record of which manifest a depot folder holds - the
    # folder is just depot_<id>. So we drop our own marker after a successful
    # download, which lets a later run recognise content it already has.
    param([Parameter(Mandatory = $true)][string]$DepotDir)
    $p = Join-Path $DepotDir '.sgdh-manifest.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json) } catch { return $null }
}

function Set-DepotMarker {
    param(
        [Parameter(Mandatory = $true)][string]$DepotDir,
        [Parameter(Mandatory = $true)][string]$ManifestId,
        [Parameter(Mandatory = $true)][long]$Bytes
    )
    $p = Join-Path $DepotDir '.sgdh-manifest.json'
    $o = [pscustomobject]@{
        manifest    = $ManifestId
        bytes       = $Bytes
        downloadedAt = (Get-Date).ToString('s')
        writtenBy   = 'steam-game-downgrade-helper'
    }
    try { $o | ConvertTo-Json | Set-Content -LiteralPath $p -Encoding utf8 } catch { }
}

function Test-DepotAlreadyDownloaded {
    # Returns Status: 'match'   - our marker says this is exactly the wanted manifest
    #                 'unknown' - files are present but we cannot say which version
    #                 'other'   - our marker says a DIFFERENT manifest is here
    #                 'empty'   - nothing downloaded yet
    #
    # Re-running download_depot over existing content costs NO bandwidth: SteamCMD
    # validates against the manifest and rewrites only what differs (verified on a
    # 50 GB depot - not one byte was rewritten). But validation still reads every
    # file, which took ~10 minutes at that size, so skipping it is worth doing.
    param(
        [Parameter(Mandatory = $true)][string]$DepotDir,
        [Parameter(Mandatory = $true)][string]$ManifestId
    )
    $bytes = Get-DepotContentSize -Path $DepotDir
    if ($bytes -le 0) {
        return [pscustomobject]@{ Status = 'empty'; Bytes = 0; Marker = $null }
    }
    $m = Get-DepotMarker -DepotDir $DepotDir
    if ($null -eq $m) {
        return [pscustomobject]@{ Status = 'unknown'; Bytes = $bytes; Marker = $null }
    }
    if ($m.manifest -eq $ManifestId) {
        # Guard against a marker left behind by an interrupted download.
        if ($m.bytes -and [long]$m.bytes -ne $bytes) {
            return [pscustomobject]@{ Status = 'unknown'; Bytes = $bytes; Marker = $m }
        }
        return [pscustomobject]@{ Status = 'match'; Bytes = $bytes; Marker = $m }
    }
    return [pscustomobject]@{ Status = 'other'; Bytes = $bytes; Marker = $m }
}

function Invoke-DepotDownload {
    # download_depot writes into <steamcmd>\steamapps\content\ and ignores
    # force_install_dir. That is why where SteamCMD lives decides where tens of
    # GB land, and why the user is asked about it explicitly.
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$AccountName,
        [Parameter(Mandatory = $true)][string]$AppId,
        [Parameter(Mandatory = $true)][string]$DepotId,
        [Parameter(Mandatory = $true)][string]$ManifestId,
        [long]$EstimatedBytes = 0
    )
    $target  = Get-DepotDownloadPath -Exe $Exe -AppId $AppId -DepotId $DepotId
    $logPath = [System.IO.Path]::GetTempFileName()
    $errPath = [System.IO.Path]::GetTempFileName()

    $argList = @('+login', $AccountName, '+download_depot', $AppId, $DepotId, $ManifestId, '+quit')
    $p = Start-Process -FilePath $Exe -ArgumentList $argList -NoNewWindow -PassThru -RedirectStandardOutput $logPath -RedirectStandardError $errPath

    # ---------------------------------------------------------------------
    # Measuring download progress honestly.
    #
    # SteamCMD prints NOTHING between "Downloading depot ..." and "Depot
    # download complete" - a full 50 GB download produced exactly two lines. So
    # progress has to be measured from outside the process.
    #
    # The obvious signal, folder size, is a TRAP. SteamCMD preallocates every
    # file at its full size and then fills it in place, so the folder measures
    # bytes ALLOCATED, not bytes written. It reaches the final figure early and
    # then stops moving while the download is still running. An earlier version
    # trusted it and showed "100%, 0.0 MB/s, ETA 00:00:00" during a genuine
    # 560 Mbps transfer. A tester reasonably concluded it had hung and killed it
    # - twice - turning one download into three.
    #
    # The process's own write counter does not have that problem. Preallocation
    # does not move it and real content does, to the byte. It is the primary
    # signal here; folder size survives only as a fallback for a machine where
    # the counter cannot be read, so the display can never be worse than before.
    #
    # Two cases the counter handles that folder size cannot:
    #   - the TAIL of a fresh download, where the last files are allocated
    #     before their contents have arrived;
    #   - a RESUMED download, where every file already exists at full size, so
    #     the folder cannot grow at all.
    #
    # On a resume SteamCMD first VALIDATES what is already there - reads, not
    # writes - so the counter legitimately sits at zero for minutes. That is
    # reported as checking, not as progress and not as a stall.
    #
    # A resume also gets no percentage. SteamCMD writes only the missing pieces,
    # so the depot total is not the denominator, and pretending otherwise would
    # be the same class of lie pointing the other way.
    #
    # Rule kept throughout: never let a derived number assert completion. The
    # bar caps at 99 while the process is alive. Only the process exiting is
    # allowed to mean done.
    # ---------------------------------------------------------------------
    $sw          = [System.Diagnostics.Stopwatch]::StartNew()
    $startSize   = Get-DirectorySize -Path $target
    $lastBytes   = $startSize
    $lastWritten = [long]0
    $lastSecs    = 0.0
    $rateAvg     = 0.0
    $quiet       = 0
    $spin        = @('|', '/', '-', '\')
    $tick        = 0
    $useCounter  = $true
    $failedReads = 0

    # Already full at launch means this is a resume: folder size can never move.
    $resuming = ($EstimatedBytes -gt 0 -and $startSize -ge ($EstimatedBytes * 0.95))
    if ($resuming) {
        Write-Host '   This version is already partly on disk, so SteamCMD will check what is' -ForegroundColor Gray
        Write-Host '   there and fill in the missing pieces. Only those pieces get written, so' -ForegroundColor Gray
        Write-Host '   there is no meaningful percentage - the bytes written below are real.' -ForegroundColor Gray
    }
    Write-Host '   DO NOT CLOSE THIS WINDOW. If you want to confirm it is working, open Task' -ForegroundColor Gray
    Write-Host '   Manager and watch the Network column.' -ForegroundColor Gray
    Write-Host ''

    $w = 100
    try { if ($Host.UI.RawUI.WindowSize.Width -gt 20) { $w = $Host.UI.RawUI.WindowSize.Width - 1 } } catch { }

    # try/finally so an interruption cannot leave SteamCMD running. An orphaned
    # steamcmd.exe keeps its state_<app>_<depot>.patch file locked, and the NEXT
    # run then dies with "Failed to write patch state file (File locked)" and
    # cannot start at all - the user is locked out entirely. Defect 17.
    #
    # This covers Ctrl+C and any error thrown by the monitor. It cannot cover the
    # console window being destroyed outright, where Windows kills the process
    # before any PowerShell cleanup runs - hence the locked-file guidance added to
    # the failure reasons below.
    try {
        while (-not $p.HasExited) {
            Start-Sleep -Seconds 2
            $tick++
            $secs  = $sw.Elapsed.TotalSeconds
            $delta = $secs - $lastSecs
            $bytes = Get-DirectorySize -Path $target

            # Read the write counter. One failed read is not enough to abandon it -
            # the process exiting mid-poll would trip that - but three in a row mean
            # it is genuinely unavailable on this machine.
            $written = [long](-1)
            if ($useCounter) {
                $written = Get-ProcessBytesWritten -ProcessId $p.Id
                if ($written -lt 0) {
                    $failedReads++
                    if ($failedReads -ge 3) { $useCounter = $false }
                } else {
                    $failedReads = 0
                }
            }
            $haveTruth = ($useCounter -and $written -ge 0)

            if ($haveTruth) {
                $moved         = $written - $lastWritten
                $progressBytes = $written
                $lastWritten   = $written
            } else {
                $moved         = $bytes - $lastBytes
                $progressBytes = $bytes
            }
            $lastBytes = $bytes
            $lastSecs  = $secs

            if ($delta -gt 0 -and $moved -gt 0) {
                $inst = $moved / $delta
                if ($rateAvg -le 0) { $rateAvg = $inst } else { $rateAvg = (0.7 * $rateAvg) + (0.3 * $inst) }
                $quiet = 0
            } else {
                $quiet++
            }

            $el = '{0:hh\:mm\:ss}' -f $sw.Elapsed

            if ($haveTruth -and $progressBytes -le 0) {
                # Nothing written yet. Normal: a resume validates first, and a fresh
                # download fetches the manifest before any data arrives.
                $why = 'preparing - waiting for the first data'
                if ($resuming) { $why = 'checking what is already on disk - nothing to write yet' }
                $line = '   {0}  {1}  {2} elapsed' -f $spin[$tick % 4], $why, $el
            }
            elseif ($haveTruth -and (-not $resuming) -and $EstimatedBytes -gt 0) {
                # Cap at 99 while running: 100% must mean "the process exited".
                $pct = [math]::Min(99.0, ($progressBytes * 100.0 / $EstimatedBytes))
                $eta = '--:--:--'
                if ($rateAvg -gt 0) {
                    # Kept in [long] deliberately. [math]::Max(0, ...) binds the
                    # Int32 overload and throws on anything above 2 GB.
                    $left = [long]$EstimatedBytes - [long]$progressBytes
                    if ($left -lt 0) { $left = [long]0 }
                    $remain = $left / $rateAvg
                    # Never let the ETA assert completion either. The bar caps at 99
                    # for the same reason; a zero ETA says "finished" just as loudly,
                    # and that is the reading that got a working download killed.
                    if ($remain -lt 1) { $remain = 1 }
                    if ($remain -lt 359999) { $eta = '{0:hh\:mm\:ss}' -f [timespan]::FromSeconds($remain) }
                }
                $line = '   {0} {1,5:N1}%  {2,6:N2} / {3,5:N1} GB  {4,5:N1} MB/s  ETA {5}' -f `
                        (Format-ProgressBar -Percent $pct), $pct, ($progressBytes / 1GB), ($EstimatedBytes / 1GB), ($rateAvg / 1MB), $eta
            }
            elseif ($haveTruth) {
                # Real bytes, no honest denominator (a resume, or no size available).
                $line = '   {0}  filling in missing pieces  {1,6:N2} GB written  {2,5:N1} MB/s  {3} elapsed' -f `
                        $spin[$tick % 4], ($progressBytes / 1GB), ($rateAvg / 1MB), $el
            }
            else {
                # Fallback: the write counter is unavailable, so we are back to
                # folder size and all of its caveats. Trust it only while it grows.
                $canMeasure = (-not $resuming) -and ($EstimatedBytes -gt 0) -and ($quiet -lt 3)
                if ($canMeasure) {
                    $pct = [math]::Min(99.0, ($bytes * 100.0 / $EstimatedBytes))
                    $eta = '--:--:--'
                    if ($rateAvg -gt 0) {
                        $left = [long]$EstimatedBytes - [long]$bytes
                        if ($left -lt 0) { $left = [long]0 }
                        $remain = $left / $rateAvg
                    # Never let the ETA assert completion either. The bar caps at 99
                    # for the same reason; a zero ETA says "finished" just as loudly,
                    # and that is the reading that got a working download killed.
                    if ($remain -lt 1) { $remain = 1 }
                        if ($remain -lt 359999) { $eta = '{0:hh\:mm\:ss}' -f [timespan]::FromSeconds($remain) }
                    }
                    $line = '   {0} {1,5:N1}%  {2,6:N2} / {3,5:N1} GB  {4,5:N1} MB/s  ETA {5}' -f `
                            (Format-ProgressBar -Percent $pct), $pct, ($bytes / 1GB), ($EstimatedBytes / 1GB), ($rateAvg / 1MB), $eta
                } else {
                    $why = 'still downloading'
                    if ($resuming)        { $why = 'filling in missing pieces' }
                    elseif ($bytes -gt 0) { $why = 'finishing off - files are created, contents still arriving' }
                    $line = '   {0}  {1}  ({2:N2} GB on disk)  {3} elapsed' -f $spin[$tick % 4], $why, ($bytes / 1GB), $el
                }
            }
            Write-Host ("`r" + $line.PadRight($w)) -NoNewline
        }
        Write-Host ("`r" + ('   done in {0:hh\:mm\:ss}' -f $sw.Elapsed).PadRight($w))
    } finally {
        if ($p -and -not $p.HasExited) {
            try { $p.Kill(); [void]$p.WaitForExit(5000) } catch { }
        }
    }

    $log = Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $errPath -Force -ErrorAction SilentlyContinue

    $ok = $false
    if ($log -and $log -match 'Depot download complete') { $ok = $true }
    if ($ok) { Set-DepotMarker -DepotDir $target -ManifestId $ManifestId -Bytes (Get-DepotContentSize -Path $target) }

    $reason = ''
    if (-not $ok -and $log) {
        if ($log -match 'Manifest not available')      { $reason = 'Valve no longer serves that manifest from the CDN.' }
        elseif ($log -match 'No subscription')         { $reason = 'This Steam account does not own the game.' }
        elseif ($log -match 'Cached credentials not found') { $reason = 'SteamCMD is not logged in.' }
        elseif ($log -match 'Disk write failure|No space') { $reason = 'Ran out of disk space.' }
        elseif ($log -match 'patch state file|File locked') {
            # Almost always an earlier SteamCMD still running and holding the file.
            # Say so plainly: without this the user sees only a bare failure and
            # has no way to know that ending one process fixes it. Defect 17.
            $reason = 'A previous SteamCMD is still running and holding its download file. Open Task Manager (Ctrl+Shift+Esc), Details tab, end any steamcmd.exe, then run this again. If that does not help, reboot.'
        }
    }

    return [pscustomobject]@{
        Ok     = $ok
        Path   = $target
        Bytes  = (Get-DirectorySize -Path $target)
        Reason = $reason
        Log    = $log
    }
}

function Get-DepotSizes {
    # Current public manifest download sizes. Used ONLY to estimate progress for
    # an older manifest - an old build's size is not published anywhere.
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$AccountName,
        [Parameter(Mandatory = $true)][string]$AppId
    )
    $o = Invoke-SteamCmd -Exe $Exe -Arguments @('+login', $AccountName, '+app_info_update', '1', '+app_info_print', $AppId, '+quit') -TimeoutSec 300
    $sizes = @{}
    if (-not $o) { return $sizes }
    $depot = $null
    foreach ($line in ($o -split "`n")) {
        if ($line -match '^\s{2,}"(\d{4,})"\s*$') {
            $depot = $matches[1]
        } elseif ($depot -and $line -match '"download"\s+"(\d+)"') {
            $sizes[$depot] = [long]$matches[1]
            $depot = $null
        }
    }
    return $sizes
}
