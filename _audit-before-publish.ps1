# Gate to run before making this repository public.
#
# Scans every file Git would actually publish for anything personal or
# machine-specific. Exits non-zero if it finds something, so it can be trusted
# as a gate rather than read as advice.
#
# Not part of the shipped pack (gitignored).

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Push-Location $root

$tracked = @(git ls-files) | Where-Object { $_ }
if (-not $tracked) {
    Write-Host 'No tracked files yet - run git add first.' -ForegroundColor Yellow
    Pop-Location
    exit 2
}

Write-Host ''
Write-Host "Auditing $($tracked.Count) tracked file(s) before publication" -ForegroundColor Cyan
Write-Host ('-' * 74)

# Patterns that must never appear in a public repo. Deliberately broad - a false
# positive costs a glance, a false negative publishes someone's details.
$patterns = @(
    @{ Name = 'Windows user profile path'; Rx = '(?i)[A-Z]:\\Users\\[A-Za-z0-9._-]+' },
    @{ Name = 'SteamID64';                 Rx = '7656119[0-9]{10}' },
    @{ Name = 'Steam account name field';  Rx = '(?i)AccountName\s*["'':=]' },
    @{ Name = 'Password-ish assignment';   Rx = '(?i)(password|passwd|pwd)\s*[:=]\s*\S' },
    @{ Name = 'API key / token';           Rx = '(?i)(api[_-]?key|secret|bearer|token)\s*[:=]\s*[A-Za-z0-9_\-]{12,}' },
    @{ Name = 'Absolute Steam library';    Rx = '(?i)[A-Z]:\\SteamLibrary' },
    @{ Name = 'Absolute SteamCMD path';    Rx = '(?i)[A-Z]:\\SteamCMD' },
    @{ Name = 'Cloud-sync folder path';    Rx = '(?i)[A-Z]:\\(Cloud|Sync|Dropbox|OneDrive|Google ?Drive|iCloud)' },
    @{ Name = 'Any absolute drive path';   Rx = '(?i)\b[A-Z]:\\[A-Za-z0-9 _.\-]{2,}\\' },
    @{ Name = 'Private IP address';        Rx = '\b(?:10|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b' },
    @{ Name = 'Email address';             Rx = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' }
)

# Things that legitimately look like a hit. Each needs a reason - do NOT add to
# this list to silence a finding you have not actually understood.
$allow = @(
    'steamdb\.info',                # documentation link
    'media\.steampowered\.com',     # Valve's SteamCMD download URL
    'C:\\Users\\<',                 # placeholder in documentation
    'C:\\Users\\YourName',          # placeholder in documentation
    '76561197960265728',            # Steam's universal SteamID64 base constant,
                                    # used to derive the 32-bit account id. A
                                    # fixed part of Steam's ID scheme, not a person.
    'AccountName\s*=\s*\$',         # assigning FROM a variable - a field name in
                                    # code, not somebody's account name
    '\$\w*(Account|Owner)\w*\.AccountName'  # property access, same reason
)

$findings = New-Object System.Collections.ArrayList
$selfName = [System.IO.Path]::GetFileName($PSCommandPath)
foreach ($f in $tracked) {
    if (-not (Test-Path -LiteralPath $f)) { continue }
    # This script necessarily contains every pattern it searches for, so scanning
    # itself only ever produces self-referential false positives.
    if ([System.IO.Path]::GetFileName($f) -eq $selfName) { continue }
    $ext = [System.IO.Path]::GetExtension($f).ToLower()
    if ($ext -in @('.png', '.jpg', '.gif', '.zip', '.exe', '.dll', '.bin')) { continue }
    $i = 0
    foreach ($line in (Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)) {
        $i++
        foreach ($p in $patterns) {
            if ($line -match $p.Rx) {
                $skip = $false
                foreach ($a in $allow) { if ($line -match $a) { $skip = $true } }
                if ($skip) { continue }
                [void]$findings.Add([pscustomobject]@{ File = $f; Line = $i; Kind = $p.Name; Text = $line.Trim() })
            }
        }
    }
}

# The runtime backup folder must never be tracked, whatever .gitignore says.
foreach ($f in $tracked) {
    if ($f -like 'backups/*' -or $f -like 'backups\*') {
        [void]$findings.Add([pscustomobject]@{ File = $f; Line = 0; Kind = 'SAVE BACKUP TRACKED'; Text = 'save data must never be committed' })
    }
}

if (@($findings).Count -eq 0) {
    Write-Host ''
    Write-Host '  PASS - nothing personal or machine-specific found.' -ForegroundColor Green
    Write-Host '  Safe to make this repository public.' -ForegroundColor Green
    Write-Host ''
    Pop-Location
    exit 0
}

Write-Host ''
Write-Host ("  FAIL - {0} thing(s) need looking at before publishing:" -f @($findings).Count) -ForegroundColor Red
Write-Host ''
foreach ($x in $findings) {
    Write-Host ("  {0}:{1}" -f $x.File, $x.Line) -ForegroundColor Yellow
    Write-Host ("    {0}" -f $x.Kind) -ForegroundColor Magenta
    Write-Host ("    {0}" -f $x.Text) -ForegroundColor Gray
    Write-Host ''
}
Pop-Location
exit 1
