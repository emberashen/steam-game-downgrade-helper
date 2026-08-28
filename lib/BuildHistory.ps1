# Recovers a game's build history from Steam's own content log.
#
# Steam records, per app:
#   "... finished update, N mounted depots (BuildID <b>) : <depot> (<manifest>),..."
#   "... state changed : ...App Running..."
#
# Attributing play sessions to the build in force at the time lets us rank
# candidate builds by evidence the user actually played them - which is a far
# better question to ask a user than "which patch number do you want?".
#
# Limits, which callers MUST surface to the user:
#  - only builds THIS machine installed appear;
#  - a fresh Steam install has no history at all;
#  - builds the machine skipped are absent.

function Get-BuildHistory {
    param(
        [Parameter(Mandatory = $true)][string]$SteamRoot,
        [Parameter(Mandatory = $true)][string]$AppId
    )

    $logDir = Join-Path $SteamRoot 'logs'
    $files  = @()
    foreach ($n in @('content_log.previous.txt', 'content_log.txt')) {
        $p = Join-Path $logDir $n
        if (Test-Path -LiteralPath $p) { $files += $p }
    }
    if ($files.Count -eq 0) { return @() }

    $reBuild = [regex]("^\[([\d\-]+ [\d:]+)\] AppID $AppId finished update.*?\(BuildID (\d+)\) : (.*)$")
    $reRun   = [regex]("^\[([\d\-]+ [\d:]+)\] AppID $AppId state changed : .*App Running")
    $reDepot = [regex]('(\d+) \((\d+)\)')

    $builds = New-Object System.Collections.ArrayList
    $runs   = New-Object System.Collections.ArrayList

    foreach ($f in $files) {
        # Steam keeps content_log.txt open while running, so a plain read fails
        # with a sharing violation. Open with FileShare::ReadWrite to read a file
        # another process is actively writing.
        $fs = $null; $sr = $null
        try {
            $fs = New-Object System.IO.FileStream(
                $f, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
            $sr = New-Object System.IO.StreamReader($fs)
        } catch {
            Write-Warning "Could not read $f : $($_.Exception.Message)"
            if ($sr) { $sr.Dispose() }; if ($fs) { $fs.Dispose() }
            continue
        }
        while ($null -ne ($line = $sr.ReadLine())) {
            if ($line -notlike "*AppID $AppId *") { continue }
            $m = $reBuild.Match($line)
            if ($m.Success) {
                $depots = [ordered]@{}
                foreach ($d in $reDepot.Matches($m.Groups[3].Value)) {
                    $depots[$d.Groups[1].Value] = $d.Groups[2].Value
                }
                [void]$builds.Add([pscustomobject]@{
                    When    = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', $null)
                    BuildId = $m.Groups[2].Value
                    Depots  = $depots
                })
                continue
            }
            $m = $reRun.Match($line)
            if ($m.Success) {
                [void]$runs.Add([datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', $null))
            }
        }
        $sr.Dispose(); $fs.Dispose()
    }
    if ($builds.Count -eq 0) { return @() }

    $builds = @($builds | Sort-Object When)
    $runs   = @($runs   | Sort-Object)

    # Attribute each play session to the build in force when it happened.
    $rows = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $builds.Count; $i++) {
        $start = $builds[$i].When
        if ($i + 1 -lt $builds.Count) { $end = $builds[$i + 1].When } else { $end = [datetime]::MaxValue }
        $window = @($runs | Where-Object { $_ -ge $start -and $_ -lt $end })
        $last = $null
        if ($window.Count -gt 0) { $last = $window[-1] }
        [void]$rows.Add([pscustomobject]@{
            BuildId    = $builds[$i].BuildId
            Installed  = $start
            LastPlayed = $last
            Sessions   = $window.Count
            Depots     = $builds[$i].Depots
        })
    }

    # Steam re-logs "finished update" on verification and when a DLC is added, so
    # the same BuildId can appear several times. Collapse to one row per build:
    # keep the depot set with the MOST depots (a later row may add a DLC depot),
    # take the earliest install, the latest play, and the summed session count.
    $merged = New-Object System.Collections.ArrayList
    foreach ($grp in ($rows | Group-Object BuildId)) {
        $items = @($grp.Group)
        $best = $items[0]
        foreach ($it in $items) { if ($it.Depots.Count -gt $best.Depots.Count) { $best = $it } }
        # NOTE: the @() must wrap the WHOLE pipeline including Sort-Object.
        # @(...) | Sort-Object unrolls a single-element array back to a scalar
        # PSCustomObject, which in PS 5.1 has no .Count - so a .Count test
        # silently evaluates false and the value is lost with no error.
        $played = @($items | Where-Object { $null -ne $_.LastPlayed } | Sort-Object LastPlayed)
        $lastPlayed = $null
        if ($played.Count -gt 0) { $lastPlayed = $played[$played.Count - 1].LastPlayed }
        $byInstall = @($items | Sort-Object Installed)
        [void]$merged.Add([pscustomobject]@{
            BuildId    = $grp.Name
            Installed  = $byInstall[0].Installed
            LastPlayed = $lastPlayed
            Sessions   = ($items | Measure-Object -Property Sessions -Sum).Sum
            Depots     = $best.Depots
        })
    }
    return @($merged | Sort-Object Installed -Descending)
}

function Get-CachedManifests {
    # Manifests still present in Steam's depot cache corroborate the log and can
    # occasionally surface a build the log has rotated away.
    param([Parameter(Mandatory = $true)][string]$SteamRoot, [Parameter(Mandatory = $true)]$DepotIds)
    $dir = Join-Path $SteamRoot 'depotcache'
    $out = @{}
    if (-not (Test-Path -LiteralPath $dir)) { return $out }
    foreach ($d in $DepotIds) {
        $hits = Get-ChildItem -LiteralPath $dir -Filter "$d`_*.manifest" -ErrorAction SilentlyContinue
        foreach ($h in $hits) {
            if ($h.BaseName -match '^(\d+)_(\d+)$') {
                if (-not $out.ContainsKey($matches[1])) { $out[$matches[1]] = New-Object System.Collections.ArrayList }
                [void]$out[$matches[1]].Add([pscustomobject]@{ Manifest = $matches[2]; Modified = $h.LastWriteTime })
            }
        }
    }
    return $out
}

function Get-SteamBuildLabels {
    # Fetches patch titles from Steam's OWN public events endpoint and maps them
    # to build IDs. No API key, no scraping, no third-party site.
    #
    # SteamDB is the obvious place to look for this and explicitly asks people not
    # to scrape it ("there's a chance you'll get automatically banned"), pointing
    # at Steam directly instead. This is that. `build_id` is a first-class field
    # on the event.
    #
    # COVERAGE IS THIN AND UNEVEN. Measured on Elden Ring: 93 events, of which
    # only 6 carried a build id, and neither the build that broke mods nor the one
    # people want to return to was among them. Developers simply stop attaching
    # patch notes to builds. So this is ENRICHMENT - a nicer label where one
    # exists - and must never be required for anything to work.
    param(
        [Parameter(Mandatory = $true)][string]$AppId,
        [int]$TimeoutSec = 12
    )
    $map = @{}
    $url = 'https://store.steampowered.com/events/ajaxgetpartnereventspageable/' +
           "?clan_accountid=0&appid=$AppId&offset=0&count=100&l=english"
    try {
        $old = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        $r = Invoke-RestMethod -Uri $url -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        $ProgressPreference = $old
    } catch {
        return $map   # offline, blocked, rate-limited - all fine, just no labels
    }
    if (-not $r -or -not $r.events) { return $map }

    foreach ($e in $r.events) {
        $bid = $null
        if ($e.PSObject.Properties.Name -contains 'build_id') { $bid = [string]$e.build_id }
        if (-not $bid -or $bid -eq '0') { continue }

        $title = ''
        if ($e.PSObject.Properties.Name -contains 'event_name') { $title = [string]$e.event_name }
        if (-not $title -and $e.jsondata) {
            try {
                $jd = $e.jsondata
                if ($jd -is [string]) { $jd = $jd | ConvertFrom-Json }
                if ($jd.localized_title) { $title = [string]@($jd.localized_title)[0] }
            } catch { }
        }
        if (-not $title) { continue }

        # Pull a version out of the title where there is one. Titles vary wildly:
        # "ELDEN RING - Patch Notes Version 1.16.1" yields 1.16.1, while
        # "Release Note for 2025/12/16" yields nothing and is skipped.
        $ver = $null
        $m = [regex]::Match($title, '(?i)(?:version|update|patch|v)\s*[:\-]?\s*(\d+\.\d+(?:\.\d+)?)')
        if ($m.Success) { $ver = $m.Groups[1].Value }
        else {
            $m2 = [regex]::Match($title, '\b(\d+\.\d+(?:\.\d+)?)\b')
            if ($m2.Success) { $ver = $m2.Groups[1].Value }
        }
        if (-not $ver) { continue }
        if (-not $map.ContainsKey($bid)) { $map[$bid] = $ver }
    }
    return $map
}

function Get-KnownBuilds {
    # Curated labels shipped with the pack. Manifest IDs are global CDN addresses,
    # not per-machine, so a harvested entry works on any machine owning the game.
    param([Parameter(Mandatory = $true)][string]$PackRoot, [Parameter(Mandatory = $true)][string]$AppId)
    $p = Join-Path $PackRoot 'data\known-builds.json'
    if (-not (Test-Path -LiteralPath $p)) { return @{} }
    try { $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } catch { return @{} }
    $map = @{}
    foreach ($app in $j.apps) {
        if ($app.appid -ne $AppId) { continue }
        foreach ($b in $app.builds) { $map[$b.buildid] = $b }
    }
    return $map
}
