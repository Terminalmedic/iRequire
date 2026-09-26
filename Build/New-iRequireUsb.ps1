#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Kirjoittaa rakennetun iRequire-median USB-tikulle.

.DESCRIPTION
    Tikku tyhjennetaan ja siihen tehdaan yksi FAT32-osio (MBR, aktiivinen),
    joka kaynnistyy seka UEFI- etta BIOS-koneissa. FAT32:n takia osio on
    enintaan 32 Gt; loput tikusta jaa kayttamatta.

.EXAMPLE
    Get-Disk | Where-Object BusType -eq USB       # katso tikun numero
    .\New-iRequireUsb.ps1 -DiskNumber 3
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$DiskNumber,
    [string]$MediaDir = (Join-Path $PSScriptRoot '..\Out\Media'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$MediaDir = [System.IO.Path]::GetFullPath($MediaDir)
if (-not (Test-Path -LiteralPath (Join-Path $MediaDir 'iRequire\iRequire.tag'))) {
    throw "Mediaa ei loydy kansiosta $MediaDir. Aja ensin Build-iRequire.ps1."
}

$disk = Get-Disk -Number $DiskNumber
if ($disk.BusType -ne 'USB') { throw "Levy $DiskNumber ei ole USB-levy ($($disk.BusType)). Keskeytetaan." }
if ($disk.IsBoot -or $disk.IsSystem) { throw "Levy $DiskNumber on taman koneen kaynnistyslevy. Keskeytetaan." }

Write-Host ('Levy {0}: {1}, {2:N1} Gt' -f $disk.Number, $disk.FriendlyName, ($disk.Size / 1GB)) -ForegroundColor Yellow
if (-not $Force) {
    $answer = Read-Host "Kaikki levyn $DiskNumber tiedot poistetaan. Kirjoita levyn numero jatkaaksesi"
    if ($answer -ne [string]$DiskNumber) { throw 'Peruttu.' }
}

Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue
Initialize-Disk -Number $DiskNumber -PartitionStyle MBR -ErrorAction SilentlyContinue
$size = [Math]::Min($disk.Size - 1MB, 32GB - 1MB)
$part = New-Partition -DiskNumber $DiskNumber -Size $size -IsActive -AssignDriveLetter
$vol = $part | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'IREQUIRE' -Confirm:$false
$root = "$($vol.DriveLetter):\"

& robocopy.exe $MediaDir $root /E /NFL /NDL /NJH /NJS /R:1 /W:1
if ($LASTEXITCODE -ge 8) { throw "Kopiointi epaonnistui (robocopy $LASTEXITCODE)" }

# BIOS-koneita varten kaynnistyskoodi. UEFI ei tarvitse tata.
$bootsect = Join-Path $MediaDir 'boot\bootsect.exe'
if (Test-Path -LiteralPath $bootsect) { & $bootsect /nt60 "$($vol.DriveLetter):" /mbr | Out-Null }

Write-Host "Valmis: $root" -ForegroundColor Green
Write-Host 'Konekohtaiset ajurit voi lisata tikun kansioon iRequire\Drivers.' -ForegroundColor Gray
