#requires -Version 5.1
<#
.SYNOPSIS
    Asettaa rakennetun median asetukset paasta paahan -testia varten.

.DESCRIPTION
    Ainoa ero tuotantomediaan on asetustiedosto, joka on tarkoituksella
    eheysmanifestin ulkopuolella (kayttaja saa muokata sita tikulla).
    Nain testattava ISO syntyy samalla tyokalulla kuin oikea.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MediaDir,
    [int]$UpdateRounds = 0
)
$ErrorActionPreference = 'Stop'
$path = Join-Path $MediaDir 'iRequire\Config\iRequire.json'
$c = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
$c.Tyhjennys.LaskuriSekuntia = 5
$c.Tyhjennys.MinimikokoGt = 20
$c.Tyhjennys.OdotaVerkkovirtaa = $false
$c.Paivitykset.MaksimiKierrokset = $UpdateRounds
$c.Paivitykset.VerkonOdotusMinuuttia = 3
$c.Asennus.LopuksiSammutus = $true
$c.Asennus.LokiSarjaporttiin = $true
$c | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
Write-Host "Testiasetukset: $path"
