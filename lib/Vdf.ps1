# Minimal parser for Valve's KeyValues (VDF) text format.
# Steam stores libraryfolders.vdf, appmanifest_*.acf and loginusers.vdf in it.
# Windows PowerShell 5.1 compatible. No external dependencies.

function ConvertFrom-Vdf {
    param([Parameter(Mandatory = $true)][string]$Text)

    $tokens = New-Object System.Collections.ArrayList
    $i = 0
    $len = $Text.Length
    while ($i -lt $len) {
        $c = $Text[$i]
        if ($c -eq '"') {
            $sb = New-Object System.Text.StringBuilder
            $i++
            while ($i -lt $len -and $Text[$i] -ne '"') {
                if ($Text[$i] -eq '\' -and ($i + 1) -lt $len) {
                    $i++
                    $e = $Text[$i]
                    if     ($e -eq 'n') { [void]$sb.Append("`n") }
                    elseif ($e -eq 't') { [void]$sb.Append("`t") }
                    else                { [void]$sb.Append($e)   }
                } else {
                    [void]$sb.Append($Text[$i])
                }
                $i++
            }
            $i++
            [void]$tokens.Add(@{ T = 'S'; V = $sb.ToString() })
        }
        elseif ($c -eq '{' -or $c -eq '}') {
            [void]$tokens.Add(@{ T = $c; V = $c })
            $i++
        }
        elseif ($c -eq '/' -and ($i + 1) -lt $len -and $Text[$i + 1] -eq '/') {
            while ($i -lt $len -and $Text[$i] -ne "`n") { $i++ }
        }
        else {
            $i++
        }
    }

    $script:VdfPos = 0
    function Read-Block($tok) {
        $node = [ordered]@{}
        while ($script:VdfPos -lt $tok.Count) {
            $t = $tok[$script:VdfPos]
            if ($t.T -eq '}') { $script:VdfPos++; return $node }
            if ($t.T -ne 'S') { $script:VdfPos++; continue }
            $key = $t.V
            $script:VdfPos++
            if ($script:VdfPos -ge $tok.Count) { break }
            $nxt = $tok[$script:VdfPos]
            if ($nxt.T -eq '{') {
                $script:VdfPos++
                $node[$key] = Read-Block $tok
            } elseif ($nxt.T -eq 'S') {
                $script:VdfPos++
                $node[$key] = $nxt.V
            } else {
                $script:VdfPos++
            }
        }
        return $node
    }

    return (Read-Block $tokens)
}

function Get-VdfFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    # Steam writes these as UTF-8. PowerShell 5.1's Get-Content defaults to the
    # system codepage, which turns non-ASCII characters in game names into
    # mojibake ("DARK SOULS(tm) III" and friends).
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return (ConvertFrom-Vdf -Text $raw)
}
