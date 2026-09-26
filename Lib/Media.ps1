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

function Copy-Ca2023BootFiles {
    <# Vaihtaa median kaynnistystiedostot 'Windows UEFI CA 2023' -allekirjoitettuihin
       (KB5025885, CVE-2023-24932). Sama tiedostojen vaihto kuin Microsoftin
       Make2023BootableMedia.ps1:ssa (KB5053484). Lahteena liitetty boot.wim,
       jossa on 2024-4B tai uudempi paivitys (Windows\Boot\*_EX).
       Palauttaa ISOn EFI-kaynnistyskuvan polun (noprompt jos saatavilla). #>
    param(
        [Parameter(Mandatory)][string]$BootRoot,
        [Parameter(Mandatory)][string]$MediaRoot
    )
    $boot = Join-Path $BootRoot 'Windows\Boot'
    $ex = Join-Path $boot 'EFI_EX'
    $fonts = Join-Path $boot 'FONTS_EX'
    $dvd = Join-Path $boot 'DVD_EX\EFI\en-US'
    foreach ($p in @($ex, $fonts, $dvd)) {
        if (-not (Test-Path -LiteralPath $p)) { throw "boot.wim:sta puuttuu $p (tarvitaan 2024-4B tai uudempi paivitys)" }
    }
    $efiBoot = Join-Path $MediaRoot 'efi\boot'
    $msBoot = Join-Path $MediaRoot 'efi\microsoft\boot'
    New-Item -ItemType Directory -Path $efiBoot, (Join-Path $msBoot 'fonts') -Force | Out-Null

    Copy-Item -LiteralPath (Join-Path $ex 'bootmgfw_EX.efi') -Destination (Join-Path $efiBoot 'bootx64.efi') -Force
    $bootmgr = Join-Path $ex 'bootmgr_EX.efi'
    if (Test-Path -LiteralPath $bootmgr) { Copy-Item -LiteralPath $bootmgr -Destination (Join-Path $MediaRoot 'bootmgr.efi') -Force }
    foreach ($f in @(Get-ChildItem -LiteralPath $fonts -File | Where-Object { $_.Name -like '*_EX.ttf' })) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path (Join-Path $msBoot 'fonts') ($f.Name -replace '_EX', '')) -Force
    }
    Copy-Item -LiteralPath (Join-Path $dvd 'efisys_EX.bin') -Destination (Join-Path $msBoot 'efisys_ex.bin') -Force
    $noprompt = Join-Path $dvd 'efisys_noprompt_EX.bin'
    if (Test-Path -LiteralPath $noprompt) {
        Copy-Item -LiteralPath $noprompt -Destination (Join-Path $msBoot 'efisys_noprompt_ex.bin') -Force
        return (Join-Path $msBoot 'efisys_noprompt_ex.bin')
    }
    return (Join-Path $msBoot 'efisys_ex.bin')
}

function Get-IsoEfiBootImage {
    <# Valitsee ISOn EFI-kaynnistyskuvan. 2023-mediaan ei saa kayttaa 2011-kuvaa,
       koska kuva sisaltaa oman kaynnistyksenhallintansa. Noprompt ensin:
       muuten ISO jaa odottamaan nappainta ("Press any key to boot from CD"). #>
    param([Parameter(Mandatory)][string]$MediaRoot, [string]$OscdimgDir = '')
    $ms = Join-Path $MediaRoot 'efi\microsoft\boot'
    $is2023 = Test-Path -LiteralPath (Join-Path $ms 'efisys_ex.bin')
    $names = if ($is2023) { @('efisys_noprompt_ex.bin', 'efisys_ex.bin') } else { @('efisys_noprompt.bin', 'efisys.bin') }
    foreach ($n in $names) {
        foreach ($dir in @($ms, $OscdimgDir)) {
            if (-not $dir) { continue }
            $p = Join-Path $dir $n
            if (Test-Path -LiteralPath $p) {
                return [pscustomobject]@{ Path = $p; Ca2023 = $is2023; NoPrompt = ($n -like '*noprompt*') }
            }
        }
    }
    throw "EFI-kaynnistyskuvaa ei loydy ($($names -join ', '))"
}

function Select-ImageEdition {
    <# Ensimmainen kuvio, joka vastaa jotain kuvaa, voittaa (kuvioiden
       jarjestys = mieltymys). '*Pro' ei vastaa "Pro N"- tai "Pro Education"
       -versioita, koska kuvio loppuu sanaan Pro. #>
    param([Parameter(Mandatory)]$Images, [Parameter(Mandatory)][string[]]$Patterns)
    foreach ($pattern in $Patterns) {
        $hit = @($Images | Where-Object { $_.ImageName -like $pattern }) | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}
