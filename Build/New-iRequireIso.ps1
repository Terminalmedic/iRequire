#requires -Version 5.1
<#
.SYNOPSIS
    Tekee rakennetusta mediasta ISO-levykuvan (virtuaalikoneet, Ventoy).

.DESCRIPTION
    UEFI-kaynnistys kayttaa efisys_noprompt.bin-tiedostoa, joten ISO ei kysy
    "Press any key to boot from CD" - muuten automaattinen asennus
    pysahtyisi heti alkuun. ISOlta ajettaessa raportit tallentuvat vain
    asennettavalle koneelle, koska ISOon ei voi kirjoittaa.

.EXAMPLE
    .\New-iRequireIso.ps1
#>
[CmdletBinding()]
param(
    [string]$MediaDir = (Join-Path $PSScriptRoot '..\Out\Media'),
    [string]$IsoPath = (Join-Path $PSScriptRoot '..\Out\iRequire.iso'),
    [string]$AdkRoot = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit"
)

$ErrorActionPreference = 'Stop'
$MediaDir = [System.IO.Path]::GetFullPath($MediaDir)
$IsoPath = [System.IO.Path]::GetFullPath($IsoPath)
if (-not (Test-Path -LiteralPath (Join-Path $MediaDir 'iRequire\iRequire.tag'))) {
    throw "Mediaa ei loydy kansiosta $MediaDir. Aja ensin Build-iRequire.ps1."
}

$oscdimg = Join-Path $AdkRoot 'Deployment Tools\amd64\Oscdimg\oscdimg.exe'
if (-not (Test-Path -LiteralPath $oscdimg)) { throw "oscdimg.exe puuttuu: $oscdimg (Windows ADK: Deployment Tools)" }

$etfs = Join-Path $MediaDir 'boot\etfsboot.com'
$efi = Join-Path $MediaDir 'efi\microsoft\boot\efisys_noprompt.bin'
if (-not (Test-Path -LiteralPath $efi)) {
    $efi = Join-Path $AdkRoot 'Deployment Tools\amd64\Oscdimg\efisys_noprompt.bin'
}
foreach ($f in @($etfs, $efi)) { if (-not (Test-Path -LiteralPath $f)) { throw "Puuttuu: $f" } }

$bootData = '2#p0,e,b{0}#pEF,e,b{1}' -f $etfs, $efi
& $oscdimg -m -o -u2 -udfver102 -lIREQUIRE "-bootdata:$bootData" $MediaDir $IsoPath
if ($LASTEXITCODE -ne 0) { throw "oscdimg epaonnistui ($LASTEXITCODE)" }
Write-Host "Valmis: $IsoPath" -ForegroundColor Green
