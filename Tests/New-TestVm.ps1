#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Luo Hyper-V-testikoneen, jolla koko iRequire-ketju ajetaan ennen
    ensimmaista oikeaa konetta.

.DESCRIPTION
    Kone saa kaksi levya, joille kirjoitetaan valmiiksi satunnaista dataa,
    jotta tyhjennyksen varmistus testautuu oikeasti (tyhjan levyn
    "tyhjentaminen" menisi lapi aina). ISO jaa asemaan tarkoituksella:
    asennuksen jalkeen kone kaynnistyy taas ISOlta, jolloin nahdaan etta
    uudelleentyhjennyksen esto toimii.

    Levyt ovat dynaamisia, mutta ylikirjoitus nollilla kasvattaa ne
    taysikokoisiksi: varaa isannalle noin 80 Gt tilaa.

    Tarkista testin jalkeen:
      - tyhjennystodistus: koneen C:\iRequire\Reports
      - WinPE:n loki: C:\iRequire\Logs\winpe.log
      - jalkiasennus: C:\iRequire\Logs\postinstall.log ja yhteenveto.txt
      - gpedit.msc: Hallintamallit > Windows-osat > Tiedonkeruu = kaytossa, 0

.EXAMPLE
    .\Build\New-iRequireIso.ps1
    .\Tests\New-TestVm.ps1 -IsoPath .\Out\iRequire.iso
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$IsoPath,
    [string]$Name = 'iRequire-testi',
    [string]$VmRoot = (Join-Path $PSScriptRoot '..\Out\VM'),
    [string]$SwitchName = 'Default Switch',
    [int]$OsDiskGb = 64,
    [int]$DataDiskGb = 8
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
    throw 'Hyper-V ei ole kaytossa. Ota kayttoon: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All'
}
$IsoPath = (Resolve-Path -LiteralPath $IsoPath).Path
$VmRoot = [System.IO.Path]::GetFullPath($VmRoot)
if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "Virtuaalikone $Name on jo olemassa. Poista se ensin: Remove-VM $Name -Force" }
New-Item -ItemType Directory -Path $VmRoot -Force | Out-Null

function New-SeededDisk {
    <# Dynaaminen VHDX, jolle kirjoitetaan NTFS-osio ja satunnaista dataa. #>
    param([string]$Path, [int]$SizeGb, [string]$Label)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    New-VHD -Path $Path -SizeBytes ([int64]$SizeGb * 1GB) -Dynamic | Out-Null
    $disk = Mount-VHD -Path $Path -Passthru | Get-Disk
    try {
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT
        $vol = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter |
            Format-Volume -FileSystem NTFS -NewFileSystemLabel $Label -Confirm:$false
        $root = "$($vol.DriveLetter):\"
        $rnd = New-Object System.Random
        $buf = New-Object byte[] (1MB)
        for ($i = 0; $i -lt 64; $i++) {
            $rnd.NextBytes($buf)
            [System.IO.File]::WriteAllBytes((Join-Path $root ("salainen-{0:D3}.bin" -f $i)), $buf)
        }
        New-Item -ItemType Directory -Path (Join-Path $root 'Users\testikayttaja') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'Users\testikayttaja\muistiinpano.txt') -Value 'Taman ei pitaisi selvita tyhjennyksesta.'
    } finally {
        Dismount-VHD -Path $Path
    }
}

$osDisk = Join-Path $VmRoot "$Name-os.vhdx"
$dataDisk = Join-Path $VmRoot "$Name-data.vhdx"
Write-Host 'Luodaan levyt ja kirjoitetaan niille testidataa...'
New-SeededDisk -Path $osDisk -SizeGb $OsDiskGb -Label 'VANHA-C'
New-SeededDisk -Path $dataDisk -SizeGb $DataDiskGb -Label 'VANHA-D'

$vm = New-VM -Name $Name -Generation 2 -MemoryStartupBytes 4GB -VHDPath $osDisk -Path $VmRoot
Set-VMProcessor -VM $vm -Count 2
Set-VMMemory -VM $vm -DynamicMemoryEnabled $false
Add-VMHardDiskDrive -VM $vm -Path $dataDisk
$dvd = Add-VMDvdDrive -VM $vm -Path $IsoPath -Passthru
Set-VMFirmware -VM $vm -FirstBootDevice $dvd -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
Set-VMKeyProtector -VM $vm -NewLocalKeyProtector
Enable-VMTPM -VM $vm
if (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue) {
    Connect-VMNetworkAdapter -VMName $Name -SwitchName $SwitchName
} else {
    Write-Warning "Verkkokytkinta '$SwitchName' ei ole: paivitysvaihe ohittuu ilman verkkoa."
}

Start-VM -VM $vm
& vmconnect.exe localhost $Name
Write-Host "Kaynnistetty. Poista testin jalkeen: Remove-VM $Name -Force; Remove-Item '$VmRoot' -Recurse" -ForegroundColor Green
