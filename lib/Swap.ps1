# Backing up saves, planning the file swap, applying it, and verifying it.
#
# The swap NEVER deletes anything in the game folder. It only overwrites files
# that the downloaded depot also contains. That single rule is what preserves
# mod installations (ModEngine2, Seamless Co-op, The Convergence and similar)
# which live alongside the game's own files rather than in a separate folder.

# --------------------------------------------------------------- hash cache
# Hashing a game's archives means reading tens of GB. The plan pass and the
# verification pass would otherwise hash the same depot files twice over, and a
# second run of the tool would hash them all again from scratch.
#
# Keying on path + size + last-write-time makes a stale entry effectively
# impossible: change a file in any way and the key changes with it.

$script:HashCache     = @{}
$script:HashCachePath = $null
$script:HashCacheDirty = $false

function Initialize-HashCache {
    param([Parameter(Mandatory = $true)][string]$PackRoot)
    $script:HashCachePath = Join-Path $PackRoot '.hashcache.json'
    $script:HashCache = @{}
    if (Test-Path -LiteralPath $script:HashCachePath) {
        try {
            $j = Get-Content -LiteralPath $script:HashCachePath -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $script:HashCache[$p.Name] = $p.Value }
        } catch { $script:HashCache = @{} }
    }
}

function Save-HashCache {
    if (-not $script:HashCachePath -or -not $script:HashCacheDirty) { return }
    try {
        # Keep it from growing without bound across many games and versions.
        if ($script:HashCache.Count -gt 20000) { $script:HashCache = @{} }
        $o = New-Object PSObject
        foreach ($k in $script:HashCache.Keys) { Add-Member -InputObject $o -NotePropertyName $k -NotePropertyValue $script:HashCache[$k] }
        $o | ConvertTo-Json -Compress | Set-Content -LiteralPath $script:HashCachePath -Encoding utf8
        $script:HashCacheDirty = $false
    } catch { }
}

function Get-CachedHash {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)
    $key = '{0}|{1}|{2}' -f $File.FullName.ToLower(), $File.Length, $File.LastWriteTimeUtc.Ticks
    if ($script:HashCache.ContainsKey($key)) { return $script:HashCache[$key] }
    $h = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
    $script:HashCache[$key] = $h
    $script:HashCacheDirty = $true
    return $h
}

function Get-SwapPlan {
    # Compares every file in the downloaded depots against the live install.
    # Size differences are decisive and free. Files matching on size are hashed,
    # because a same-size-different-content file is entirely possible.
    param(
        [Parameter(Mandatory = $true)][string]$GameDir,
        [Parameter(Mandatory = $true)][string[]]$DepotDirs
    )
    $actions = New-Object System.Collections.ArrayList
    $seen    = @{}

    # Gather first so we can show honest progress. Hashing a game's archives
    # means reading tens of GB twice over, which takes minutes - without a
    # progress indicator that is indistinguishable from a hang.
    $work = New-Object System.Collections.ArrayList
    foreach ($depot in $DepotDirs) {
        if (-not (Test-Path -LiteralPath $depot)) { continue }
        $depotFull = (Get-Item -LiteralPath $depot).FullName
        foreach ($src in (Get-ChildItem -LiteralPath $depotFull -Recurse -File -ErrorAction SilentlyContinue)) {
            if ($src.Name -eq '.sgdh-manifest.json') { continue }
            $rel = $src.FullName.Substring($depotFull.Length).TrimStart('\')
            # The same file can appear in more than one depot (shared anti-cheat
            # assets, for instance). Plan it once.
            if ($seen.ContainsKey($rel)) { continue }
            $seen[$rel] = $true
            [void]$work.Add([pscustomobject]@{ Rel = $rel; Src = $src.FullName; Size = $src.Length })
        }
    }

    # Only same-size files need hashing; a size difference is decisive and free.
    $toHash = [long]0
    foreach ($w in $work) {
        $d = Join-Path $GameDir $w.Rel
        if ((Test-Path -LiteralPath $d) -and ((Get-Item -LiteralPath $d).Length -eq $w.Size)) { $toHash += $w.Size }
    }

    $doneBytes = [long]0
    $n = 0
    $count = @($work).Count
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($w in $work) {
        $n++
        $dst = Join-Path $GameDir $w.Rel

        if (-not (Test-Path -LiteralPath $dst)) {
            [void]$actions.Add([pscustomobject]@{ Rel = $w.Rel; Src = $w.Src; Dst = $dst; Size = $w.Size; Why = 'missing' })
            continue
        }
        if ((Get-Item -LiteralPath $dst).Length -ne $w.Size) {
            [void]$actions.Add([pscustomobject]@{ Rel = $w.Rel; Src = $w.Src; Dst = $dst; Size = $w.Size; Why = 'size differs' })
            continue
        }

        if ($toHash -gt 0) {
            $pct = $doneBytes * 100.0 / $toHash
            $eta = '--:--'
            $el  = $sw.Elapsed.TotalSeconds
            if ($doneBytes -gt 0 -and $el -gt 2) {
                $rate = $doneBytes / $el
                # [math]::Max(0, ...) binds the Int32 overload because the literal
                # 0 is an int, and then overflows on any value above 2 GB. Game
                # archives are routinely 20 GB, so both arguments must be [long].
                $left = $toHash - $doneBytes
                if ($left -lt 0) { $left = [long]0 }
                if ($rate -gt 0) { $eta = '{0:mm\:ss}' -f [timespan]::FromSeconds($left / $rate) }
            }
            $label = $w.Rel
            if ($label.Length -gt 26) { $label = '...' + $label.Substring($label.Length - 23) }
            Write-Host ("`r  {0} {1,5:N1}%  [{2}/{3}] {4}  ETA {5}" -f (Format-ProgressBar -Percent $pct), $pct, $n, $count, $label, $eta).PadRight(96) -NoNewline
        }

        $hs = Get-CachedHash -File (Get-Item -LiteralPath $w.Src)
        $hd = Get-CachedHash -File (Get-Item -LiteralPath $dst)
        $doneBytes += $w.Size
        if ($hs -ne $hd) {
            [void]$actions.Add([pscustomobject]@{ Rel = $w.Rel; Src = $w.Src; Dst = $dst; Size = $w.Size; Why = 'content differs' })
        }
    }
    if ($toHash -gt 0) {
        Write-Host ("`r  {0} 100.0%  {1} file(s) checked" -f (Format-ProgressBar -Percent 100), $count).PadRight(96)
    }
    Save-HashCache
    return $actions
}

function Copy-FileWithProgress {
    # Copy-Item is opaque: a 19 GB game archive shows nothing for minutes, which
    # is indistinguishable from a hang. Stream it instead so progress can be
    # reported from inside the copy.
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [scriptblock]$OnProgress,
        [int]$BufferSize = 4194304
    )
    $in = $null; $out = $null
    try {
        $in  = [System.IO.File]::Open($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $out = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buf = New-Object byte[] $BufferSize
        $copied = [long]0
        $lastReport = [long]0
        while (($read = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $read)
            $copied += $read
            # Report roughly every 32 MB - often enough to look alive, rarely
            # enough not to cost anything.
            if ($OnProgress -and ($copied - $lastReport) -ge 33554432) {
                $lastReport = $copied
                & $OnProgress $copied
            }
        }
        $out.Flush()
        return $copied
    } finally {
        if ($out) { $out.Dispose() }
        if ($in)  { $in.Dispose() }
    }
}

function Invoke-Swap {
    # Each file is copied to a temporary name beside its destination and then
    # renamed into place. On the same volume that rename is atomic, so an
    # interruption can never leave a truncated 20 GB archive behind.
    param([Parameter(Mandatory = $true)]$Actions)

    $total = ($Actions | Measure-Object -Property Size -Sum).Sum
    if ($null -eq $total) { $total = 0 }
    $done  = [long]0
    $i     = 0
    $count = @($Actions).Count

    # If anything throws part-way through, remove the half-written temporary file
    # rather than leaving debris in the user's game folder.
    $tmp = $null
    try {
    foreach ($a in $Actions) {
        $i++
        $parent = Split-Path -Parent $a.Dst
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        $tmp = $a.Dst + '.sgdh-tmp'

        $w = 100
        try { if ($Host.UI.RawUI.WindowSize.Width -gt 20) { $w = $Host.UI.RawUI.WindowSize.Width - 1 } } catch { }

        $label = $a.Rel
        if ($label.Length -gt 30) { $label = '...' + $label.Substring($label.Length - 27) }

        $render = {
            param($fileCopied)
            $pct = 0
            if ($total -gt 0) { $pct = ($done + $fileCopied) * 100.0 / $total }
            $line = '  {0} {1,5:N1}%  [{2}/{3}] {4}' -f (Format-ProgressBar -Percent $pct), $pct, $i, $count, $label
            # A single archive can be 19 GB, so show where we are inside it too -
            # otherwise the bar sits still for minutes and looks hung.
            if ($a.Size -ge 268435456) {
                $line += '  {0:N1} / {1:N1} GB' -f ($fileCopied / 1GB), ($a.Size / 1GB)
            }
            Write-Host ("`r" + $line.PadRight($w)) -NoNewline
        }

        & $render 0
        Copy-FileWithProgress -Source $a.Src -Destination $tmp -OnProgress $render | Out-Null
        if (Test-Path -LiteralPath $a.Dst) {
            # Replace() swaps one existing file for another in a single step.
            #
            # The third argument MUST be [NullString]::Value, not $null. PowerShell
            # marshals a bare $null into a string parameter as an empty string, and
            # File.Replace rejects "" with "The path is not of a legal form" - it
            # accepts a real null (meaning "keep no backup") but not an empty one.
            [System.IO.File]::Replace($tmp, $a.Dst, [NullString]::Value)
        } else {
            # Replace() REQUIRES an existing destination and throws without one.
            # A file present in the older build but absent from the installed one
            # is entirely normal, so move it into place instead. Both operations
            # are atomic on the same volume, which is why the temporary file is
            # created beside its destination rather than in %TEMP%.
            [System.IO.File]::Move($tmp, $a.Dst)
        }
        $done += $a.Size
        $tmp = $null
    }
    } finally {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    $pct = 100
    Write-Host ("`r  {0} {1,5:N1}%  {2} file(s) replaced" -f (Format-ProgressBar -Percent $pct), $pct, $count).PadRight(96)
}

# ------------------------------------------------- what is ACTUALLY installed
# Steam's appmanifest records the build Steam believes is installed. After a
# downgrade that is deliberately left alone - editing it would make Steam think
# an update is due and re-patch the game. So the appmanifest reports the NEWER
# build even though older files are on disk, and cannot be trusted as the answer
# to "what version am I running?".
#
# Resolution order, most trustworthy first:
#   1. a marker this tool wrote into the game folder after a swap
#   2. the executable's own version resource, matched against known builds
#   3. the appmanifest, flagged as Steam's opinion rather than fact

function Get-InstalledMarker {
    param([Parameter(Mandatory = $true)][string]$GameDir)
    $p = Join-Path $GameDir '.sgdh-installed.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json) } catch { return $null }
}

function Set-InstalledMarker {
    param(
        [Parameter(Mandatory = $true)][string]$GameDir,
        [Parameter(Mandatory = $true)][string]$BuildId,
        [string]$Label
    )
    $p = Join-Path $GameDir '.sgdh-installed.json'
    $o = [pscustomobject]@{
        buildid   = $BuildId
        label     = $Label
        appliedAt = (Get-Date).ToString('s')
        note      = 'Written by Steam Game Downgrade Helper. Steam''s own appmanifest still lists the newer build on purpose, so that Steam does not try to re-patch the game.'
    }
    try { $o | ConvertTo-Json | Set-Content -LiteralPath $p -Encoding utf8 } catch { }
}

function Resolve-ActualBuild {
    # Returns the build actually on disk plus how confident we are, so the caller
    # can be honest with the user rather than asserting something it cannot know.
    param(
        [Parameter(Mandatory = $true)]$Game,
        $KnownBuilds
    )
    # The marker records what THIS TOOL last installed. It is evidence of what we
    # did, NOT of what is on disk now, and it goes stale the moment anything else
    # touches the game - most commonly "Verify integrity of game files", which is
    # the very undo path this tool recommends.
    #
    # Left unchecked that is not merely a wrong label: the caller uses the same
    # value to refuse a build the user "already has", so a user who verified back
    # to the current version would be blocked from downgrading again.
    #
    # So corroborate it two ways before trusting it. Physical evidence on disk
    # beats a memory of what we did.
    $exes   = @(Get-ExeVersions -GameDir $Game.InstallDir)
    $marker = Get-InstalledMarker -GameDir $Game.InstallDir

    if ($marker -and $marker.buildid) {
        $stale  = $false
        $reason = ''

        # (1) Precise check, needs the build to be curated with an exeVersion.
        #     Stale if the expected executable version is nowhere to be seen AND
        #     some OTHER known build's version is present instead.
        if ($KnownBuilds -and $KnownBuilds.ContainsKey([string]$marker.buildid)) {
            $expectedExe = $KnownBuilds[[string]$marker.buildid].exeVersion
            if ($expectedExe -and @($exes).Count -gt 0) {
                $seen = @($exes | ForEach-Object { $_.Version })
                if ($seen -notcontains $expectedExe) {
                    foreach ($k in $KnownBuilds.Keys) {
                        $b = $KnownBuilds[$k]
                        if ($b.exeVersion -and $seen -contains $b.exeVersion) {
                            $stale  = $true
                            $reason = "the game's executable is version $($b.exeVersion), not the $expectedExe this marker claims"
                            break
                        }
                    }
                }
            }
        }

        # (2) General check, works for ANY game with no curated data at all.
        #     The swap writes the files and then the marker, so the marker is
        #     always newer than the files it describes. Game files newer than the
        #     marker mean something else has written to the install since.
        if (-not $stale -and $marker.appliedAt) {
            try {
                $written = [datetime]::Parse($marker.appliedAt)
                # A minute of slack absorbs ordinary filesystem timestamp drift.
                $cutoff  = $written.AddMinutes(1)
                $newer = Get-ChildItem -LiteralPath $Game.InstallDir -Recurse -File -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -ne '.sgdh-installed.json' -and $_.LastWriteTime -gt $cutoff } |
                         Select-Object -First 1
                if ($newer) {
                    $stale  = $true
                    $reason = "game files have been changed since (for example $($newer.Name)), so Steam or something else has written to this install"
                }
            } catch { }
        }

        if (-not $stale) {
            return [pscustomobject]@{
                BuildId = [string]$marker.buildid; Label = $marker.label
                Source = 'this tool downgraded it'; Certain = $true
            }
        }
        Write-Warning "Ignoring this tool's own record of a previous downgrade: $reason."
        # Fall through to the executable, which is now the better evidence.
    }

    # Match the executable's version against the known table. Catches installs
    # downgraded before the marker existed, done by hand, or changed underneath
    # us by a Steam update or verify.
    if ($KnownBuilds) {
        foreach ($k in $KnownBuilds.Keys) {
            $b = $KnownBuilds[$k]
            if (-not $b.exeVersion) { continue }
            foreach ($e in $exes) {
                if ($e.Version -and $e.Version -eq $b.exeVersion) {
                    return [pscustomobject]@{
                        BuildId = [string]$b.buildid; Label = $b.label
                        Source = ("matched {0} version {1}" -f $e.Name, $e.Version); Certain = $true
                    }
                }
            }
        }
    }

    return [pscustomobject]@{
        BuildId = $Game.BuildId; Label = ''
        Source = 'according to Steam'; Certain = $false
    }
}

function Get-ExeVersions {
    # After a downgrade the executable's version resource is the cheapest proof
    # that the correct build is now on disk.
    param([Parameter(Mandatory = $true)][string]$GameDir)
    $out = New-Object System.Collections.ArrayList
    Get-ChildItem -LiteralPath $GameDir -Recurse -File -Filter '*.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 1MB } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.VersionInfo.FileVersion) } |
        ForEach-Object {
            [void]$out.Add([pscustomobject]@{
                Name    = $_.Name
                Path    = $_.FullName
                Version = $_.VersionInfo.FileVersion
                Size    = $_.Length
            })
        }
    return $out
}

function Format-Bytes {
    param([double]$Bytes)
    $u = @('B', 'KB', 'MB', 'GB', 'TB')
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt ($u.Count - 1)) { $Bytes = $Bytes / 1024; $i++ }
    return ('{0:N1} {1}' -f $Bytes, $u[$i])
}
