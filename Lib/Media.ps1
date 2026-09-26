# ==============================================================
#  Lib\Media.ps1 - asennusmedian eheys
#
#  Rakennusvaihe laskee jokaiselle median tiedostolle SHA-256-tiivisteen.
#  WinPE tarkistaa ne ENNEN kuin levyihin kosketaan: jos tikun kopio on
#  rikki, tyhjennyksen jalkeinen asennus epaonnistuisi ja kone jaisi
#  ilman kayttojarjestelmaa.
#
#  Mukana ei ole tiedostoja, joita kayttajan kuuluu muokata tikulla
#  (asetukset, konekohtaiset ajurit, raportit).
# ==============================================================

$script:ManifestName = 'iRequire\manifest.json'
$script:ManifestExclude = @('iRequire\Config\*', 'iRequire\Drivers\*', 'iRequire\Reports\*', 'iRequire\manifest.json')

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path, [scriptblock]$OnProgress)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] (4MB)
        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            [void]$sha.TransformBlock($buf, 0, $n, $null, 0)
            if ($OnProgress) { & $OnProgress $n }
        }
        [void]$sha.TransformFinalBlock($buf, 0, 0)
        return ([BitConverter]::ToString($sha.Hash) -replace '-', '')
    } finally {
        $fs.Dispose()
    }
}

function Test-ManifestExcluded {
    param([Parameter(Mandatory)][string]$Relative)
    foreach ($p in $script:ManifestExclude) { if ($Relative -like $p) { return $true } }
    return $false
}

function New-MediaManifest {
    <# Kirjoittaa manifestin median juureen. Polut ovat suhteellisia ja
       kenoviivoilla, jotta ne toimivat WinPE:ssa milla tahansa kirjaimella. #>
    param([Parameter(Mandatory)][string]$MediaRoot)
    $root = (Resolve-Path -LiteralPath $MediaRoot).Path.TrimEnd('\', '/')
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName)) {
        $rel = $f.FullName.Substring($root.Length + 1).Replace('/', '\')
        if (Test-ManifestExcluded $rel) { continue }
        $files.Add([ordered]@{ Polku = $rel; Koko = [int64]$f.Length; Sha256 = (Get-FileSha256 -Path $f.FullName) })
    }
    $doc = [ordered]@{ Luotu = (Get-Date).ToString('s'); Tiedostot = $files.ToArray() }
    $out = Join-Path $root $script:ManifestName
    $doc | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $out -Encoding UTF8
    return $files.Count
}

function Test-MediaManifest {
    <# Palauttaa listan ongelmista; tyhja lista = media on ehja. #>
    param([Parameter(Mandatory)][string]$MediaRoot)
    $problems = New-Object System.Collections.Generic.List[string]
    $root = $MediaRoot.TrimEnd('\', '/')
    $manifestPath = Join-Path $root $script:ManifestName
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        $problems.Add('manifest.json puuttuu (media rakennettu vanhalla versiolla tai kopioitu kasin)')
        return ,$problems
    }
    $doc = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $entries = @($doc.Tiedostot)
    $total = [int64]0
    foreach ($e in $entries) { $total += [int64]$e.Koko }

    $state = @{ Done = [int64]0; Last = [DateTime]::MinValue }
    $progress = {
        param($n)
        $state.Done += $n
        if (((Get-Date) - $state.Last).TotalSeconds -ge 1) {
            $state.Last = Get-Date
            $pct = if ($total -gt 0) { [int](100.0 * $state.Done / $total) } else { 100 }
            Write-Progress -Activity 'Tarkistetaan tikun eheys' -Status ('{0} %' -f $pct) -PercentComplete ([Math]::Min($pct, 100))
        }
    }
    try {
        foreach ($e in $entries) {
            $p = Join-Path $root ([string]$e.Polku)
            if (-not (Test-Path -LiteralPath $p)) { $problems.Add("puuttuu: $($e.Polku)"); continue }
            $len = (Get-Item -LiteralPath $p).Length
            if ($len -ne [int64]$e.Koko) { $problems.Add(("vaara koko: {0} ({1} != {2})" -f $e.Polku, $len, $e.Koko)); continue }
            try {
                $h = Get-FileSha256 -Path $p -OnProgress $progress
                if ($h -ne [string]$e.Sha256) { $problems.Add("vioittunut: $($e.Polku)") }
            } catch {
                $problems.Add(("lukuvirhe: {0} ({1})" -f $e.Polku, $_.Exception.Message))
            }
        }
    } finally {
        Write-Progress -Activity 'Tarkistetaan tikun eheys' -Completed
    }
    return ,$problems
}
