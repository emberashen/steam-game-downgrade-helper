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

function Get-SteamBuildEvents {
    # Fetches build information from Steam's public endpoints including
    # build IDs, patch titles, dates, and patch notes where available.
    # Queries both the Events API and News API for better coverage.
    # No API key required, no scraping, no third-party site.
    #
    # COVERAGE IS THIN AND UNEVEN. Developers frequently don't attach patch notes
    # to builds, so missing data is common and must be handled gracefully.
    param(
        [Parameter(Mandatory = $true)][string]$AppId,
        [int]$TimeoutSec = 15
    )
    
    $events = New-Object System.Collections.ArrayList
    $eventsByBuildId = @{}
    
    # First, query the Events API for builds with build_id tags
    $url = 'https://store.steampowered.com/events/ajaxgetpartnereventspageable/' +
           "?clan_accountid=0&appid=$AppId&offset=0&count=100&l=english"
    try {
        $old = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        $r = Invoke-RestMethod -Uri $url -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        $ProgressPreference = $old
    } catch {
        # offline, blocked, rate-limited - continue to News API
        $r = $null
    }
    
    if ($r -and $r.events) {
        foreach ($e in $r.events) {
            $bid = $null
            if ($e.PSObject.Properties.Name -contains 'build_id') { $bid = [string]$e.build_id }
            if (-not $bid -or $bid -eq '0') { continue }

            $title = ''
            if ($e.PSObject.Properties.Name -contains 'event_name') { $title = [string]$e.event_name }
            
            $date = $null
            if ($e.PSObject.Properties.Name -contains 'rtime32_start_time') {
                try { $date = [DateTimeOffset]::FromUnixTimeSeconds($e.rtime32_start_time).DateTime }
                catch { }
            }
            
            # Extract patch notes from jsondata
            $patchNotes = ''
            $version = ''
            if ($e.jsondata) {
                try {
                    $jd = $e.jsondata
                    if ($jd -is [string]) { $jd = $jd | ConvertFrom-Json }
                    
                    # Try to get title from jsondata if not in event_name
                    if (-not $title -and $jd.localized_title) { 
                        $title = [string]@($jd.localized_title)[0] 
                    }
                    
                    # Extract patch notes body
                    if ($jd.body) { $patchNotes = [string]$jd.body }
                    elseif ($jd.localized_body) {
                        $bodyObj = $jd.localized_body
                        if ($bodyObj -is [string]) { $patchNotes = $bodyObj }
                        elseif ($bodyObj.PSObject.Properties.Name -contains 'english') {
                            $patchNotes = [string]$bodyObj.english
                        }
                    }
                } catch { }
            }
            
            # Extract version from title
            if ($title) {
                $m = [regex]::Match($title, '(?i)(?:version|update|patch|v)\s*[:\-]?\s*(\d+\.\d+(?:\.\d+)?)')
                if ($m.Success) { $version = $m.Groups[1].Value }
                else {
                    $m2 = [regex]::Match($title, '\b(\d+\.\d+(?:\.\d+)?)\b')
                    if ($m2.Success) { $version = $m2.Groups[1].Value }
                }
            }

            $eventObj = [pscustomobject]@{
                BuildId     = $bid
                PatchTitle  = $title
                Version     = $version
                Date        = $date
                PatchNotes  = $patchNotes
            }
            [void]$events.Add($eventObj)
            $eventsByBuildId[$bid] = $eventObj
        }
    }
    
    # Second, query the News API for patch notes posted as community announcements
    # News items don't include build IDs, so we match them to events by date proximity
    $newsUrl = "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid=$AppId&count=50&maxlength=0"
    try {
        $news = Invoke-RestMethod -Uri $newsUrl -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
    } catch {
        $news = $null
    }
    
    if ($news -and $news.appnews -and $news.appnews.newsitems) {
        # Filter to only community announcements (official patch notes)
        $announcements = $news.appnews.newsitems | Where-Object { $_.feedname -eq 'steam_community_announcements' }
        
        foreach ($item in $announcements) {
            $newsDate = $null
            if ($item.date) {
                try { $newsDate = [DateTimeOffset]::FromUnixTimeSeconds($item.date).DateTime }
                catch { continue }
            }
            if (-not $newsDate) { continue }
            
            $title = if ($item.title) { [string]$item.title } else { '' }
            $patchNotes = if ($item.contents) { [string]$item.contents } else { '' }
            
            # Skip if no patch notes
            if (-not $patchNotes) { continue }
            
            # Try to find a matching event by date (within 24 hours)
            $matchedEvent = $null
            foreach ($event in $events) {
                if ($event.Date -and [Math]::Abs(($event.Date - $newsDate).TotalHours) -lt 24) {
                    $matchedEvent = $event
                    break
                }
            }
            
            if ($matchedEvent) {
                # Update existing event with patch notes from News
                if (-not $matchedEvent.PatchNotes) {
                    $matchedEvent.PatchNotes = $patchNotes
                }
                if (-not $matchedEvent.PatchTitle -and $title) {
                    $matchedEvent.PatchTitle = $title
                }
            } else {
                # No matching event found, try to extract build ID from title/contents
                $bid = $null
                
                # Try to extract from title
                if ($title -match '(?i)(?:build|update)\s*[:\-]?\s*(\d{7,})') {
                    $bid = $matches[1]
                }
                
                # Try to extract from body/content
                if (-not $bid -and $patchNotes -match '(?i)(?:build|buildid|build_id)\s*[:\-]?\s*"?(\d{7,})"?') {
                    $bid = $matches[1]
                }
                
                if ($bid) {
                    # Extract version from title
                    $version = ''
                    if ($title) {
                        $m = [regex]::Match($title, '(?i)(?:version|update|patch|v)\s*[:\-]?\s*(\d+\.\d+(?:\.\d+)?)')
                        if ($m.Success) { $version = $m.Groups[1].Value }
                        else {
                            $m2 = [regex]::Match($title, '\b(\d+\.\d+(?:\.\d+)?)\b')
                            if ($m2.Success) { $version = $m2.Groups[1].Value }
                        }
                    }
                    
                    # Add new event from News
                    $eventObj = [pscustomobject]@{
                        BuildId     = $bid
                        PatchTitle  = $title
                        Version     = $version
                        Date        = $newsDate
                        PatchNotes  = $patchNotes
                    }
                    [void]$events.Add($eventObj)
                    $eventsByBuildId[$bid] = $eventObj
                }
            }
        }
    }
    
    return $events
}

function ConvertFrom-SteamBBCode {
    # Converts Steam's BBCode-formatted patch notes to plain text for console display
    param(
        [Parameter(Mandatory = $true)][string]$Text
    )
    
    if (-not $Text) { return '' }
    
    $result = $Text
    
    # Remove HTML tags that might be mixed in
    $result = $result -replace '<[^>]+>', ''
    
    # Convert headers to uppercase with underline
    $result = $result -replace '\[h1\]([^\[]+)\[/h1\]', "`n`$1`n$('=' * 60)"
    $result = $result -replace '\[h2\]([^\[]+)\[/h2\]', "`n`$1`n$('-' * 40)"
    $result = $result -replace '\[h3\]([^\[]+)\[/h3\]', "`n`$1"
    
    # Convert lists
    $result = $result -replace '\[list\]', ''
    $result = $result -replace '\[/list\]', "`n"
    $result = $result -replace '\[\*\]\s*', '  - '
    
    # Convert bold and italic
    $result = $result -replace '\[b\]([^\[]+)\[/b\]', '$1'
    $result = $result -replace '\[i\]([^\[]+)\[/i\]', '$1'
    $result = $result -replace '\[u\]([^\[]+)\[/u\]', '$1'
    
    # Convert URLs - show just the text or the URL
    $result = $result -replace '\[url=([^\]]+)\]([^\[]+)\[/url\]', '$2 ($1)'
    $result = $result -replace '\[url\]([^\[]+)\[/url\]', '$1'
    
    # Convert images - remove them
    $result = $result -replace '\[img\][^\[]*\[/img\]', '[Image]'
    
    # Convert quotes
    $result = $result -replace '\[quote\]([^\[]+)\[/quote\]', "`n> `$1`n"
    
    # Convert line breaks and paragraphs
    $result = $result -replace '\[br\]', "`n"
    $result = $result -replace '\[/p\]\s*\[p\]', "`n`n"
    $result = $result -replace '\[p\]', ''
    $result = $result -replace '\[/p\]', "`n"
    
    # Remove any remaining BBCode tags
    $result = $result -replace '\[/?[a-z]+\d*(?:=[^\]]+)?\]', ''
    
    # Decode HTML entities
    $result = $result -replace '&amp;', '&'
    $result = $result -replace '&lt;', '<'
    $result = $result -replace '&gt;', '>'
    $result = $result -replace '&quot;', '"'
    $result = $result -replace '&#39;', "'"
    $result = $result -replace '&nbsp;', ' '
    
    # Clean up excessive whitespace
    $result = $result -replace '\n{3,}', "`n`n"
    $result = $result -replace '[ \t]+', ' '
    
    return $result.Trim()
}

function Get-SteamBuildLabels {
    # Backward compatibility wrapper - returns hashtable of buildid -> version label
    # for existing code that expects this format.
    param(
        [Parameter(Mandatory = $true)][string]$AppId,
        [int]$TimeoutSec = 12
    )
    $map = @{}
    $events = Get-SteamBuildEvents -AppId $AppId -TimeoutSec $TimeoutSec
    foreach ($e in $events) {
        if ($e.Version -and -not $map.ContainsKey($e.BuildId)) {
            $map[$e.BuildId] = $e.Version
        }
    }
    return $map
}

function Get-SteamLiveBuild {
    # Queries Steam's PICS network via SteamCMD to get the current live build ID
    # from the public branch. This is the authoritative source for what's actually
    # live on Steam's servers right now.
    param(
        [Parameter(Mandatory = $true)][string]$SteamCmdExe,
        [Parameter(Mandatory = $true)][string]$AppId,
        [int]$TimeoutSec = 60
    )
    
    if (-not (Test-Path -LiteralPath $SteamCmdExe)) {
        return $null
    }
    
    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        $cmdLine = "`"$SteamCmdExe`" +login anonymous +app_info_update 1 +app_info_print $AppId +quit"
        $process = Start-Process -FilePath $SteamCmdExe -ArgumentList "+login anonymous +app_info_update 1 +app_info_print $AppId +quit" `
            -RedirectStandardOutput $tempFile -NoNewWindow -Wait -PassThru
        
        if ($process.ExitCode -ne 0) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
            return $null
        }
        
        $output = Get-Content -LiteralPath $tempFile -Raw -ErrorAction SilentlyContinue
        if (-not $output) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
            return $null
        }
        
        # Parse the VDF-like output to find depots -> branches -> public -> buildid
        # The output format is:
        # "depots"
        # {
        #     "branches"
        #     {
        #         "public"
        #         {
        #             "buildid"    "12345678"
        #             ...
        #         }
        #     }
        # }
        
        # Look for the pattern: "public" followed by "buildid" with a value
        $publicPattern = '"public"\s*\{[^}]*"buildid"\s+"(\d+)"'
        $match = [regex]::Match($output, $publicPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
        
        if ($match.Success) {
            return $match.Groups[1].Value
        }
        
        return $null
    } catch {
        return $null
    } finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
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
