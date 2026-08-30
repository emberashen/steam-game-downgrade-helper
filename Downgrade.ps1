<#
    Steam Game Downgrade Helper
    Rolls a Steam game back to an earlier build, for when a mandatory update
    breaks a modded setup.

    Run it via Downgrade.bat - that sets the execution policy for this process
    only, which is what stops Windows blocking a script downloaded from the web.

    Nothing here is specific to any one machine. Steam's location, its library
    folders, the game's install directory, the user profile and the drive
    letters are all discovered at runtime.
#>
[CmdletBinding()]
param(
    [string]$AppId,
    [switch]$NoBanner
)

$ErrorActionPreference = 'Stop'
$PackRoot = $PSScriptRoot

# Bumped only when a release goes out, never for changes between releases. It
# exists so a bug report can say which build it came from: without it, neither
# the user nor anyone helping them can tell whether a fix is already in the copy
# they are running. V1 was the launch build and carries no version string at all,
# so "no version shown" means V1.
$PackVersion = 'V2'

. "$PackRoot\lib\Vdf.ps1"
. "$PackRoot\lib\Steam.ps1"
. "$PackRoot\lib\BuildHistory.ps1"
. "$PackRoot\lib\SteamCmd.ps1"
. "$PackRoot\lib\Swap.ps1"

# Speeds up the file comparison, and the verification pass that follows it, by
# not re-hashing files whose size and timestamp are unchanged.
Initialize-HashCache -PackRoot $PackRoot

# ---------------------------------------------------------------- presentation

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
}

function Write-Step { param([string]$Text) Write-Host ''; Write-Host ">> $Text" -ForegroundColor Yellow }
function Write-Note { param([string]$Text) Write-Host "   $Text" -ForegroundColor Gray }
function Write-Warn { param([string]$Text) Write-Host "   ! $Text" -ForegroundColor Magenta }
function Write-Good { param([string]$Text) Write-Host "   + $Text" -ForegroundColor Green }
function Write-Bad  { param([string]$Text) Write-Host "   X $Text" -ForegroundColor Red }

function Read-Choice {
    param([string]$Prompt, [string[]]$Valid, [string]$Default)
    while ($true) {
        $hint = ''
        if ($Default) { $hint = " [$Default]" }
        $a = Read-Host ("   $Prompt$hint")
        if ([string]::IsNullOrWhiteSpace($a) -and $Default) { return $Default }
        $a = $a.Trim()
        if (-not $Valid -or $Valid -contains $a.ToLower()) { return $a.ToLower() }
        Write-Warn "Please answer one of: $($Valid -join ', ')"
    }
}

function Confirm-YesNo {
    param([string]$Prompt, [string]$Default = 'y')
    return ((Read-Choice -Prompt $Prompt -Valid @('y', 'n') -Default $Default) -eq 'y')
}

function Stop-Pack {
    param([string]$Message)
    Write-Host ''
    Write-Bad $Message
    Write-Host ''
    Read-Host '   Press Enter to close'
    exit 1
}

# ------------------------------------------------------------------- banner

if (-not $NoBanner) {
    Clear-Host
    Write-Host ''
    Write-Host ('   STEAM GAME DOWNGRADE HELPER   {0}' -f $PackVersion) -ForegroundColor White
    Write-Host '   Roll a Steam game back to an earlier build.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '   Nothing is changed without showing you first and asking.' -ForegroundColor DarkGray
    Write-Host '   Your Steam password is never asked for, stored or seen by this script.' -ForegroundColor DarkGray
}

# =====================================================  STEP 0  ==============
Write-Head 'STEP 0 of 11 - Stop Steam re-patching the game'

Write-Note 'Steam has no "never update" option. The strongest setting available is'
Write-Note '"Only update this game when I launch it", and it must be set BEFORE we'
Write-Note 'start, or Steam can re-patch the game midway and undo everything.'
Write-Host ''
Write-Note 'In the Steam client:'
Write-Note '   right-click the game  >  Properties  >  Updates'
Write-Note '   set Automatic Updates to "Only update this game when I launch it"'
Write-Host ''
Write-Note 'Two more things that will undo a downgrade, so worth knowing now:'
Write-Note '   - Launch the game from its mod loader (.bat / launcher .exe),'
Write-Note '     NOT by pressing Play in Steam.'
Write-Note '   - NEVER use "Verify integrity of game files" afterwards. It compares'
Write-Note '     against the CURRENT patch and would re-download it.'
Write-Host ''
if (-not (Confirm-YesNo 'Ready to continue? (y/n)')) { Stop-Pack 'Stopped at your request. Nothing was changed.' }

# =====================================================  STEP 1  ==============
Write-Head 'STEP 1 of 11 - Finding Steam'

$SteamRoot = Get-SteamRoot
if (-not $SteamRoot) { Stop-Pack 'Could not find a Steam installation on this PC.' }
Write-Good "Steam found at: $SteamRoot"

$Libraries = Get-SteamLibraries -SteamRoot $SteamRoot
if (@($Libraries).Count -eq 0) { Stop-Pack 'Found Steam but could not read any library folders.' }
Write-Good ("{0} library folder(s):" -f @($Libraries).Count)
foreach ($l in $Libraries) { Write-Note "   $($l.Path)" }

$Games = @(Get-SteamGames -Libraries $Libraries | Where-Object { $_.Installed })
if (@($Games).Count -eq 0) { Stop-Pack 'No installed games found in any Steam library.' }
Write-Good ("{0} installed game(s) found" -f @($Games).Count)

$Accounts = Get-SteamAccounts -SteamRoot $SteamRoot
if (@($Accounts).Count -eq 0) { Stop-Pack 'No Steam accounts found. Sign in to the Steam client at least once, then re-run.' }

# =====================================================  STEP 2  ==============
Write-Head 'STEP 2 of 11 - Choose the game'

$Game = $null
if ($AppId) { $Game = $Games | Where-Object { $_.AppId -eq $AppId } | Select-Object -First 1 }

if (-not $Game) {
    for ($i = 0; $i -lt @($Games).Count; $i++) {
        $g = $Games[$i]
        Write-Host ('   {0,3}. {1,-46} {2,10}  {3}' -f ($i + 1), $g.Name, $g.AppId, (Split-Path -Qualifier $g.InstallDir))
    }
    Write-Host ''
    while (-not $Game) {
        $sel = Read-Host '   Enter the number of the game (or q to quit)'
        if ($sel -eq 'q') { Stop-Pack 'Stopped at your request. Nothing was changed.' }
        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le @($Games).Count) { $Game = $Games[$n - 1] }
        else { Write-Warn 'Not a valid number from the list.' }
    }
}
Write-Good "Selected: $($Game.Name)  (AppID $($Game.AppId))"

# =====================================================  STEP 3  ==============
Write-Head 'STEP 3 of 11 - Locating the game files'

if (-not (Test-Path -LiteralPath $Game.InstallDir)) { Stop-Pack "The game's folder does not exist: $($Game.InstallDir)" }
Write-Good "Install folder : $($Game.InstallDir)"

# Steam's appmanifest says what Steam BELIEVES is installed. After a downgrade
# it is deliberately left untouched, so it keeps naming the newer build. Work
# out what is really on disk before telling the user anything.
$Known   = Get-KnownBuilds -PackRoot $PackRoot -AppId $Game.AppId
# Version names Steam itself publishes, used only to put a friendlier name next
# to a build. Coverage is patchy and a missing name changes nothing.
$SteamLabels = Get-SteamBuildLabels -AppId $Game.AppId
$Actual  = Resolve-ActualBuild -Game $Game -KnownBuilds $Known
$CurrentBuildId = $Actual.BuildId

$lbl = ''
if ($Actual.Label) { $lbl = " (version $($Actual.Label))" }
Write-Good ("Current build  : {0}{1}   [{2}]" -f $Actual.BuildId, $lbl, $Actual.Source)
if ($Actual.Certain -and $Actual.BuildId -ne $Game.BuildId) {
    Write-Note "Steam's records still say $($Game.BuildId). That is expected and correct -"
    Write-Note 'leaving them alone is what stops Steam re-patching the game.'
}

$autoText = 'unknown'
if ($Game.AutoUpdate -eq '0') { $autoText = 'Always keep up to date  <-- NOT what we want' }
if ($Game.AutoUpdate -eq '1') { $autoText = 'Only update when I launch it  <-- correct' }
if ($Game.AutoUpdate -eq '2') { $autoText = 'High priority  <-- NOT what we want' }
Write-Good "Update setting : $autoText"
if ($Game.AutoUpdate -ne '1') {
    Write-Warn 'That update setting can re-patch the game. Go back and set it now (Step 0).'
    if (-not (Confirm-YesNo 'Continue anyway? (y/n)' 'n')) { Stop-Pack 'Stopped so you can change the update setting.' }
}

$CurrentDepots = [ordered]@{}
if ($Game.Depots) { foreach ($d in $Game.Depots.Keys) { $CurrentDepots[$d] = $Game.Depots.$d.manifest } }
Write-Good ("Installed depots: {0}" -f (($CurrentDepots.Keys | ForEach-Object { $_ }) -join ', '))

if (Test-GameRunning -InstallDir $Game.InstallDir) { Stop-Pack 'That game is running. Close it and re-run this tool.' }

$Owner = Resolve-OwnerAccount -Game $Game -Accounts $Accounts
if (-not $Owner) {
    Write-Warn 'Could not tell which Steam account owns this game.'
    for ($i = 0; $i -lt @($Accounts).Count; $i++) {
        Write-Host ('   {0,3}. {1,-24} {2}' -f ($i + 1), $Accounts[$i].AccountName, $Accounts[$i].PersonaName)
    }
    $n = 0
    while (-not $Owner) {
        $sel = Read-Host '   Which account owns this game? Enter a number'
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le @($Accounts).Count) { $Owner = $Accounts[$n - 1] }
    }
}
Write-Good "Owned by account: $($Owner.AccountName)"

# ===============================================  STEPS 4 and 5  =============
Write-Head 'STEPS 4 and 5 of 11 - SteamCMD'

$SteamCmdExe = Find-SteamCmd
if ($SteamCmdExe) {
    Write-Good "SteamCMD already installed: $SteamCmdExe"
} else {
    Write-Note 'SteamCMD is not installed. It is Valve''s own command-line tool and is'
    Write-Note 'what actually downloads the older version of the game.'
    Write-Host ''
    Write-Warn 'IMPORTANT - choose where it goes carefully:'
    Write-Note '  Game downloads land INSIDE the SteamCMD folder (it ignores any other'
    Write-Note '  setting), and they can be TENS OF GIGABYTES.'
    Write-Note '  They are kept afterwards on purpose: if the game updates again, rolling'
    Write-Note '  back becomes a two-minute local copy instead of another long download.'
    Write-Note '  You can delete the folder later - it only costs you that download.'
    Write-Host ''
    $gameDrive = Split-Path -Qualifier $Game.InstallDir
    Write-Note 'Drives on this PC:'
    foreach ($d in (Get-FixedDrives)) {
        $tag = ''
        if ($d.Name.StartsWith($gameDrive, 'OrdinalIgnoreCase')) { $tag = '   <-- the game is on this drive (recommended)' }
        Write-Host ('     {0}  {1,9:N1} GB free of {2,9:N1} GB{3}' -f $d.Name, $d.FreeGB, $d.TotalGB, $tag)
    }
    Write-Host ''
    Write-Note 'Same drive as the game is recommended: the file swap is then a fast local'
    Write-Note 'copy, and each file lands atomically so an interruption cannot corrupt it.'
    Write-Host ''
    $default = (Join-Path $gameDrive '\SteamCMD')

    # Validate here, not later. A path without a drive letter is treated by Windows
    # as RELATIVE, so SteamCMD and up to 50 GB of game data land inside whatever
    # folder the pack was unzipped into - usually Downloads - and the run then dies
    # at step 11 of 11 when a free-space check cannot parse the drive. Defect 19.
    # Catching it at the prompt costs a retyped line; catching it later costs an
    # hour and a 50 GB download in the wrong place.
    $dir = $null
    while ($true) {
        $entered = Read-Host "   Install SteamCMD where? [$default]"
        if ([string]::IsNullOrWhiteSpace($entered)) { $dir = $default; break }
        $entered = $entered.Trim().Trim('"').Trim("'")
        if ([System.IO.Path]::IsPathRooted($entered)) { $dir = $entered; break }

        Write-Bad ("That is not a full path: {0}" -f $entered)
        $hint = Get-MissingColonHint -Path $entered
        if ($hint) {
            Write-Note ("Did you mean  {0}  ? A drive letter needs a colon after it." -f $hint)
        }
        Write-Note 'Give the full path including the drive letter and its colon.'
        Write-Note ("Or just press Enter to use  {0}" -f $default)
        Write-Host ''
    }

    $SteamCmdExe = Install-SteamCmd -TargetDir $dir
    Write-Good "SteamCMD installed: $SteamCmdExe"
}

# ===========================================  STEPS 6, 7, 8 and 9  ===========
Write-Head 'STEPS 6 to 9 of 11 - Signing SteamCMD in'

Write-Note "Checking whether SteamCMD is already signed in as '$($Owner.AccountName)'."
Write-Note 'This starts SteamCMD in the background and waits for it. It can sit here'
Write-Note 'for up to a minute with nothing happening on screen, especially the first'
Write-Note 'time. That is normal - do not press anything, it is not stuck.'
Write-Host '   working ... ' -NoNewline
$LoggedIn = Test-SteamCmdLogin -Exe $SteamCmdExe -AccountName $Owner.AccountName
Write-Host 'done'

if ($LoggedIn) {
    Write-Good 'Already signed in - no password needed.'
} else {
    Write-Host ''
    Write-Note 'SteamCMD needs to sign in once. After this it remembers, and every future'
    Write-Note 'run needs no password and no Steam Guard code.'
    Write-Host ''
    Write-Warn 'This script never sees, stores or asks for your password. A separate'
    Write-Warn 'SteamCMD window will open and you type it directly into that.'
    Write-Host ''
    Write-Note 'WHAT TO EXPECT IN THAT WINDOW:'
    Write-Note ''
    Write-Note '  1. It asks for your password. This is your NORMAL Steam password -'
    Write-Note '     there is no separate SteamCMD account.'
    Write-Note ''
    Write-Note '  2. *** NOTHING WILL APPEAR AS YOU TYPE IT. ***'
    Write-Note '     No dots, no stars, no moving cursor. The line stays blank.'
    Write-Note '     That is normal - it is deliberately not shown. Just type it and'
    Write-Note '     press Enter.'
    Write-Note ''
    Write-Note '  3. You CAN paste with Ctrl+V (or right-click). That is invisible too,'
    Write-Note '     so DO NOT paste twice thinking it did not work. Paste once, Enter.'
    Write-Note ''
    Write-Note '  4. Then Steam Guard, which comes one of two ways:'
    Write-Note '       - a prompt on your PHONE to approve. Nothing to type here -'
    Write-Note '         just approve it in the Steam mobile app.'
    Write-Note '       - or it asks for a 5-character code (email / authenticator).'
    Write-Note ''
    Write-Note '  5. Success looks like:   Logging in user ... to Steam Public...OK'
    Write-Note '     followed by a  Steam>  prompt.'
    Write-Note ''
    Write-Note '  6. Type  quit  and press Enter to close that window.'
    Write-Host ''
    Write-Warn 'AFTERWARDS, YOUR STEAM CLIENT MAY GO OFFLINE.'
    Write-Note 'Signing SteamCMD in can knock the Steam client off its connection. You'
    Write-Note 'may see "NO CONNECTION" in Steam, or a warning that it cannot sync your'
    Write-Note 'saves with Steam Cloud. Nothing is broken and no game files are harmed.'
    Write-Note ''
    Write-Note 'Fix: Steam menu > Exit for a FULL quit (not just closing the window),'
    Write-Note 'then start Steam again. Do that before you play anything, and do not'
    Write-Note 'click "Play anyway" on a cloud-sync warning - that can overwrite good'
    Write-Note 'cloud saves with whatever is on this PC.'
    Write-Host ''
    if (-not (Confirm-YesNo 'Open the SteamCMD sign-in window now? (y/n)')) {
        Stop-Pack 'Stopped at your request. Nothing was changed.'
    }

    $proc = Start-InteractiveLogin -Exe $SteamCmdExe -AccountName $Owner.AccountName
    Write-Host ''
    Write-Note 'Waiting for you to finish in the SteamCMD window ...'
    Write-Note "(type  quit  there once you see the  Steam>  prompt)"
    $proc.WaitForExit()
    Write-Host ''
    Write-Note 'Window closed. Checking the sign-in took ...'

    $LoggedIn = Test-SteamCmdLogin -Exe $SteamCmdExe -AccountName $Owner.AccountName
    if (-not $LoggedIn) {
        Write-Bad 'SteamCMD still is not signed in.'
        Write-Note 'The usual causes are a mistyped password, a Steam Guard prompt that'
        Write-Note 'timed out, or the window being closed before sign-in completed.'
        if (Confirm-YesNo 'Try again? (y/n)') {
            $proc = Start-InteractiveLogin -Exe $SteamCmdExe -AccountName $Owner.AccountName
            $proc.WaitForExit()
            $LoggedIn = Test-SteamCmdLogin -Exe $SteamCmdExe -AccountName $Owner.AccountName
        }
    }
    if (-not $LoggedIn) { Stop-Pack 'Could not sign SteamCMD in, so the download cannot run.' }
    Write-Good 'Signed in.'
}

# ====================================================  STEP 10  ==============
Write-Head 'STEP 10 of 11 - Choose the version to go back to'

Write-Note 'Your Steam logs record which builds THIS PC has installed, including'
Write-Note 'everything needed to download them again.'
Write-Host ''
Write-Warn 'Only builds this PC actually installed will be listed. If you reinstalled'
Write-Warn 'Steam recently, or skipped the version you want, it will not appear.'
Write-Host ''

$History = @()
if (Confirm-YesNo 'Read your Steam logs to list available versions? (y/n)') {
    $History = @(Get-BuildHistory -SteamRoot $SteamRoot -AppId $Game.AppId)
    Write-Good ("{0} build(s) found in your logs" -f @($History).Count)
}

# Merge log history with the curated table. Manifest IDs are global, so a
# shipped entry works even on a PC that never installed that build.
$Rows = New-Object System.Collections.ArrayList
$seenBuild = @{}
foreach ($h in $History) {
    $lbl = ''
    $note = ''
    if ($Known.ContainsKey($h.BuildId)) { $lbl = $Known[$h.BuildId].label; $note = $Known[$h.BuildId].notes }
    # Curated names win; Steam's fill the gaps.
    if (-not $lbl -and $SteamLabels.ContainsKey($h.BuildId)) { $lbl = $SteamLabels[$h.BuildId] }
    [void]$Rows.Add([pscustomobject]@{
        BuildId = $h.BuildId; Label = $lbl; Installed = $h.Installed.ToString('yyyy-MM-dd')
        LastPlayed = $(if ($h.LastPlayed) { $h.LastPlayed.ToString('yyyy-MM-dd') } else { 'never' })
        Sessions = $h.Sessions; Depots = $h.Depots; Source = 'your logs'; Notes = $note
    })
    $seenBuild[$h.BuildId] = $true
}
foreach ($k in $Known.Keys) {
    if ($seenBuild.ContainsKey($k)) { continue }
    $b = $Known[$k]
    $dep = [ordered]@{}
    foreach ($p in $b.depots.PSObject.Properties) { $dep[$p.Name] = $p.Value }
    [void]$Rows.Add([pscustomobject]@{
        BuildId = $b.buildid; Label = $b.label; Installed = $b.seen
        LastPlayed = '-'; Sessions = 0; Depots = $dep; Source = 'shipped list'; Notes = $b.notes
    })
}
function Get-ManualTarget {
    # Manual entry, for a version this PC never installed and the shipped list
    # does not cover. SteamDB is the only complete public source for this, and it
    # cannot be read by a script - it sits behind bot protection - so the user
    # looks it up in a browser and pastes the values in.
    param($AppId, $CurrentDepots)

    Write-Host ''
    Write-Note 'Manual entry. You will need a manifest ID for each part of the game.'
    Write-Host ''
    Write-Note 'Open these in your browser:'
    Write-Note ("   https://steamdb.info/app/{0}/patchnotes/" -f $AppId)
    Write-Note '      lists the builds and their dates, so you can find the one you want.'
    foreach ($d in $CurrentDepots.Keys) {
        Write-Note ("   https://steamdb.info/depot/{0}/manifests/" -f $d)
        Write-Note '      find that build in the list and copy its Manifest ID.'
    }
    Write-Host ''
    Write-Note 'Leave any depot blank to leave that part of the game untouched.'
    Write-Host ''

    $dep = [ordered]@{}
    foreach ($d in $CurrentDepots.Keys) {
        while ($true) {
            $v = Read-Host ("   Manifest ID for depot $d (blank to skip)")
            if ([string]::IsNullOrWhiteSpace($v)) { break }
            $v = $v.Trim()
            # Manifest IDs are 64-bit decimal numbers. Catching a bad paste here
            # is far kinder than a confusing SteamCMD error later.
            if ($v -match '^\d{6,25}$') { $dep[$d] = $v; break }
            Write-Warn 'That does not look like a manifest ID - it should be a long run of digits only.'
        }
    }
    if ($dep.Count -eq 0) { return $null }

    $bid = Read-Host '   Build ID, if you know it (optional, for your own reference)'
    if ([string]::IsNullOrWhiteSpace($bid)) { $bid = 'manual' }
    $lbl = Read-Host '   A name for this version, if you know it (optional)'

    return [pscustomobject]@{
        BuildId = $bid.Trim(); Label = $lbl.Trim(); Installed = (Get-Date).ToString('yyyy-MM-dd')
        LastPlayed = '-'; Sessions = 0; Depots = $dep; Source = 'entered by hand'; Notes = ''
    }
}

if (@($Rows).Count -eq 0) {
    Write-Bad 'No previous builds are known for this game, from your logs or the shipped list.'
    Write-Host ''
    Write-Note 'You can still do this by hand if you can find the version on SteamDB.'
    if (-not (Confirm-YesNo 'Enter the details manually? (y/n)')) {
        Stop-Pack 'Nothing to offer automatically.'
    }
    $manual = Get-ManualTarget -AppId $Game.AppId -CurrentDepots $CurrentDepots
    if (-not $manual) { Stop-Pack 'Nothing entered.' }
    [void]$Rows.Add($manual)
}

$Rows = @($Rows | Sort-Object { [datetime]::Parse($_.Installed) } -Descending)

if ($Actual.Certain -and $Actual.BuildId -ne $Game.BuildId) {
    $actualRow = $Rows | Where-Object { $_.BuildId -eq $CurrentBuildId } | Select-Object -First 1
    if ($actualRow -and $actualRow.Depots -and $actualRow.Depots.Count -gt 0) {
        $CurrentDepots = $actualRow.Depots
    }
}

Write-Host ''
Write-Host ('   {0,3}  {1,-11} {2,-9} {3,-11} {4,-11} {5,8}  {6}' -f '#', 'Build', 'Version', 'Installed', 'LastPlayed', 'Sessions', 'Source')
Write-Host ('   ' + ('-' * 88))
for ($i = 0; $i -lt @($Rows).Count; $i++) {
    $r = $Rows[$i]
    $mark = ' '
    if ($r.BuildId -eq $CurrentBuildId) { $mark = '*' }
    $colour = 'Gray'
    if ($r.BuildId -eq $CurrentBuildId) { $colour = 'DarkGray' }
    elseif ($r.Sessions -gt 0) { $colour = 'White' }
    $lbl = $r.Label
    if (-not $lbl) { $lbl = '?' }
    Write-Host ('   {0,3}{1} {2,-11} {3,-9} {4,-11} {5,-11} {6,8}  {7}' -f ($i+1), $mark, $r.BuildId, $lbl, $r.Installed, $r.LastPlayed, $r.Sessions, $r.Source) -ForegroundColor $colour
}
Write-Host ''
if ($Actual.Certain) {
    Write-Note "* = the build you have installed right now ($($Actual.Source))"
} else {
    Write-Note '* = the build Steam thinks you have installed. If you have already'
    Write-Note '    downgraded this game by hand, Steam will still name the newer one.'
}
Write-Note 'Sessions = how many times you played that build. The one you played a lot,'
Write-Note 'just before the current one, is almost always the one you want.'
if (@($SteamLabels.Keys).Count -gt 0) {
    Write-Note ("Version names come from this tool's own list plus {0} published by Steam." -f @($SteamLabels.Keys).Count)
}
Write-Note 'A "?" just means nobody attached a version name to that build. It is still'
Write-Note 'perfectly usable - pick by date and play count instead.'

# Recommend: most recently played build before the current one, with evidence.
$Recommend = $null
foreach ($r in $Rows) {
    if ($r.BuildId -eq $CurrentBuildId) { continue }
    if ($r.Sessions -gt 0) { $Recommend = $r; break }
}
if (-not $Recommend) { foreach ($r in $Rows) { if ($r.BuildId -ne $CurrentBuildId) { $Recommend = $r; break } } }

$defaultIdx = ''
if ($Recommend) {
    for ($i = 0; $i -lt @($Rows).Count; $i++) { if ($Rows[$i].BuildId -eq $Recommend.BuildId) { $defaultIdx = ($i + 1).ToString() } }
    Write-Host ''
    Write-Good ("Suggested: #{0}  build {1}{2}" -f $defaultIdx, $Recommend.BuildId, $(if ($Recommend.Label) { " (version $($Recommend.Label))" } else { '' }))
    if ($Recommend.Sessions -gt 0) {
        Write-Note ("You installed it on {0} and played it {1} time(s), last on {2}." -f $Recommend.Installed, $Recommend.Sessions, $Recommend.LastPlayed)
    }
    if ($Recommend.Notes) { Write-Note $Recommend.Notes }
}

Write-Host ''
Write-Note "If the version you want is not listed, enter 'm' to type its details in by"
Write-Note 'hand from SteamDB.'

$Target = $null
while (-not $Target) {
    $sel = Read-Host ("   Which version? Enter a number$(if ($defaultIdx) { " [$defaultIdx]" }), m for manual, or q to quit")
    if ($sel -eq 'q') { Stop-Pack 'Stopped at your request. Nothing was changed.' }
    if ($sel -eq 'm') {
        $manual = Get-ManualTarget -AppId $Game.AppId -CurrentDepots $CurrentDepots
        if ($manual) { $Target = $manual }
        continue
    }
    if ([string]::IsNullOrWhiteSpace($sel) -and $defaultIdx) { $sel = $defaultIdx }
    $n = 0
    if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le @($Rows).Count) {
        if ($Rows[$n-1].BuildId -eq $CurrentBuildId) { Write-Warn 'That is the build you already have. Pick a different one.' }
        else { $Target = $Rows[$n - 1] }
    } else { Write-Warn "Not a valid number from the list (or 'm' for manual, 'q' to quit)." }
}
Write-Good "Target: build $($Target.BuildId)"

# ====================================================  STEP 11  ==============
Write-Head 'STEP 11 of 11 - Download, swap, verify'

# Only depots whose manifest actually differs need downloading. On Elden Ring
# 1.17 this skipped a 16 GB DLC depot that had not changed at all.
$Needed = New-Object System.Collections.ArrayList
foreach ($d in $Target.Depots.Keys) {
    $want = $Target.Depots[$d]
    $have = ''
    if ($CurrentDepots.Contains($d)) { $have = $CurrentDepots[$d] }
    if ($want -ne $have) {
        [void]$Needed.Add([pscustomobject]@{ DepotId = $d; Manifest = $want; Have = $have })
    }
}
if (@($Needed).Count -eq 0) { Stop-Pack 'Nothing to do - every depot already matches that build.' }

Write-Note 'Asking Steam how big each part of the game is. This runs SteamCMD again'
Write-Note 'and can sit silently for a minute or two. It is not stuck.'
Write-Host '   working ... ' -NoNewline
$Sizes = Get-DepotSizes -Exe $SteamCmdExe -AccountName $Owner.AccountName -AppId $Game.AppId
Write-Host 'done'

# Reuse anything already downloaded. Re-running download_depot over correct
# content costs no bandwidth, but SteamCMD still validates every file, which
# took ~10 minutes on a 50 GB depot. Skipping that when we already know what is
# there is worth doing - and it covers the case of someone who downloaded the
# right files previously and did not know what to do next.
Write-Note 'Checking what is already downloaded ...'
foreach ($n in $Needed) {
    $dir = Get-DepotDownloadPath -Exe $SteamCmdExe -AppId $Game.AppId -DepotId $n.DepotId
    $st  = Test-DepotAlreadyDownloaded -DepotDir $dir -ManifestId $n.Manifest
    Add-Member -InputObject $n -NotePropertyName 'Reuse'    -NotePropertyValue $st.Status
    Add-Member -InputObject $n -NotePropertyName 'HaveBytes' -NotePropertyValue $st.Bytes
    Add-Member -InputObject $n -NotePropertyName 'Dir'      -NotePropertyValue $dir
}

$Ready    = @($Needed | Where-Object { $_.Reuse -eq 'match' })
$ToGet    = @($Needed | Where-Object { $_.Reuse -ne 'match' })

if (@($Ready).Count -gt 0) {
    Write-Good ("{0} depot(s) already downloaded and identified - skipping:" -f @($Ready).Count)
    foreach ($n in $Ready) { Write-Note ("   depot {0}   {1} already on disk" -f $n.DepotId, (Format-Bytes $n.HaveBytes)) }
}
foreach ($n in ($ToGet | Where-Object { $_.Reuse -eq 'unknown' })) {
    Write-Warn ("Depot {0} already has {1} of files, but I cannot tell which version." -f $n.DepotId, (Format-Bytes $n.HaveBytes))
    Write-Note '   SteamCMD will check them and re-use whatever already matches, so this'
    Write-Note '   costs no extra download - only the time taken to verify them.'
}
foreach ($n in ($ToGet | Where-Object { $_.Reuse -eq 'other' })) {
    Write-Note ("Depot {0} currently holds a different version; only the differences will download." -f $n.DepotId)
}

$TotalEst = [long]0
if (@($ToGet).Count -gt 0) {
    Write-Host ''
    Write-Note 'Depots to fetch:'
    foreach ($n in $ToGet) {
        $est = 0
        if ($Sizes.ContainsKey($n.DepotId)) { $est = $Sizes[$n.DepotId] }
        $TotalEst += $est
        Write-Note ("   depot {0}  ->  manifest {1}   (up to about {2})" -f $n.DepotId, $n.Manifest, (Format-Bytes $est))
    }
}
$skipped = @($Target.Depots.Keys).Count - @($Needed).Count
if ($skipped -eq 1) { Write-Good '1 part of the game is identical between the two versions and will not be touched.' }
elseif ($skipped -gt 1) { Write-Good "$skipped parts of the game are identical between the two versions and will not be touched." }

Write-Host ''
if (@($ToGet).Count -eq 0) {
    Write-Good 'Nothing needs downloading - everything for that version is already on this PC.'
} else {
    Write-Note ("Estimated download: up to about {0}. Sizes are approximate - an older" -f (Format-Bytes $TotalEst))
    Write-Note "build's exact size is not published by Steam, and anything already on"
    Write-Note 'disk is re-used rather than fetched again.'
}

if (@($ToGet).Count -gt 0) {
    # A free-space check is a courtesy, not a gate. It must never be the thing that
    # ends a run - which is exactly what it did in defect 19, at step 11 of 11,
    # after the download had already happened.
    $cmdDrive = Get-PathQualifier -Path $SteamCmdExe
    if ($cmdDrive) {
        $free = (Get-FixedDrives | Where-Object { $_.Name.StartsWith($cmdDrive, 'OrdinalIgnoreCase') }).FreeBytes
        if ($free -and $free -lt ($TotalEst * 1.15)) {
            Write-Bad ("Not enough free space on {0}: {1} free, about {2} needed." -f $cmdDrive, (Format-Bytes $free), (Format-Bytes ($TotalEst * 1.15)))
            Stop-Pack 'Free up space, or reinstall SteamCMD to a roomier drive, then re-run.'
        }
        if ($free) { Write-Good ("Free space on {0}: {1}" -f $cmdDrive, (Format-Bytes $free)) }
    } else {
        Write-Note ("Could not tell which drive SteamCMD is on ({0}), so the free-space" -f $SteamCmdExe)
        Write-Note 'check was skipped. The download will still work; just make sure that'
        Write-Note 'location has room.'
    }
}

Write-Host ''
$goPrompt = 'Start the download? (y/n)'
if (@($ToGet).Count -eq 0) { $goPrompt = 'Continue? (y/n)' }
if (-not (Confirm-YesNo $goPrompt)) { Stop-Pack 'Stopped at your request. Nothing was changed.' }

# --- saves are the user's responsibility, deliberately ---
# This tool does NOT touch save files. Every game stores them somewhere
# different - the user profile, Documents, the install folder, Steam Cloud - and
# there is no general rule. A tool that guesses gets it wrong, and getting it
# wrong with somebody's saves is not an acceptable failure mode.
$appCfg = $null
try { $appCfg = (Get-Content -LiteralPath (Join-Path $PackRoot 'data\known-builds.json') -Raw | ConvertFrom-Json).apps | Where-Object { $_.appid -eq $Game.AppId } } catch { }

Write-Step 'Save files - worth a thought before we continue'
Write-Note 'This tool does not touch save files, and deliberately does not try to'
Write-Note 'back them up. Every game handles saves differently and there is no'
Write-Note 'reliable way for a script to find them.'
Write-Host ''
Write-Note 'Not every game even needs this. Plenty keep saves on a server or in'
Write-Note 'Steam Cloud, where a version change makes no difference at all.'
Write-Host ''
Write-Note 'But if this game keeps saves on your PC, look up where it puts them'
Write-Note 'and copy them somewhere safe first. A quick search for the game name'
Write-Note 'plus "save file location" will normally tell you.'
Write-Host ''
Write-Note 'Changing version does not usually harm saves, but an older build may'
Write-Note 'refuse to read one written by a newer build.'
Write-Host ''
if (-not (Confirm-YesNo 'Happy to continue? (y/n)' 'n')) {
    Stop-Pack 'Stopped at your request. Nothing has been changed.'
}

# Every depot of the target build feeds the file comparison later, including
# ones we already had on disk.
$DepotDirs = New-Object System.Collections.ArrayList
foreach ($n in $Ready) { [void]$DepotDirs.Add($n.Dir) }

# Smallest first. A manifest being listed does NOT guarantee Valve still serves
# it, so proving it is live on the smallest depot costs seconds - whereas finding
# out after a 50 GB download does not.
$ordered = @($ToGet | Sort-Object { if ($Sizes.ContainsKey($_.DepotId)) { $Sizes[$_.DepotId] } else { [long]::MaxValue } })
if (@($ToGet).Count -gt 1 -and @($Sizes.Keys).Count -eq 0) {
    Write-Warn 'Steam did not report part sizes, so these are fetched in arbitrary order.'
    Write-Note 'An unavailable version may therefore not be spotted until later.'
}

$first = $true
foreach ($n in $ordered) {
    $est = 0
    if ($Sizes.ContainsKey($n.DepotId)) { $est = $Sizes[$n.DepotId] }

    if ($first) {
        Write-Step 'Checking that version is still available from Valve'
        if (@($ordered).Count -gt 1) {
            Write-Note ("Starting with the smallest part ({0}), so a version Valve no longer" -f $n.DepotId)
            Write-Note 'serves is found in seconds rather than after a long download.'
        } else {
            Write-Note ("Only one part to fetch ({0}), so availability and download happen" -f $n.DepotId)
            Write-Note 'together.'
        }
    } else {
        Write-Step ("Downloading depot {0}  (up to about {1})" -f $n.DepotId, (Format-Bytes $est))
        Write-Note 'This can take a while. You can leave it running.'
    }

    $rr = Invoke-DepotDownload -Exe $SteamCmdExe -AccountName $Owner.AccountName -AppId $Game.AppId -DepotId $n.DepotId -ManifestId $n.Manifest -EstimatedBytes $est
    if (-not $rr.Ok) {
        Write-Bad ("Depot {0} could not be downloaded." -f $n.DepotId)
        if ($rr.Reason) { Write-Note $rr.Reason }
        if ($first) {
            Write-Note 'Valve does remove very old builds from their servers. Try a different'
            Write-Note 'version from the list.'
        }
        Stop-Pack 'Download failed. The game has NOT been changed.'
    }
    if ($first) { Write-Good 'That version is available. Continuing.' }
    Write-Good ("Depot {0} ready - {1}" -f $n.DepotId, (Format-Bytes $rr.Bytes))
    [void]$DepotDirs.Add($rr.Path)
    $first = $false
}

# --- dry run ---
Write-Step 'Working out exactly which files would change'
Write-Note 'Comparing every downloaded file against your install (this reads a lot of'
Write-Note 'data, so give it a minute) ...'
$Plan = @(Get-SwapPlan -GameDir $Game.InstallDir -DepotDirs @($DepotDirs))
if (@($Plan).Count -eq 0) {
    Write-Good 'Nothing to change - your install already matches that build.'
    Read-Host '   Press Enter to close'
    exit 0
}
$planBytes = ($Plan | Measure-Object -Property Size -Sum).Sum
Write-Host ''
Write-Note ("{0} file(s) would be replaced, {1} in total:" -f @($Plan).Count, (Format-Bytes $planBytes))
foreach ($a in $Plan) { Write-Host ('     {0,-48} {1,10}   ({2})' -f $a.Rel, (Format-Bytes $a.Size), $a.Why) }
Write-Host ''
Write-Note 'Only these files change. Nothing is deleted, so any mod folders sitting'
Write-Note 'alongside the game files are left exactly as they are.'
Write-Host ''
if (-not (Confirm-YesNo 'Apply these changes? (y/n)')) { Stop-Pack 'Stopped at your request. The game has NOT been changed.' }

if (Test-GameRunning -InstallDir $Game.InstallDir) { Stop-Pack 'The game started running. Close it and re-run this tool.' }

# --- apply ---
Write-Step 'Replacing files'
Invoke-Swap -Actions $Plan
Write-Good 'Files replaced.'

# Record what is now genuinely on disk. Steam's appmanifest is deliberately left
# naming the newer build, so without this a later run would report the wrong
# version - and would refuse to re-apply this one, believing it already present.
Set-InstalledMarker -GameDir $Game.InstallDir -BuildId $Target.BuildId -Label $Target.Label

# --- verify ---
Write-Step 'Verifying'
$after = @(Get-SwapPlan -GameDir $Game.InstallDir -DepotDirs @($DepotDirs))
if (@($after).Count -eq 0) {
    Write-Good 'Verified: every file now matches the version you chose.'
} else {
    Write-Bad ("{0} file(s) still do not match. Something went wrong." -f @($after).Count)
    foreach ($a in $after) { Write-Note ("   {0}  ({1})" -f $a.Rel, $a.Why) }
}
foreach ($e in (Get-ExeVersions -GameDir $Game.InstallDir)) {
    Write-Note ("   {0}  version {1}" -f $e.Name, $e.Version)
}

# --- closing notes ---
Write-Head 'Done'
Write-Good "$($Game.Name) is now on build $($Target.BuildId)$(if ($Target.Label) { " (version $($Target.Label))" })"
Write-Host ''
Write-Warn 'RESTART STEAM NOW.'
Write-Note '  Signing SteamCMD in can knock the Steam client offline. If Steam shows'
Write-Note '  "NO CONNECTION", or warns it cannot sync your saves with Steam Cloud,'
Write-Note '  that is why - it is not damage to your game.'
Write-Note '  Fix: Steam menu > Exit (a full quit, not just closing the window), then'
Write-Note '  start Steam again. Do that before playing anything.'
Write-Host ''
Write-Warn 'THEN KEEP THIS IN MIND, or you will end up back where you started:'
Write-Host ''
if ($appCfg -and $appCfg.launchNotes) {
    Write-Note '  1. Launch the game from its mod loader, not Steam''s Play button:'
    foreach ($l in $appCfg.launchNotes) { Write-Note "     $l" }
} else {
    Write-Note '  1. Launching from Steam is fine right now, but once a NEWER patch'
    Write-Note '     exists, pressing Play in Steam is what triggers the update that'
    Write-Note '     undoes this. To be safe, launch the game''s .exe directly from:'
    Write-Note ("     {0}" -f $Game.InstallDir)
}
Write-Note ''
Write-Note '  2. NEVER use "Verify integrity of game files" unless you WANT the'
Write-Note '     newest version back. It checks your files against the current patch'
Write-Note '     and re-downloads anything that does not match - which is every file'
Write-Note '     this tool just changed.'
Write-Note ''
Write-Note '     That also makes it the RIGHT way to undo this deliberately. To go'
Write-Note '     back to the current version: right-click the game in Steam >'
Write-Note '     Properties > Installed Files > Verify integrity of game files.'
Write-Note ''
Write-Note '  3. When the game gets patched again, Steam will want to update. Because'
Write-Note '     the downloaded files were kept, running this tool again will be quick'
Write-Note '     - no big download the second time.'
Write-Host ''
Write-Note ("Downloaded files kept at: {0}" -f (Split-Path -Parent (Split-Path -Parent $DepotDirs[0])))
Write-Note 'Delete that folder only if you need the disk space back.'
Write-Host ''
Read-Host '   Press Enter to close'
