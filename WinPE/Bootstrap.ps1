#requires -Version 5.1
<#
.SYNOPSIS
    Leivotaan boot.wim:iin. Etsii iRequire-tikun ja kaynnistaa sen skriptin.

.DESCRIPTION
    Varsinainen logiikka pidetaan tikulla eika kuvan sisalla, jotta
    skripteja voi korjata tikulle ilman boot.wim:n uudelleenrakennusta.
#>
$ErrorActionPreference = 'Continue'
$Host.UI.RawUI.WindowTitle = 'iRequire'

$root = $null
# USB-levyn tunnistus voi kestaa hetken wpeinitin jalkeen.
for ($try = 0; $try -lt 30 -and -not $root; $try++) {
    foreach ($l in [char[]]'CDEFGHIJKLMNOPQRSTUVWYZ') {
        if (Test-Path -LiteralPath "${l}:\iRequire\iRequire.tag") { $root = "${l}:"; break }
    }
    if (-not $root) { Start-Sleep -Seconds 1 }
}

if (-not $root) {
    Write-Host 'iRequire-tikkua ei loytynyt (iRequire\iRequire.tag puuttuu).' -ForegroundColor Red
    Write-Host 'Avataan komentokehote. "wpeutil shutdown" sammuttaa.' -ForegroundColor Yellow
    & cmd.exe
    exit 1
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$root\iRequire\WinPE\Start-iRequire.ps1" -UsbRoot $root

# Kun taman skriptin ajo loppuu, WinPE kaynnistyy uudelleen (winpeshl). Jos
# Start-iRequire kaatui odottamatta (esim. jasennysvirhe), uudelleenkaynnistys
# kaynnistaisi saman tikun alusta - pysahdytaan sen sijaan ja naytetaan syy.
# Onnistunut ajo on jo pyytanyt uudelleenkaynnistyksen itse (koodi 0).
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host ("iRequire pysahtyi odottamatta (koodi {0})." -f $LASTEXITCODE) -ForegroundColor Red
    Write-Host ("Loki: {0}\iRequire\Reports tai X:\iRequire\Reports" -f $root) -ForegroundColor Yellow
    Write-Host 'Kone ei kaynnisty uudelleen itsestaan. Komentokehote avautuu; sulkeminen sammuttaa koneen.' -ForegroundColor Yellow
    & cmd.exe
    & wpeutil.exe shutdown
}
