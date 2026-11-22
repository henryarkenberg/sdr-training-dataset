#requires -Version 5.1
<#
    Open Weather Archive - audio downloader
    ---------------------------------------
    Interactive console menu (arrow keys) for picking which WAV files from an
    archive.csv to download.

    Usage:
        - Double click  Download-OpenWeather-Audio.bat
        - or drag archive.csv onto that .bat
        - or:  powershell -ExecutionPolicy Bypass -File OpenWeather-Audio-Downloader.ps1 [path\to\archive.csv]

    Nothing is downloaded by merely opening the file. You filter the archive,
    then "Browse & download" shows the matching files 20 per page; highlight one
    and press Enter to fetch only that file, or press a / p to fetch all / page.

    Transfers run through a small compiled engine that reports live byte counts,
    so you get an animated block bar with percent, size, speed and ETA (plus one
    mini bar per parallel transfer). Press Esc during a transfer to stop it.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$CsvPath = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$script:CsvPath   = $CsvPath
$script:All       = @()
$script:Selection = @()
$script:AppCredit = 'Made in Pakistan - https://github.com/henryarkenberg/sdr-training-dataset'
$script:Settings  = @{
    Parallel     = 12
    OutDir       = ''
    SkipExisting = $true
    IdPrefix     = $false
    OpenWhenDone = $true
}

# ----------------------------------------------------------------------------
# small helpers
# ----------------------------------------------------------------------------

function Clear-Screen {
    try { [Console]::Clear() } catch { Write-Host '' }
}

function Write-At {
    param(
        [int]$Row,
        [string]$Text = '',
        [string]$Foreground = $null,
        [string]$Background = $null
    )
    if ($Row -lt 0) { return }
    $max = 0
    try { $max = [Console]::WindowWidth - 1 } catch { $max = 0 }
    if ($max -gt 0 -and $Text.Length -gt $max) { $Text = $Text.Substring(0, $max) }

    $positioned = $true
    try { [Console]::SetCursorPosition(0, $Row) } catch { $positioned = $false }
    if (-not $positioned) {
        # not a real console (redirected output): just print sequentially
        if ($Foreground) { Write-Host $Text -ForegroundColor $Foreground } else { Write-Host $Text }
        return
    }

    try {
        if ($Foreground -and $Background) {
            Write-Host $Text -ForegroundColor $Foreground -BackgroundColor $Background -NoNewline
        } elseif ($Foreground) {
            Write-Host $Text -ForegroundColor $Foreground -NoNewline
        } else {
            Write-Host $Text -NoNewline
        }
    } catch { }
}

function Get-Key {
    try { return [Console]::ReadKey($true) } catch { return $null }
}

function Show-Message {
    param([string]$Text = '', [string]$Color = 'Yellow')
    Write-Host ''
    Write-Host ('  ' + $Text) -ForegroundColor $Color
    try { [void](Read-Host '  Press Enter to continue') } catch { }
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB)     { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB)     { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB)     { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function ConvertTo-SafeName {
    param([string]$Name)
    $n = $Name
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) {
        $n = $n.Replace([string]$c, '_')
    }
    $n = $n.Trim()
    if ([string]::IsNullOrWhiteSpace($n)) { $n = 'audio.wav' }
    if ($n.Length -gt 120) { $n = $n.Substring($n.Length - 120) }
    return $n
}

function Get-Field {
    param($Row, [string[]]$Names)
    foreach ($n in $Names) {
        $p = $Row.PSObject.Properties[$n]
        if ($p -and $null -ne $p.Value) { return ([string]$p.Value).Trim() }
    }
    return ''
}

# ----------------------------------------------------------------------------
# menu engine (arrow keys)
# ----------------------------------------------------------------------------

$script:DefaultMenuFooter = '  Up/Down move   PgUp/PgDn page   Home/End   Enter select   Esc back'

function New-MenuFrame {
    param(
        [string]$Title,
        [string]$Subtitle,
        [string[]]$Items,
        [int]$Top,
        [int]$Selected,
        [int]$RowCount,
        [int]$Height,
        [int]$Width,
        [string]$Footer = ''
    )

    if ($Height -lt 8) { $Height = 8 }
    if (-not $Footer) { $Footer = $script:DefaultMenuFooter }

    $footerLines = @($Footer -split "`n")
    $subLines = @()
    if ($Subtitle) { $subLines = @($Subtitle -split "`n") }

    $rows = New-Object System.Collections.ArrayList
    for ($k = 0; $k -lt $Height; $k++) {
        [void]$rows.Add([pscustomobject]@{ Text = ''; Fg = $null; Bg = $null })
    }
    $set = {
        param([int]$r, [string]$t, $fg, $bg)
        if ($r -ge 0 -and $r -lt $rows.Count) {
            $rows[$r].Text = $t
            $rows[$r].Fg = $fg
            $rows[$r].Bg = $bg
        }
    }

    & $set 0 $Title 'Cyan' $null
    $row = 1
    & $set $row ('  ' + $script:AppCredit) 'Green' $null
    $row++
    foreach ($subLine in $subLines) {
        & $set $row $subLine 'DarkGray' $null
        $row++
    }
    $row++

    $last = [Math]::Min($Items.Count, $Top + $RowCount)
    for ($i = $Top; $i -lt $last; $i++) {
        $label = [string]$Items[$i]
        $line = '  ' + $label
        if ($line.Length -gt ($Width - 1)) { $line = $line.Substring(0, [Math]::Max(1, $Width - 4)) + '...' }
        if ($i -eq $Selected) {
            $line = '> ' + $line.Substring(2)
            $line = $line.PadRight([Math]::Max(1, $Width - 1))
            & $set $row $line 'Black' 'Cyan'
        } else {
            & $set $row $line $null $null
        }
        $row++
    }

    $hint = ''
    if ($Top -gt 0 -and $last -lt $Items.Count)  { $hint = '  ^^ more above    vv more below' }
    elseif ($Top -gt 0)                          { $hint = '  ^^ more above' }
    elseif ($last -lt $Items.Count)              { $hint = '  vv more below' }

    $footerTop = $Height - $footerLines.Count
    if ($hint) {
        $hintRow = $footerTop - 1
        if ($hintRow -lt $row) { $hintRow = $row }
        & $set $hintRow $hint 'DarkGray' $null
    }

    for ($j = 0; $j -lt $footerLines.Count; $j++) {
        & $set ($footerTop + $j) $footerLines[$j] 'DarkGray' $null
    }
    return $rows
}

function Show-MenuScreen {
    param(
        [string]$Title,
        [string]$Subtitle,
        [string[]]$Items,
        [int]$Top,
        [int]$Selected,
        [int]$RowCount,
        [int]$Height,
        [int]$Width,
        [string]$Footer = ''
    )

    Clear-Screen
    $rows = New-MenuFrame -Title $Title -Subtitle $Subtitle -Items $Items -Top $Top -Selected $Selected `
        -RowCount $RowCount -Height $Height -Width $Width -Footer $Footer
    for ($r = 0; $r -lt $rows.Count; $r++) {
        Write-At $r $rows[$r].Text $rows[$r].Fg $rows[$r].Bg
    }
}

function Read-Menu {
    param(
        [string]$Title,
        [string]$Subtitle = '',
        [string[]]$Items,
        [int]$Selected = 0,
        [string]$Footer = '',
        [hashtable]$SpecialKeys = @{}
    )

    if ($null -eq $Items -or $Items.Count -eq 0) { return -1 }
    $count = $Items.Count
    if ($Selected -ge $count) { $Selected = $count - 1 }
    if ($Selected -lt 0) { $Selected = 0 }
    if (-not $Footer) { $Footer = $script:DefaultMenuFooter }

    $footerLines = @($Footer -split "`n").Count
    $subLines = 0
    if ($Subtitle) { $subLines = @($Subtitle -split "`n").Count }

    $top = 0
    while ($true) {
        $height = 30
        try { if ([Console]::WindowHeight -gt 10) { $height = [Console]::WindowHeight } } catch { }
        $width = 100
        try { if ([Console]::WindowWidth -gt 40) { $width = [Console]::WindowWidth } } catch { }

        $rowCount = $height - $footerLines - $subLines - 4
        if ($rowCount -lt 3) { $rowCount = 3 }

        if ($top -gt $Selected) { $top = $Selected }
        if ($Selected -ge ($top + $rowCount)) { $top = $Selected - $rowCount + 1 }
        $maxTop = [Math]::Max(0, $count - $rowCount)
        if ($top -gt $maxTop) { $top = $maxTop }
        if ($top -lt 0) { $top = 0 }

        Show-MenuScreen -Title $Title -Subtitle $Subtitle -Items $Items -Top $top -Selected $Selected `
            -RowCount $rowCount -Height $height -Width $width -Footer $Footer

        $key = Get-Key
        if ($null -eq $key) { return -1 }

        $keyName = [string]$key.Key
        $charName = ''
        if ($key.KeyChar -ne [char]0) { $charName = ([string]$key.KeyChar).ToLower() }
        if ($null -ne $SpecialKeys -and $SpecialKeys.Count -gt 0) {
            if ($keyName -and $SpecialKeys.ContainsKey($keyName)) { return [int]$SpecialKeys[$keyName] }
            if ($charName -and $SpecialKeys.ContainsKey($charName)) { return [int]$SpecialKeys[$charName] }
        }

        switch ($keyName) {
            'UpArrow'   { if ($Selected -gt 0) { $Selected-- } }
            'DownArrow' { if ($Selected -lt ($count - 1)) { $Selected++ } }
            'PageUp'    { $Selected = [Math]::Max(0, $Selected - $rowCount) }
            'PageDown'  { $Selected = [Math]::Min($count - 1, $Selected + $rowCount) }
            'Home'      { $Selected = 0 }
            'End'       { $Selected = $count - 1 }
            'Enter'     { return $Selected }
            'Escape'    { return -1 }
            'Backspace' { return -1 }
            default {
                if ($key.KeyChar -eq 'q' -or $key.KeyChar -eq 'Q') { return -1 }
                if ($key.KeyChar -eq 'k') { if ($Selected -gt 0) { $Selected-- } }
                if ($key.KeyChar -eq 'j') { if ($Selected -lt ($count - 1)) { $Selected++ } }
            }
        }
    }
}

# ----------------------------------------------------------------------------
# archive loading
# ----------------------------------------------------------------------------

function Load-Archive {
    param([string]$Path)

    $rows = @(Import-Csv -LiteralPath $Path)
    if ($rows.Count -eq 0) { return @() }

    $props = @($rows[0].PSObject.Properties.Name)
    $audioCol = $null
    foreach ($cand in @('audio', 'audio_url', 'audioUrl', 'wav', 'url')) {
        if ($props -contains $cand) { $audioCol = $cand; break }
    }
    if (-not $audioCol) {
        throw ('No audio URL column found in the CSV. Columns are: ' + ($props -join ', '))
    }

    $out = New-Object System.Collections.ArrayList
    $n = 0
    foreach ($row in $rows) {
        $n++
        $url = ([string]$row.$audioCol).Trim()
        if (-not $url) { continue }
        if ($url.StartsWith('//')) { $url = 'https:' + $url }
        if ($url -notmatch '^https?://') { continue }

        $path = $url
        $q = $path.IndexOf('?')
        if ($q -ge 0) { $path = $path.Substring(0, $q) }
        $seg = $path.Substring($path.LastIndexOf('/') + 1)
        try { $seg = [System.Uri]::UnescapeDataString($seg) } catch { }
        $file = ConvertTo-SafeName $seg
        if ($file -notmatch '\.[A-Za-z0-9]{2,5}$') { $file = $file + '.wav' }

        $date = ''
        foreach ($dn in @('date_local', 'date_utc', 'date')) {
            $v = Get-Field $row @($dn)
            if ($v) { $date = $v; break }
        }
        $year = ''
        if ($date -match '^(\d{4})') { $year = $Matches[1] }

        $rec = [pscustomobject]@{
            N           = $n
            Id          = Get-Field $row @('id')
            Url         = $url
            FileName    = $file
            Satellite   = Get-Field $row @('satellite')
            Year        = $year
            Date        = $date
            Country     = Get-Field $row @('country_territory', 'country')
            Contributor = Get-Field $row @('name')
            Location    = Get-Field $row @('location')
            Notes       = ((Get-Field $row @('weather_note')) + ' ' + (Get-Field $row @('climate_words'))).Trim()
            Search      = ''
        }
        $rec.Search = (@($rec.Id, $rec.Contributor, $rec.Location, $rec.Country, $rec.Satellite, $rec.Notes, $rec.FileName) | Where-Object { $_ }) -join ' | '
        [void]$out.Add($rec)
    }
    return $out
}

function Resolve-CsvPath {
    if ($CsvPath) {
        if (Test-Path -LiteralPath $CsvPath) { return (Resolve-Path -LiteralPath $CsvPath).Path }
        Write-Host ('  CSV not found: ' + $CsvPath) -ForegroundColor Red
    }

    $cands = @()
    if ($PSScriptRoot) {
        $cands = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.csv' -File -ErrorAction SilentlyContinue)
    }
    if ($cands.Count -eq 1) {
        Write-Host ('  Using ' + $cands[0].Name + ' found next to the script.') -ForegroundColor DarkGray
        return $cands[0].FullName
    }
    if ($cands.Count -gt 1) {
        $items = @($cands | ForEach-Object { $_.Name })
        $i = Read-Menu -Title 'Choose the archive CSV' -Subtitle ('  ' + $PSScriptRoot) -Items $items
        if ($i -ge 0) { return $cands[$i].FullName }
        return $null
    }

    Write-Host '  Drag the archive CSV into this window, or type its full path.' -ForegroundColor Yellow
    $line = Read-Host '  CSV path'
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    $line = $line.Trim().Trim('"').Trim("'")
    if (Test-Path -LiteralPath $line) { return (Resolve-Path -LiteralPath $line).Path }
    Write-Host ('  Not found: ' + $line) -ForegroundColor Red
    return $null
}

# ----------------------------------------------------------------------------
# filters
# ----------------------------------------------------------------------------

function Filter-ByValue {
    param(
        [string]$Title,
        [string]$Property,
        [string]$SortMode = 'Count'
    )

    $groups = @($script:Selection | Where-Object { $_.$Property } | Group-Object -Property $Property)
    if ($groups.Count -eq 0) {
        Show-Message ('No ' + $Property + ' values in the current selection.')
        return
    }

    if ($SortMode -eq 'Count') {
        $groups = @($groups | Sort-Object -Property @{ Expression = { $_.Count }; Descending = $true }, @{ Expression = { $_.Name } })
    } elseif ($SortMode -eq 'NameDesc') {
        $groups = @($groups | Sort-Object -Property @{ Expression = { $_.Name }; Descending = $true })
    } else {
        $groups = @($groups | Sort-Object -Property @{ Expression = { $_.Name } })
    }

    $items = @($groups | ForEach-Object { '{0}   ({1:N0})' -f $_.Name, $_.Count })
    $i = Read-Menu -Title $Title -Subtitle ('  ' + $groups.Count + ' option(s) from the current selection') -Items $items
    if ($i -lt 0) { return }

    $val = $groups[$i].Name
    $new = @($script:Selection | Where-Object { $_.$Property -eq $val })
    if ($new.Count -eq 0) { Show-Message 'No records matched.'; return }
    $script:Selection = $new
}

function Filter-DateRange {
    Clear-Screen
    Write-Host ''
    Write-Host '  Date range' -ForegroundColor Cyan
    Write-Host '  Format yyyy-mm-dd. Leave blank for no limit. Esc is not available here.' -ForegroundColor DarkGray
    $from = Read-Host '  From'
    $to = Read-Host '  To'
    $from = ([string]$from).Trim()
    $to = ([string]$to).Trim()
    if (-not $from -and -not $to) { return }
    if ($from -and $from -notmatch '^\d{4}-\d{2}-\d{2}$') { Show-Message 'From date must look like 2025-06-01.'; return }
    if ($to   -and $to   -notmatch '^\d{4}-\d{2}-\d{2}$') { Show-Message 'To date must look like 2025-08-31.'; return }

    $new = @($script:Selection | Where-Object {
        $_.Date -and (-not $from -or $_.Date -ge $from) -and (-not $to -or $_.Date -le $to)
    })
    if ($new.Count -eq 0) { Show-Message 'No records in that range.'; return }
    $script:Selection = $new
}

function Filter-ById {
    Clear-Screen
    Write-Host ''
    Write-Host '  Filter by record ID' -ForegroundColor Cyan
    $kw = ([string](Read-Host '  ID or prefix (e.g. OW3301 or OW33)')).Trim()
    if (-not $kw) { return }
    $new = @($script:Selection | Where-Object { $_.Id -like ('*' + $kw + '*') })
    if ($new.Count -eq 0) { Show-Message ('No record ID contains "' + $kw + '".'); return }
    $script:Selection = $new
}

function Filter-Search {
    Clear-Screen
    Write-Host ''
    Write-Host '  Search text' -ForegroundColor Cyan
    Write-Host '  Matches ID, contributor, location, country, satellite, notes and filename.' -ForegroundColor DarkGray
    $kw = ([string](Read-Host '  Search for')).Trim()
    if (-not $kw) { return }
    $new = @($script:Selection | Where-Object { $_.Search -like ('*' + $kw + '*') })
    if ($new.Count -eq 0) { Show-Message ('Nothing matches "' + $kw + '".'); return }
    $script:Selection = $new
}

# ----------------------------------------------------------------------------
# settings
# ----------------------------------------------------------------------------

function Settings-Menu {
    while ($true) {
        $s = $script:Settings
        $skip = 'No';  if ($s.SkipExisting) { $skip = 'Yes' }
        $pref = 'No';  if ($s.IdPrefix)     { $pref = 'Yes' }
        $open = 'No';  if ($s.OpenWhenDone) { $open = 'Yes' }

        $items = @(
            ('Parallel downloads: {0}' -f $s.Parallel),
            ('Output folder: {0}' -f $s.OutDir),
            ('Skip files already on disk: {0}' -f $skip),
            ('Prefix filenames with record ID: {0}' -f $pref),
            ('Open the folder when finished: {0}' -f $open),
            'Back'
        )
        $i = Read-Menu -Title 'Settings' -Subtitle '  Changes apply to the rest of this session' -Items $items
        if ($i -lt 0 -or $i -eq 5) { return }

        switch ($i) {
            0 {
                $opts = @('1', '2', '4', '6', '8', '10', '12', '16', '20', '24', '32')
                $cur = 0
                for ($k = 0; $k -lt $opts.Count; $k++) { if ($opts[$k] -eq [string]$s.Parallel) { $cur = $k } }
                $j = Read-Menu -Title 'Parallel downloads' -Subtitle '  More is faster on a fast line; too many can get you throttled' -Items $opts -Selected $cur
                if ($j -ge 0) { $script:Settings.Parallel = [int]$opts[$j] }
            }
            1 {
                Clear-Screen
                Write-Host ''
                Write-Host ('  Current folder: ' + $s.OutDir) -ForegroundColor DarkGray
                $p = ([string](Read-Host '  New folder (blank keeps current)')).Trim().Trim('"')
                if ($p) { $script:Settings.OutDir = $p }
            }
            2 { $script:Settings.SkipExisting = -not $s.SkipExisting }
            3 { $script:Settings.IdPrefix = -not $s.IdPrefix }
            4 { $script:Settings.OpenWhenDone = -not $s.OpenWhenDone }
        }
    }
}

# ----------------------------------------------------------------------------
# download
# ----------------------------------------------------------------------------

function Get-NamingPlan {
    # one entry per unique URL, with the final file name / destination path
    param($Records)

    $outDir = $script:Settings.OutDir
    $plan = New-Object System.Collections.ArrayList
    $seenUrl = @{}
    $usedName = @{}

    foreach ($r in $Records) {
        if ($seenUrl.ContainsKey($r.Url)) { continue }
        $seenUrl[$r.Url] = $true

        $name = $r.FileName
        if ($script:Settings.IdPrefix -and $r.Id) { $name = $r.Id + '_' + $name }
        $name = ConvertTo-SafeName $name

        $cand = $name
        $n = 1
        while ($usedName.ContainsKey($cand.ToLower())) {
            $n++
            $cand = [System.IO.Path]::GetFileNameWithoutExtension($name) + '_' + $n + [System.IO.Path]::GetExtension($name)
        }
        $usedName[$cand.ToLower()] = $true

        $dest = Join-Path $outDir $cand
        [void]$plan.Add([pscustomobject]@{
            Record = $r
            Url    = $r.Url
            Name   = $cand
            Dest   = $dest
            Part   = ($dest + '.part')
            Id     = $r.Id
        })
    }
    return $plan
}

function New-DownloadQueue {
    param($Records)

    $plan = Get-NamingPlan -Records $Records
    $queue = New-Object System.Collections.ArrayList
    $skipped = 0

    foreach ($it in $plan) {
        if ($script:Settings.SkipExisting -and (Test-Path -LiteralPath $it.Dest)) {
            $len = 0
            try { $len = (Get-Item -LiteralPath $it.Dest).Length } catch { }
            if ($len -gt 0) { $skipped++; continue }
        }
        [void]$queue.Add($it)
    }

    return [pscustomobject]@{
        Items      = $queue
        Skipped    = $skipped
        Duplicates = ([Math]::Max(0, @($Records).Count - $plan.Count))
    }
}

function Invoke-DownloadNative {
    param($Queue)

    $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
    if (-not $curl) { return $false }

    $versionText = ''
    try { $versionText = (& curl.exe --version | Select-Object -First 1) } catch { }
    $supportsParallel = $false
    if ($versionText -match 'curl (\d+)\.(\d+)') {
        $maj = [int]$Matches[1]; $min = [int]$Matches[2]
        if ($maj -gt 7 -or ($maj -eq 7 -and $min -ge 66)) { $supportsParallel = $true }
    }

    $parallel = [int]$script:Settings.Parallel
    if ($parallel -lt 1) { $parallel = 1 }

    $total = $Queue.Count
    $cfg = Join-Path ([System.IO.Path]::GetTempPath()) ('owdl_' + [guid]::NewGuid().ToString('N') + '.cfg')
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($it in $Queue) {
        $lines.Add('url = "' + $it.Url + '"')
        $lines.Add('output = "' + ($it.Part -replace '\\', '/') + '"')
    }
    [System.IO.File]::WriteAllLines($cfg, $lines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))

    $curlArgs = New-Object System.Collections.Generic.List[string]
    $curlArgs.Add('-K'); $curlArgs.Add($cfg)
    if ($supportsParallel -and $parallel -gt 1) {
        $curlArgs.Add('--parallel'); $curlArgs.Add('--parallel-max'); $curlArgs.Add([string]$parallel)
    }
    foreach ($a in @('-f', '-sS', '--retry', '2', '--retry-delay', '2', '--connect-timeout', '25',
                     '--speed-limit', '1024', '--speed-time', '120',
                     '-A', 'Mozilla/5.0 (OpenWeather Archive Downloader)',
                     '-w', '%{http_code} %{size_download} %{url_effective}\n')) {
        $curlArgs.Add($a)
    }

    $done = 0
    $bytes = [int64]0
    $httpErrors = 0
    $transportErrors = 0

    # curl writes progress/errors to stderr; with ErrorActionPreference=Stop a native
    # command writing to stderr becomes a terminating error, so relax it here.
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & curl.exe @($curlArgs.ToArray()) 2>&1 | ForEach-Object {
            $line = [string]$_
            if ($line -match '^([1-5]\d\d) (\d+) (\S*)') {
                $code = [int]$Matches[1]
                $done++
                $bytes += [int64]$Matches[2]
                if ($code -ge 400) { $httpErrors++ }
                $pct = [int](100 * $done / [Math]::Max(1, $total))
                Write-Progress -Id 1 -Activity 'Downloading audio' `
                    -Status ("{0:N0}/{1:N0} finished | {2} so far | last: HTTP {3}" -f $done, $total, (Format-Size $bytes), $code) `
                    -PercentComplete $pct
            } elseif ($line -match '^curl: \((\d+)\)') {
                $transportErrors++
            }
        }
    } finally {
        $ErrorActionPreference = $prevEap
        Write-Progress -Id 1 -Activity 'Downloading audio' -Completed
        Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue
    }

    Write-Host ('  Transfer pass finished: {0:N0} response(s), {1}, {2} HTTP error(s), {3} stderr notice(s).' -f $done, (Format-Size $bytes), $httpErrors, $transportErrors) -ForegroundColor DarkGray
    return $true
}

function Invoke-DownloadFallback {
    param($Queue)

    Write-Host '  curl.exe not found - using Invoke-WebRequest (slower, one file at a time).' -ForegroundColor Yellow
    $total = $Queue.Count
    $done = 0
    $bytes = [int64]0
    foreach ($it in $Queue) {
        $done++
        Write-Progress -Id 1 -Activity 'Downloading audio' -Status ("{0:N0}/{1:N0}  {2}" -f $done, $total, $it.Name) -PercentComplete ([int](100 * $done / [Math]::Max(1, $total)))
        try {
            Invoke-WebRequest -Uri $it.Url -OutFile $it.Part -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop | Out-Null
            if ((Test-Path -LiteralPath $it.Part) -and (Get-Item -LiteralPath $it.Part).Length -gt 0) {
                $bytes += (Get-Item -LiteralPath $it.Part).Length
            }
        } catch {
            Remove-Item -LiteralPath $it.Part -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Progress -Id 1 -Activity 'Downloading audio' -Completed
}

# ----------------------------------------------------------------------------
# download engine + live progress panel
# ----------------------------------------------------------------------------

$script:EngineSource = @'
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

public class OwJob
{
    public string Url = "";
    public string Dest = "";
    public string Part = "";
    public string Name = "";
    public long Total = -1;
    public long Received = 0;
    public int State = 0;   // 0 queued, 1 running, 2 done, 3 failed
    public string Error = "";
}

public class OwEngine
{
    public List<OwJob> Jobs = new List<OwJob>();
    public int Parallel = 8;
    public int Completed = 0;
    public int Failed = 0;
    public int Finished = 0;
    public volatile bool Stopped = false;

    private long _received = 0;
    private ConcurrentQueue<OwJob> _queue = new ConcurrentQueue<OwJob>();
    private int _workersLeft = 0;
    private static HttpClient _http = null;
    private static object _gate = new object();

    public long Received { get { return Interlocked.Read(ref _received); } }

    public void Add(OwJob job)
    {
        Jobs.Add(job);
        _queue.Enqueue(job);
    }

    public void Start()
    {
        int n = Parallel < 1 ? 1 : Parallel;
        _workersLeft = n;
        for (int i = 0; i < n; i++)
        {
            Thread t = new Thread(Worker);
            t.IsBackground = true;
            t.Start();
        }
    }

    public void Stop() { Stopped = true; }

    private static HttpClient Client
    {
        get
        {
            if (_http == null)
            {
                lock (_gate)
                {
                    if (_http == null)
                    {
                        ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                        ServicePointManager.DefaultConnectionLimit = 64;
                        ServicePointManager.Expect100Continue = false;
                        HttpClient h = new HttpClient();
                        h.Timeout = Timeout.InfiniteTimeSpan;
                        h.DefaultRequestHeaders.Add("User-Agent", "Mozilla/5.0 (OpenWeather Archive Downloader)");
                        _http = h;
                    }
                }
            }
            return _http;
        }
    }

    private void Worker()
    {
        try
        {
            OwJob job;
            while (!Stopped && _queue.TryDequeue(out job))
            {
                job.State = 1;
                bool ok = false;
                for (int attempt = 0; attempt < 2 && !ok && !Stopped; attempt++)
                {
                    try
                    {
                        Get(job);
                        ok = true;
                    }
                    catch (Exception ex)
                    {
                        job.Error = ex.Message;
                        Interlocked.Add(ref _received, -job.Received);
                        job.Received = 0;
                        Thread.Sleep(700);
                    }
                }
                if (ok)
                {
                    job.State = 2;
                    Interlocked.Increment(ref Completed);
                }
                else
                {
                    job.State = 3;
                    TryDelete(job.Part);
                    Interlocked.Increment(ref Failed);
                }
            }
        }
        finally
        {
            if (Interlocked.Decrement(ref _workersLeft) == 0) { Interlocked.Exchange(ref Finished, 1); }
        }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) { File.Delete(path); } } catch { }
    }

    private void Get(OwJob job)
    {
        using (HttpResponseMessage resp = Client.GetAsync(job.Url, HttpCompletionOption.ResponseHeadersRead).GetAwaiter().GetResult())
        {
            if (!resp.IsSuccessStatusCode)
            {
                throw new Exception("HTTP " + ((int)resp.StatusCode).ToString());
            }

            long total = -1;
            if (resp.Content.Headers.ContentLength.HasValue) { total = resp.Content.Headers.ContentLength.Value; }
            job.Total = total;

            using (Stream src = resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
            using (FileStream dst = new FileStream(job.Part, FileMode.Create, FileAccess.Write, FileShare.None, 65536))
            {
                byte[] buf = new byte[65536];
                int n;
                while ((n = src.Read(buf, 0, buf.Length)) > 0)
                {
                    if (Stopped) { throw new Exception("cancelled"); }
                    dst.Write(buf, 0, n);
                    Interlocked.Add(ref _received, n);
                    Interlocked.Add(ref job.Received, n);
                }
            }

            if (job.Total > 0 && job.Received != job.Total)
            {
                throw new Exception("incomplete " + job.Received.ToString() + "/" + job.Total.ToString());
            }

            TryDelete(job.Dest);
            File.Move(job.Part, job.Dest);
        }
    }
}
'@

$script:EngineReady = $null

function Initialize-DownloadEngine {
    if ($null -ne $script:EngineReady) { return $script:EngineReady }
    try {
        Add-Type -TypeDefinition $script:EngineSource -Language CSharp -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Net.Http') -ErrorAction Stop
        $script:EngineReady = $true
    } catch {
        $script:EngineReady = $false
        $script:EngineError = $_.Exception.Message
    }
    return $script:EngineReady
}

function Write-Seg {
    param([int]$Row, [int]$Col, [string]$Text, $Fg = $null, $Bg = $null)
    if ($Row -lt 0 -or $Col -lt 0) { return }
    try { [Console]::SetCursorPosition($Col, $Row) } catch { return }
    try {
        if ($Fg -and $Bg) { Write-Host $Text -ForegroundColor $Fg -BackgroundColor $Bg -NoNewline }
        elseif ($Fg) { Write-Host $Text -ForegroundColor $Fg -NoNewline }
        else { Write-Host $Text -NoNewline }
    } catch { }
}

function Clear-PanelRow {
    param([int]$Row, [int]$Width)
    Write-Seg -Row $Row -Col 0 -Text (' ' * ([Math]::Max(1, $Width - 1)))
}

function Write-Bar {
    # draws a block bar and returns the column after it
    param([int]$Row, [int]$Col, [double]$Fraction, [int]$Width, [switch]$Pulse, [double]$Phase = 0)

    if ($Fraction -lt 0) { $Fraction = 0 }
    if ($Fraction -gt 1) { $Fraction = 1 }

    if ($Pulse) {
        # unknown total: a block sweeping left to right
        $chunk = [Math]::Max(4, [int]($Width / 4))
        $pos = [int](($Phase % 1.0) * ($Width + $chunk)) - $chunk
        $left = ''
        $mid = ''
        $right = ''
        for ($i = 0; $i -lt $Width; $i++) {
            if ($i -ge $pos -and $i -lt ($pos + $chunk)) { $mid += [char]0x2588 }
            elseif ($i -lt $pos) { $left += [char]0x2591 }
            else { $right += [char]0x2591 }
        }
        if ($left) { Write-Seg -Row $Row -Col $Col -Text $left -Fg DarkGray }
        if ($mid) { Write-Seg -Row $Row -Col ($Col + $left.Length) -Text $mid -Fg Cyan }
        if ($right) { Write-Seg -Row $Row -Col ($Col + $left.Length + $mid.Length) -Text $right -Fg DarkGray }
        return ($Col + $Width)
    }

    $filled = [int][Math]::Round($Width * $Fraction)
    if ($filled -lt 0) { $filled = 0 }
    if ($filled -gt $Width) { $filled = $Width }
    $empty = $Width - $filled

    if ($filled -gt 0) {
        $color = 'Cyan'
        if ($Fraction -ge 1) { $color = 'Green' }
        Write-Seg -Row $Row -Col $Col -Text ([string]([char]0x2588) * $filled) -Fg $color
    }
    if ($empty -gt 0) {
        Write-Seg -Row $Row -Col ($Col + $filled) -Text ([string]([char]0x2591) * $empty) -Fg DarkGray
    }
    return ($Col + $Width)
}

function Format-Duration {
    param([double]$Seconds)
    if ([double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds) -or $Seconds -lt 0 -or $Seconds -gt 359999) { return '--:--' }
    $t = [TimeSpan]::FromSeconds($Seconds)
    if ($t.TotalHours -ge 1) { return ('{0}:{1:00}:{2:00}' -f [int][Math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds) }
    return ('{0:00}:{1:00}' -f $t.Minutes, $t.Seconds)
}

function Update-DownloadPanel {
    param($Engine, [TimeSpan]$Elapsed, [int]$Top = 4)

    $height = 30
    try { if ([Console]::WindowHeight -gt 10) { $height = [Console]::WindowHeight } } catch { }
    $width = 100
    try { if ([Console]::WindowWidth -gt 60) { $width = [Console]::WindowWidth } } catch { }

    $jobs = @($Engine.Jobs)
    $totalFiles = $jobs.Count
    $doneFiles = $Engine.Completed + $Engine.Failed
    $failed = $Engine.Failed
    $received = $Engine.Received
    $seconds = [Math]::Max(0.001, $Elapsed.TotalSeconds)
    $speed = $received / $seconds

    $barWidth = [Math]::Min(42, [Math]::Max(18, $width - 62))

    # progress: single file -> bytes, many files -> files finished
    $single = $null
    if ($totalFiles -eq 1) { $single = $jobs[0] }

    if ($single -and $single.Total -gt 0) {
        $frac = [double]$single.Received / [double]$single.Total
        $pulse = $false
        $eta = if ($speed -gt 0) { ([double]$single.Total - [double]$single.Received) / $speed } else { -1 }
        $bytesText = ('{0} / {1}' -f (Format-Size $single.Received), (Format-Size $single.Total))
    } elseif ($single) {
        $frac = 0
        $pulse = $true
        $eta = -1
        $bytesText = (Format-Size $received)
    } else {
        if ($doneFiles -gt $totalFiles) { $doneFiles = $totalFiles }
        $frac = [double]$doneFiles / [Math]::Max(1, $totalFiles)
        $pulse = $false
        if ($doneFiles -gt 0) { $eta = ($totalFiles - $doneFiles) * ($seconds / $doneFiles) } else { $eta = -1 }
        $bytesText = (Format-Size $received)
    }

    if ($frac -lt 0) { $frac = 0 }
    if ($frac -gt 1) { $frac = 1 }

    $pct = [int][Math]::Round(100 * $frac)
    if ($pulse) { $pct = -1 }

    # row 0: the bar
    Clear-PanelRow -Row $Top -Width $width
    $col = 2
    if ($pulse) {
        $col = Write-Bar -Row $Top -Col $col -Fraction 0 -Width $barWidth -Pulse -Phase (($Elapsed.TotalSeconds / 1.6) % 1.0)
        $pulseText = '  working...   ' + (Format-Size $received) + '   ' + (Format-Size $speed) + '/s'
        $room = [Math]::Max(0, $width - $col - 2)
        if ($pulseText.Length -gt $room) { $pulseText = $pulseText.Substring(0, $room) }
        Write-Seg -Row $Top -Col $col -Text $pulseText -Fg Cyan
    } else {
        $col = Write-Bar -Row $Top -Col $col -Fraction $frac -Width $barWidth
        Write-Seg -Row $Top -Col $col -Text (' {0,3}%' -f $pct) -Fg White
        $col += 6
        $etaPart = ''
        if ($frac -lt 1 -and $eta -ge 0) { $etaPart = '   ETA ' + (Format-Duration $eta) }
        $tail = '  ' + $bytesText + '   ' + (Format-Size $speed) + '/s' + $etaPart
        $room = [Math]::Max(0, $width - $col - 2)
        if ($tail.Length -gt $room) { $tail = $tail.Substring(0, $room) }
        Write-Seg -Row $Top -Col $col -Text $tail -Fg DarkGray
    }

    # row 1: summary
    $row = $Top + 1
    Clear-PanelRow -Row $row -Width $width
    if ($single) {
        $name = [string]$single.Name
        if ($name.Length -gt ($width - 12)) { $name = $name.Substring(0, $width - 15) + '...' }
        Write-Seg -Row $row -Col 2 -Text $name -Fg White
    } else {
        $line = ('  {0:N0} / {1:N0} files   {2} parallel   {3} failed   elapsed {4}' -f $doneFiles, $totalFiles, $Engine.Parallel, $failed, (Format-Duration $seconds))
        Write-Seg -Row $row -Col 0 -Text $line -Fg DarkGray
    }
    $row++

    # rows: active transfers
    $maxRows = [Math]::Max(0, [Math]::Min(6, $height - $Top - 4))
    $active = @($jobs | Where-Object { $_.State -eq 1 })
    $shown = 0
    if (-not $single) {
        foreach ($job in $active) {
            if ($shown -ge $maxRows) { break }
            Clear-PanelRow -Row $row -Width $width
            $name = [string]$job.Name
            $nameWidth = [Math]::Min(34, [Math]::Max(14, $width - 62))
            if ($name.Length -gt $nameWidth) { $name = $name.Substring(0, $nameWidth - 3) + '...' }
            Write-Seg -Row $row -Col 2 -Text ($name.PadRight($nameWidth)) -Fg Gray
            $jobFrac = 0.0
            $jobText = ''
            if ($job.Total -gt 0) {
                $jobFrac = [double]$job.Received / [double]$job.Total
                $jobText = ('{0,3}%  {1}' -f [int](100 * $jobFrac), (Format-Size $job.Received))
            } else {
                $jobFrac = 0
                $jobText = ('     {0}' -f (Format-Size $job.Received))
            }
            [void](Write-Bar -Row $row -Col (2 + $nameWidth + 2) -Fraction $jobFrac -Width 16)
            Write-Seg -Row $row -Col (2 + $nameWidth + 2 + 16) -Text ('  ' + $jobText) -Fg DarkGray
            $row++
            $shown++
        }
    }

    if ($failed -gt 0) {
        Clear-PanelRow -Row $row -Width $width
        Write-Seg -Row $row -Col 2 -Text ('{0} failed (see the report when this finishes)' -f $failed) -Fg DarkYellow
        $row++
    }

    # wipe anything left from the previous frame
    for ($r = $row; $r -le $script:PanelDrawnTo; $r++) {
        if ($r -gt $Top) { Clear-PanelRow -Row $r -Width $width }
    }
    $script:PanelDrawnTo = $row - 1
    return ($row)
}

function Invoke-DownloadEngine {
    # streaming downloads through the compiled engine, with the live panel.
    # returns $false when the engine is unavailable so the caller can fall back.
    param($Items)

    if (-not (Initialize-DownloadEngine)) { return $false }

    $engine = New-Object OwEngine
    $engine.Parallel = [Math]::Max(1, [int]$script:Settings.Parallel)
    foreach ($it in $Items) {
        $job = New-Object OwJob
        $job.Url = $it.Url
        $job.Dest = $it.Dest
        $job.Part = $it.Part
        $job.Name = $it.Name
        $engine.Add($job)
    }

    $quiet = $false
    try { $quiet = [Console]::IsOutputRedirected } catch { }
    $inputRedirected = $false
    try { $inputRedirected = [Console]::IsInputRedirected } catch { }

    $script:PanelDrawnTo = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $engine.Start()
    $stopped = $false

    while ($engine.Finished -eq 0) {
        if (-not $quiet) {
            try { [void](Update-DownloadPanel -Engine $engine -Elapsed $sw.Elapsed) } catch { }
        }

        if (-not $inputRedirected) {
            try {
                while ([Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    if ($k.Key -eq 'Escape') { $engine.Stop(); $stopped = $true }
                }
            } catch { }
        }
        if ($stopped) { break }
        Start-Sleep -Milliseconds 220
    }

    if ($stopped) {
        $wait = 0
        while ($engine.Finished -eq 0 -and $wait -lt 100) { Start-Sleep -Milliseconds 100; $wait++ }
    }
    $sw.Stop()

    if (-not $quiet) {
        try { [void](Update-DownloadPanel -Engine $engine -Elapsed $sw.Elapsed) } catch { }
        $row = [Math]::Max(1, $script:PanelDrawnTo + 2)
        try { [Console]::SetCursorPosition(0, $row) } catch { }
        Write-Host ''
    }

    if (-not $inputRedirected) {
        try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { }
    }

    if ($stopped) {
        Write-Host ('  Stopped after {0:N0} of {1:N0} file(s).' -f ($engine.Completed + $engine.Failed), $engine.Jobs.Count) -ForegroundColor Yellow
    }
    return $true
}

function Invoke-DownloadItems {
    # transfers an explicit list of queue items (already named), then verifies,
    # promotes .part files, retries failures and reports.
    param($Items, [string]$OutDir, [int]$Skipped = 0, [string]$Heading = '')

    $total = @($Items).Count
    if ($total -eq 0) { return }

    Clear-Screen
    Write-Host ''
    Write-Host ('  Output folder: ' + $OutDir) -ForegroundColor Cyan
    if ($Heading) { Write-Host ('  ' + $Heading) -ForegroundColor DarkGray }
    Write-Host '  press Esc to stop the transfer' -ForegroundColor DarkGray

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $usedEngine = Invoke-DownloadEngine -Items $Items
    if (-not $usedEngine) {
        $usedNative = Invoke-DownloadNative -Queue $Items
        if (-not $usedNative) { Invoke-DownloadFallback -Queue $Items }
    }

    # verify / promote .part files, because a transfer can still fail mid-way
    $ok = 0
    $written = [int64]0
    $failed = New-Object System.Collections.ArrayList
    foreach ($it in $Items) {
        if (Test-Path -LiteralPath $it.Part) {
            $len = 0
            try { $len = (Get-Item -LiteralPath $it.Part).Length } catch { }
            if ($len -gt 0) {
                try {
                    Move-Item -LiteralPath $it.Part -Destination $it.Dest -Force
                    $ok++
                    $written += $len
                    continue
                } catch { }
            }
            Remove-Item -LiteralPath $it.Part -Force -ErrorAction SilentlyContinue
            [void]$failed.Add($it)
        } else {
            $len = 0
            if (Test-Path -LiteralPath $it.Dest) { try { $len = (Get-Item -LiteralPath $it.Dest).Length } catch { } }
            if ($len -gt 0) { $ok++; $written += $len } else { [void]$failed.Add($it) }
        }
    }

    # one retry pass for whatever is left
    if ($failed.Count -gt 0) {
        Write-Host ''
        Write-Host ('  Retrying {0:N0} failed file(s) one at a time...' -f $failed.Count) -ForegroundColor Yellow
        $stillBad = New-Object System.Collections.ArrayList
        $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
        $idx = 0
        foreach ($it in $failed) {
            $idx++
            Write-Progress -Id 1 -Activity 'Retrying failed files' -Status ("{0}/{1}  {2}" -f $idx, $failed.Count, $it.Name) -PercentComplete ([int](100 * $idx / [Math]::Max(1, $failed.Count)))
            $good = $false
            if ($curl) {
                $prevEap = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    & curl.exe -f -sS -L --retry 3 --retry-delay 3 --connect-timeout 25 --speed-limit 1024 --speed-time 120 -A 'Mozilla/5.0 (OpenWeather Archive Downloader)' -o $it.Part $it.Url 2>$null
                } catch { } finally {
                    $ErrorActionPreference = $prevEap
                }
                if ((Test-Path -LiteralPath $it.Part) -and (Get-Item -LiteralPath $it.Part).Length -gt 0) { $good = $true }
            } else {
                try {
                    Invoke-WebRequest -Uri $it.Url -OutFile $it.Part -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop | Out-Null
                    if ((Test-Path -LiteralPath $it.Part) -and (Get-Item -LiteralPath $it.Part).Length -gt 0) { $good = $true }
                } catch { }
            }
            if ($good) {
                try {
                    $written += (Get-Item -LiteralPath $it.Part).Length
                    Move-Item -LiteralPath $it.Part -Destination $it.Dest -Force
                    $ok++
                } catch { $good = $false }
            }
            if (-not $good) {
                Remove-Item -LiteralPath $it.Part -Force -ErrorAction SilentlyContinue
                [void]$stillBad.Add($it)
            }
        }
        Write-Progress -Id 1 -Activity 'Retrying failed files' -Completed
        $failed = $stillBad
    }

    $sw.Stop()
    Write-Host ''
    Write-Host ('  Done in ' + $sw.Elapsed.ToString('hh\:mm\:ss')) -ForegroundColor Cyan
    Write-Host ('  Downloaded: {0:N0}   Written: {1}   Already present: {2:N0}   Failed: {3:N0}' -f $ok, (Format-Size $written), $Skipped, $failed.Count) -ForegroundColor Green
    Write-Host ('  Folder: ' + $OutDir) -ForegroundColor DarkGray

    if ($failed.Count -gt 0) {
        $log = Join-Path $OutDir ('failed-downloads_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')
        try {
            $failed | ForEach-Object { $_.Url } | Set-Content -LiteralPath $log -Encoding UTF8
            Write-Host ('  Failed URLs written to: ' + $log) -ForegroundColor Yellow
        } catch { }
        Write-Host '  These are usually links that no longer exist on the server (HTTP 404).' -ForegroundColor DarkGray
    }

    if ($ok -gt 0 -and $script:Settings.OpenWhenDone) {
        try { Start-Process -FilePath $OutDir | Out-Null } catch { }
    }

    Show-Message 'Finished.'
}

function Initialize-OutputFolder {
    $outDir = $script:Settings.OutDir
    if (-not $outDir) {
        $outDir = Join-Path (Split-Path -Parent $script:CsvPath) 'wav'
        $script:Settings.OutDir = $outDir
    }
    try {
        if (-not (Test-Path -LiteralPath $outDir)) {
            [void](New-Item -ItemType Directory -Path $outDir -Force)
        }
    } catch {
        Show-Message ('Could not create the output folder: ' + $outDir)
        return $false
    }
    return $true
}

function Clear-StalePartials {
    $outDir = $script:Settings.OutDir
    $stale = @()
    try { $stale = @(Get-ChildItem -LiteralPath $outDir -Filter '*.part' -File -ErrorAction SilentlyContinue) } catch { }
    foreach ($f in $stale) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    if ($stale.Count -gt 0) { Write-Host ('  Removed ' + $stale.Count + ' leftover partial file(s).') -ForegroundColor DarkGray }
}

function Start-DownloadRun {
    param($Records)

    Clear-Screen
    if (-not (Initialize-OutputFolder)) { return }

    Write-Host ''
    Write-Host ('  Output folder: ' + $script:Settings.OutDir) -ForegroundColor Cyan
    # stale partials from an interrupted run are useless without resume
    Clear-StalePartials

    $queue = New-DownloadQueue $Records
    if ($queue.Items.Count -eq 0) {
        Show-Message ('Nothing to download. ' + $queue.Skipped + ' file(s) already on disk.') 'Green'
        return
    }

    Write-Host ('  {0:N0} file(s) queued, {1:N0} already on disk, {2:N0} duplicate link(s) collapsed.' -f $queue.Items.Count, $queue.Skipped, $queue.Duplicates) -ForegroundColor Green

    Invoke-DownloadItems -Items $queue.Items -OutDir $script:Settings.OutDir -Skipped $queue.Skipped
}

function Save-Selection {
    param($Records)

    $outDir = $script:Settings.OutDir
    if (-not (Test-Path -LiteralPath $outDir)) { [void](New-Item -ItemType Directory -Path $outDir -Force) }
    $file = Join-Path $outDir ('selection_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.csv')
    $Records | Select-Object Id, Url, FileName, Satellite, Date, Country, Contributor, Location |
        Export-Csv -LiteralPath $file -NoTypeInformation -Encoding UTF8
    Show-Message ('Selection saved to ' + $file) 'Green'
}

function Show-DownloadBrowser {
    # paginated file list: highlight one and press Enter to download just that file
    param($Records)

    $pageSize = 20
    if (-not (Initialize-OutputFolder)) { return }

    $plan = @(Get-NamingPlan -Records $Records)
    if ($plan.Count -eq 0) { Show-Message 'Nothing to show for this selection.'; return }

    $pageCount = [int][Math]::Ceiling($plan.Count / $pageSize)
    $page = 0
    $sel = 0
    $footer = @(
        '  Enter = this file   a = all   p = page   s = save list   Esc = back',
        '  Up/Down select   Left/Right page   PgUp/PgDn   Home/End'
    ) -join "`n"

    $specials = @{
        'LeftArrow'  = -2
        'RightArrow' = -3
        'a'          = -4
        'p'          = -5
        's'          = -6
    }

    while ($true) {
        if ($page -lt 0) { $page = 0 }
        if ($page -gt ($pageCount - 1)) { $page = $pageCount - 1 }

        $start = $page * $pageSize
        $end = [Math]::Min($plan.Count - 1, $start + $pageSize - 1)
        $slice = @($plan[$start..$end])

        $labels = New-Object System.Collections.ArrayList
        $onDisk = 0
        $n = $start
        foreach ($it in $slice) {
            $n++
            $exists = $false
            try { $exists = (Test-Path -LiteralPath $it.Dest) -and ((Get-Item -LiteralPath $it.Dest).Length -gt 0) } catch { }
            if ($exists) { $onDisk++ }
            $mark = '   '
            if ($exists) { $mark = '[x]' }
            $date = [string]$it.Record.Date
            $sat = [string]$it.Record.Satellite
            if (-not $sat) { $sat = '-' }
            [void]$labels.Add(('{0} {1,5}  {2,-7} {3,-8} {4,-10} {5}' -f $mark, $n, $it.Id, $sat, $date, $it.Name))
        }

        if ($sel -ge $labels.Count) { $sel = $labels.Count - 1 }
        if ($sel -lt 0) { $sel = 0 }

        $sub = ('  page {0} of {1}   files {2:N0}-{3:N0} of {4:N0}   on disk: {5}/{6}' -f `
                ($page + 1), $pageCount, ($start + 1), ($end + 1), $plan.Count, $onDisk, $slice.Count)
        $sub = $sub + "`n" + ('  folder: ' + $script:Settings.OutDir)

        $code = Read-Menu -Title 'Files in the current selection' -Subtitle $sub -Items @($labels) `
            -Selected $sel -Footer $footer -SpecialKeys $specials

        if ($code -eq -1) { return }
        if ($code -eq -2) { if ($page -gt 0) { $page--; $sel = 0 }; continue }
        if ($code -eq -3) { if ($page -lt ($pageCount - 1)) { $page++; $sel = 0 }; continue }
        if ($code -eq -6) { Save-Selection $Records; continue }

        if ($code -eq -4) {
            $answer = Read-Menu -Title 'Download everything?' -Subtitle ('  {0:N0} file(s) into {1}' -f $plan.Count, $script:Settings.OutDir) `
                -Items @('Yes, download all of them', 'No, back to the list')
            if ($answer -eq 0) { Start-DownloadRun $Records }
            continue
        }

        if ($code -eq -5) {
            $pageItems = New-Object System.Collections.ArrayList
            foreach ($it in $slice) {
                $exists = $false
                try { $exists = (Test-Path -LiteralPath $it.Dest) -and ((Get-Item -LiteralPath $it.Dest).Length -gt 0) } catch { }
                if (-not $exists) { [void]$pageItems.Add($it) }
            }
            if ($pageItems.Count -eq 0) { Show-Message 'Every file on this page is already downloaded.' 'Green'; continue }
            Invoke-DownloadItems -Items $pageItems -OutDir $script:Settings.OutDir -Heading ('Downloading {0} file(s) from page {1}' -f $pageItems.Count, ($page + 1))
            continue
        }

        if ($code -ge 0 -and $code -lt $slice.Count) {
            $sel = $code
            $item = $slice[$code]
            $exists = $false
            try { $exists = (Test-Path -LiteralPath $item.Dest) -and ((Get-Item -LiteralPath $item.Dest).Length -gt 0) } catch { }
            if ($exists) { Show-Message ('Already downloaded: ' + $item.Name) 'Green'; continue }
            Invoke-DownloadItems -Items @($item) -OutDir $script:Settings.OutDir -Heading ('Downloading ' + $item.Name)
        }
    }
}

function Start-DownloadFlow {
    $sel = @($script:Selection)
    if ($sel.Count -eq 0) { Show-Message 'Nothing is selected.'; return }
    Show-DownloadBrowser -Records $sel
}

# ----------------------------------------------------------------------------
# main menu
# ----------------------------------------------------------------------------

function Main-Menu {
    $last = 0
    while ($true) {
        $sel = @($script:Selection)
        $unique = @($sel | Group-Object -Property Url).Count

        $items = @(
            ('Browse & download  ({0:N0} files)' -f $unique),
            'Filter by satellite',
            'Filter by year',
            'Filter by date range',
            'Filter by country / territory',
            'Filter by contributor',
            'Filter by record ID',
            'Search all text fields',
            'Clear filters (back to all records)',
            'Settings',
            'Exit'
        )
        $sub = ('  {0:N0} of {1:N0} records selected ({2:N0} unique files)' -f $sel.Count, $script:All.Count, $unique)
        $sub = $sub + "`n" + ('  folder: ' + $script:Settings.OutDir)

        $i = Read-Menu -Title 'Open Weather Archive - audio downloader' -Subtitle $sub -Items $items -Selected $last
        if ($i -lt 0) { return }
        $last = $i

        switch ($i) {
            0  { Start-DownloadFlow }
            1  { Filter-ByValue -Title 'Filter by satellite' -Property 'Satellite' -SortMode 'Count' }
            2  { Filter-ByValue -Title 'Filter by year' -Property 'Year' -SortMode 'NameDesc' }
            3  { Filter-DateRange }
            4  { Filter-ByValue -Title 'Filter by country / territory' -Property 'Country' -SortMode 'Count' }
            5  { Filter-ByValue -Title 'Filter by contributor' -Property 'Contributor' -SortMode 'Count' }
            6  { Filter-ById }
            7  { Filter-Search }
            8  { $script:Selection = $script:All; Show-Message ('Filters cleared. All ' + $script:All.Count + ' records selected.') 'Green' }
            9  { Settings-Menu }
            10 { return }
        }
    }
}

function Main {
    Clear-Screen
    Write-Host ''
    Write-Host '  Open Weather Archive - audio downloader' -ForegroundColor Cyan
    Write-Host '  --------------------------------------' -ForegroundColor DarkGray
    Write-Host ('  ' + $script:AppCredit) -ForegroundColor Green
    Write-Host ''

    $csv = Resolve-CsvPath
    if (-not $csv) {
        Write-Host '  No CSV selected. Nothing to do.' -ForegroundColor Red
        return
    }
    $script:CsvPath = $csv

    Write-Host ('  Reading ' + $csv) -ForegroundColor DarkGray
    try {
        $all = Load-Archive $csv
    } catch {
        Write-Host ('  Could not read the CSV: ' + $_.Exception.Message) -ForegroundColor Red
        return
    }
    if ($all.Count -eq 0) {
        Write-Host '  No audio links found in that CSV.' -ForegroundColor Red
        return
    }

    $script:All = $all
    $script:Selection = $all
    if (-not $script:Settings.OutDir) {
        $script:Settings.OutDir = Join-Path (Split-Path -Parent $csv) 'wav'
    }

    $uniq = @($all | Group-Object -Property Url).Count
    Write-Host ('  Loaded {0:N0} records with audio ({1:N0} unique files).' -f $all.Count, $uniq) -ForegroundColor Green
    Start-Sleep -Milliseconds 800

    Main-Menu

    Clear-Screen
    Write-Host ''
    Write-Host '  Bye.' -ForegroundColor DarkGray
    Write-Host ''
}

if (-not $env:OWDL_NO_MAIN) { Main }


