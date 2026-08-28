# Discovery of the local Steam install: root, libraries, installed games,
# per-game metadata, and which account owns a given game.
# Nothing here is machine-specific: every path is discovered at runtime.

function Get-SteamRoot {
    foreach ($p in @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )) {
        try {
            $k = Get-ItemProperty -Path $p -ErrorAction Stop
            foreach ($prop in @('SteamPath', 'InstallPath')) {
                $v = $k.$prop
                if ($v -and (Test-Path -LiteralPath $v)) { return (Resolve-Path -LiteralPath $v).Path }
            }
        } catch { }
    }
    foreach ($p in @("${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam", 'C:\Steam')) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Get-SteamLibraries {
    param([Parameter(Mandatory = $true)][string]$SteamRoot)
    $out = New-Object System.Collections.ArrayList
    $vdf = Get-VdfFile (Join-Path $SteamRoot 'steamapps\libraryfolders.vdf')
    if ($null -eq $vdf) { return $out }

    $root = $null
    if ($vdf.Contains('libraryfolders')) { $root = $vdf.libraryfolders } else { $root = $vdf }

    foreach ($k in $root.Keys) {
        $entry = $root.$k
        if ($entry -isnot [System.Collections.Specialized.OrderedDictionary]) { continue }
        if (-not $entry.Contains('path')) { continue }
        $path = $entry.path
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Warning "Steam library listed but not reachable (drive disconnected?): $path"
            continue
        }
        [void]$out.Add([pscustomobject]@{
            Path      = $path
            SteamApps = (Join-Path $path 'steamapps')
        })
    }
    return $out
}

function Get-SteamGames {
    param([Parameter(Mandatory = $true)]$Libraries)
    $out = New-Object System.Collections.ArrayList
    foreach ($lib in $Libraries) {
        if (-not (Test-Path -LiteralPath $lib.SteamApps)) { continue }
        Get-ChildItem -LiteralPath $lib.SteamApps -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $m = Get-VdfFile $_.FullName
                if ($null -eq $m -or -not $m.Contains('AppState')) { return }
                $s = $m.AppState
                $dir = Join-Path $lib.SteamApps ('common\' + $s.installdir)
                [void]$out.Add([pscustomobject]@{
                    AppId        = $s.appid
                    Name         = $s.name
                    InstallDir   = $dir
                    Installed    = (Test-Path -LiteralPath $dir)
                    BuildId      = $s.buildid
                    LastOwner    = $s.LastOwner
                    AutoUpdate   = $s.AutoUpdateBehavior
                    SizeOnDisk   = $s.SizeOnDisk
                    ManifestPath = $_.FullName
                    Library      = $lib.Path
                    Depots       = $s.InstalledDepots
                })
            }
    }
    return ($out | Sort-Object Name)
}

function Get-SteamAccounts {
    param([Parameter(Mandatory = $true)][string]$SteamRoot)
    $out = New-Object System.Collections.ArrayList
    $vdf = Get-VdfFile (Join-Path $SteamRoot 'config\loginusers.vdf')
    if ($null -eq $vdf -or -not $vdf.Contains('users')) { return $out }
    foreach ($sid in $vdf.users.Keys) {
        $u = $vdf.users.$sid
        [void]$out.Add([pscustomobject]@{
            SteamId64   = $sid
            AccountName = $u.AccountName
            PersonaName = $u.PersonaName
        })
    }
    return $out
}

function Resolve-OwnerAccount {
    # The account that owns the game is recorded as LastOwner in its appmanifest.
    # Matching that against loginusers.vdf avoids guessing on multi-account machines.
    param([Parameter(Mandatory = $true)]$Game, [Parameter(Mandatory = $true)]$Accounts)
    if ($Game.LastOwner) {
        $hit = $Accounts | Where-Object { $_.SteamId64 -eq $Game.LastOwner }
        if ($hit) { return $hit }
    }
    if ($Accounts.Count -eq 1) { return $Accounts[0] }
    return $null
}

function Test-SteamRunning {
    $p = Get-Process -Name 'steam' -ErrorAction SilentlyContinue
    return ($null -ne $p)
}

function Test-GameRunning {
    param([Parameter(Mandatory = $true)][string]$InstallDir)
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($InstallDir, 'OrdinalIgnoreCase') }
    return ($null -ne $procs -and @($procs).Count -gt 0)
}
