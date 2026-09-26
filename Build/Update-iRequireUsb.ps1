#requires -Version 5.1
<#
.SYNOPSIS
    Paivittaa valmiin iRequire-tikun skriptit ilman uudelleenrakennusta.

.DESCRIPTION
    Useimmat korjaukset koskevat vain tikulla olevia skripteja (WinPE,
    jalkiasennus, kaytannot). Tama kopioi ne reposta tikulle ja laskee
    eheysmanifestin uudelleen - minuutti koko rakennuksen (30-60 min)
    sijaan. Kayttajan iRequire.json ja tikun ajurit sailyvat.

    Ei paivita asennuskuvaa, boot.wim:ia eika sen sisaista
    Bootstrap.ps1:ta; niihin tarvitaan Build-iRequire.ps1.

.EXAMPLE
    .\Build\Update-iRequireUsb.ps1 -UsbRoot E:
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$UsbRoot)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repo 'Lib\Common.ps1')
. (Join-Path $repo 'Lib\Media.ps1')

$UsbRoot = $UsbRoot.TrimEnd('\', '/')
if ($UsbRoot -match '^[A-Za-z]$') { $UsbRoot += ':' }
$tag = Join-Path $UsbRoot 'iRequire\iRequire.tag'
if (-not (Test-Path -LiteralPath $tag)) { throw "iRequire-tikkua ei loydy: $UsbRoot (puuttuu iRequire\iRequire.tag)" }

Write-Host "Paivitetaan tikku $UsbRoot" -ForegroundColor Cyan
$old = Read-MediaManifest -MediaRoot $UsbRoot
Copy-RepoPayload -RepoRoot $repo -Destination (Join-Path $UsbRoot 'iRequire') -KeepConfig
Set-Content -LiteralPath $tag -Value ('iRequire ' + (Get-Date -Format s) + ' (skriptit paivitetty)') -Encoding ASCII
$count = New-MediaManifest -MediaRoot $UsbRoot -Reuse $old
Write-Host "  manifestissa $count tiedostoa" -ForegroundColor Gray

$problems = Test-MediaManifest -MediaRoot $UsbRoot
if ($problems.Count -gt 0) { throw ('eheystarkistus epaonnistui: ' + ($problems -join '; ')) }
$cfg = @(Test-IRequireConfig -Path (Join-Path $UsbRoot 'iRequire\Config\iRequire.json'))
foreach ($p in $cfg) { Write-Host "  VAROITUS asetustiedosto: $p" -ForegroundColor Yellow }
if ($cfg.Count -gt 0) { Write-Host '  Tikku pysahtyy naihin ennen tyhjennysta. Korjaa iRequire\Config\iRequire.json.' -ForegroundColor Yellow }
Write-Host 'Valmis. Tikun skriptit ovat ajan tasalla.' -ForegroundColor Green
