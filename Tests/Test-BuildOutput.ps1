#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Tarkistaa Build-iRequire.ps1:n tuottaman median sisaltapain.

.DESCRIPTION
    Ajetaan rakennuksen jalkeen (CI:n build-tyonkulku tai kasin). Kuvat
    liitetaan vain luku -tilassa, eika mitaan muuteta. Tarkistaa etta:
      - boot.wim:ssa on yksi kaynnistettava kuva, PowerShell, WMI-
        tallennuskomennot, iRequiren kaynnistin ja winpeshl.ini
      - asennuskuvassa on yksi versio, .NET 3.5, SMB1 poissa ja
        oletuskayttajan asetukset
      - iRequire-kansio, merkki ja eheysmanifesti ovat kunnossa
#>
[CmdletBinding()]
param(
    [string]$MediaDir = (Join-Path $PSScriptRoot '..\Out\Media'),
    [string]$MountDir = (Join-Path $env:TEMP 'irequire-tarkistus')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Lib\Common.ps1')
. (Join-Path $root 'Lib\Media.ps1')
function Write-IRequireLog { param([string]$Message, [string]$Level) Write-Host "  $Message" }

$MediaDir = [System.IO.Path]::GetFullPath($MediaDir)
$failures = New-Object System.Collections.Generic.List[string]
function Check {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; Write-Host "  OK    $Name" -ForegroundColor Green }
    catch { $failures.Add("$Name - $($_.Exception.Message)"); Write-Host "  VIRHE $Name - $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }

Write-Host ''
Write-Host "=== Rakennetun median tarkistus: $MediaDir ===" -ForegroundColor Cyan
if (Test-Path -LiteralPath $MountDir) { Remove-Item -LiteralPath $MountDir -Recurse -Force }
New-Item -ItemType Directory -Path $MountDir -Force | Out-Null

Check 'iRequire-kansio, merkki ja eheysmanifesti' {
    Assert-True (Test-Path -LiteralPath (Join-Path $MediaDir 'iRequire\iRequire.tag')) 'iRequire.tag puuttuu'
    foreach ($f in @('WinPE\Start-iRequire.ps1', 'WinPE\Disk.ps1', 'WinPE\Deploy.ps1', 'PostInstall\Invoke-PostInstall.ps1',
                     'Lib\Common.ps1', 'Lib\Stages.ps1', 'Lib\Tuning.ps1', 'Lib\Media.ps1', 'Lib\Display.ps1', 'Lib\Readiness.ps1',
                     'Unattend\unattend.template.xml', 'Config\iRequire.json', 'Policies\machine.txt')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $MediaDir "iRequire\$f")) "puuttuu iRequire\$f"
    }
    $problems = Test-MediaManifest -MediaRoot $MediaDir
    Assert-True ($problems.Count -eq 0) ('manifesti: ' + ($problems -join '; '))
}

Check 'Kaynnistystiedostojen Secure Boot -varmenne (KB5025885)' {
    $ca2023 = Test-Path -LiteralPath (Join-Path $MediaDir 'efi\microsoft\boot\efisys_ex.bin')
    $expect = if ($ca2023) { 'Windows UEFI CA 2023' } else { 'Microsoft Windows Production PCA 2011' }
    foreach ($f in @('efi\boot\bootx64.efi')) {
        $sig = Get-AuthenticodeSignature -FilePath (Join-Path $MediaDir $f)
        Assert-True ($null -ne $sig.SignerCertificate) "$f ei ole allekirjoitettu"
        Assert-True ($sig.SignerCertificate.Issuer -match [regex]::Escape($expect)) ("{0}: myontaja '{1}', odotettiin '{2}'" -f $f, $sig.SignerCertificate.Issuer, $expect)
    }
    Write-Host ("          {0}" -f $expect) -ForegroundColor DarkGray
}

Check 'Ei asennusohjelman omia vastaustiedostoja' {
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $MediaDir 'autounattend.xml'))) 'autounattend.xml juuressa'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $MediaDir 'sources\ei.cfg'))) 'ei.cfg jai'
}

Check 'Asennuskuva: yksi versio, FAT32:lle sopiva' {
    $swm = Join-Path $MediaDir 'sources\install.swm'
    $wim = Join-Path $MediaDir 'sources\install.wim'
    Assert-True ((Test-Path -LiteralPath $swm) -or (Test-Path -LiteralPath $wim)) 'install.swm/wim puuttuu'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $MediaDir 'sources\install.esd'))) 'install.esd jai'
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $MediaDir 'sources') -Filter 'install*')) {
        Assert-True ($f.Length -lt 4GB) "$($f.Name) on yli 4 Gt (ei mahdu FAT32:lle)"
    }
    $img = if (Test-Path -LiteralPath $swm) { $swm } else { $wim }
    $images = @(Get-WindowsImage -ImagePath $img)
    Assert-True ($images.Count -eq 1) "kuvia $($images.Count), odotettiin 1"
    Write-Host ("          {0}" -f $images[0].ImageName) -ForegroundColor DarkGray
}

Check 'boot.wim: PowerShell, tallennuskomennot, kaynnistin' {
    $boot = Join-Path $MediaDir 'sources\boot.wim'
    $images = @(Get-WindowsImage -ImagePath $boot)
    Assert-True ($images.Count -eq 1) "boot.wim:ssa $($images.Count) kuvaa, odotettiin 1"
    $m = Join-Path $MountDir 'boot'
    New-Item -ItemType Directory -Path $m -Force | Out-Null
    Mount-WindowsImage -ImagePath $boot -Index 1 -Path $m -ReadOnly | Out-Null
    try {
        $sys32 = Join-Path $m 'Windows\System32'
        foreach ($f in @('WindowsPowerShell\v1.0\powershell.exe', 'iRequire-Bootstrap.ps1', 'winpeshl.ini', 'diskpart.exe', 'bcdboot.exe', 'Dism.exe')) {
            Assert-True (Test-Path -LiteralPath (Join-Path $sys32 $f)) "puuttuu System32\$f"
        }
        $storage = Get-ChildItem -LiteralPath (Join-Path $sys32 'WindowsPowerShell\v1.0\Modules') -Directory | ForEach-Object { $_.Name }
        Assert-True ($storage -contains 'Storage') 'Storage-moduuli (Get-Disk) puuttuu'
        $ini = Get-Content -LiteralPath (Join-Path $sys32 'winpeshl.ini') -Raw
        Assert-True ($ini -match 'iRequire-Bootstrap\.ps1') 'winpeshl.ini ei kaynnista iRequirea'
        $pkgs = @(Get-WindowsPackage -Path $m | ForEach-Object { $_.PackageName })
        foreach ($oc in @('WinPE-PowerShell', 'WinPE-StorageWMI', 'WinPE-NetFx', 'WinPE-WMI')) {
            Assert-True (@($pkgs | Where-Object { $_ -like "*$oc*" }).Count -gt 0) "$oc puuttuu"
        }
    } finally {
        Dismount-WindowsImage -Path $m -Discard | Out-Null
    }
}

Check 'Asennuskuva: .NET 3.5, SMB1 pois, oletuskayttajan asetukset' {
    $swm = Join-Path $MediaDir 'sources\install.swm'
    $m = Join-Path $MountDir 'install'
    New-Item -ItemType Directory -Path $m -Force | Out-Null
    $image = Join-Path $MediaDir 'sources\install.wim'
    if (Test-Path -LiteralPath $swm) {
        # Pilkottua kuvaa ei voi liittaa (DISM virhe 87), joten palat
        # yhdistetaan ensin valiaikaiseksi kuvaksi. Asennus itse kayttaa
        # /Apply-Image /SWMFile, joka tukee palasia suoraan.
        $image = Join-Path $MountDir 'yhdistetty.wim'
        Export-WindowsImage -SourceImagePath $swm -SplitImageFilePattern (Join-Path $MediaDir 'sources\install*.swm') `
            -SourceIndex 1 -DestinationImagePath $image -CompressionType none | Out-Null
    }
    Mount-WindowsImage -ImagePath $image -Index 1 -Path $m -ReadOnly | Out-Null
    try {
        $netfx = Get-WindowsOptionalFeature -Path $m -FeatureName NetFx3
        # Offline-kuvassa tila on EnablePending: viimeistely tapahtuu Windowsin
        # ensimmaisella kaynnistyksella. Paasta paahan -testi tarkistaa lopputilan.
        Assert-True ($netfx.State -in @('Enabled', 'EnablePending')) ".NET 3.5: $($netfx.State)"
        $smb = Get-WindowsOptionalFeature -Path $m -FeatureName SMB1Protocol -ErrorAction SilentlyContinue
        Assert-True (-not $smb -or $smb.State -ne 'Enabled') 'SMB1 on paalla'

        $hive = 'HKU\iRequireTarkistus'
        & reg.exe load $hive (Join-Path $m 'Users\Default\NTUSER.DAT') | Out-Null
        try {
            $r = 'Registry::HKEY_USERS\iRequireTarkistus'
            $expect = @(
                @{ Key = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'; Name = 'StartupDelayInMSec'; Value = 0 },
                @{ Key = 'System\GameConfigStore'; Name = 'GameDVR_Enabled'; Value = 0 },
                @{ Key = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'HideFileExt'; Value = 0 },
                @{ Key = 'Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled'; Value = 1 },
                @{ Key = 'Control Panel\Mouse'; Name = 'MouseSpeed'; Value = '0' }
            )
            foreach ($e in $expect) {
                $v = (Get-ItemProperty -LiteralPath (Join-Path $r $e.Key) -ErrorAction Stop).($e.Name)
                Assert-True ("$v" -eq "$($e.Value)") ("{0}\{1} = '{2}', odotettiin '{3}'" -f $e.Key, $e.Name, $v, $e.Value)
            }
            $run = Get-ItemProperty -LiteralPath (Join-Path $r 'Software\Microsoft\Windows\CurrentVersion\Run') -ErrorAction SilentlyContinue
            Assert-True (-not $run -or -not $run.OneDriveSetup) 'OneDriveSetup jai Run-avaimeen'
        } finally {
            [GC]::Collect()
            Start-Sleep -Seconds 1
            & reg.exe unload $hive | Out-Null
        }

        $prov = @(Get-AppxProvisionedPackage -Path $m | ForEach-Object { $_.DisplayName })
        Write-Host ("          esiasennettuja sovelluksia: {0}" -f ($prov -join ', ')) -ForegroundColor DarkGray
        foreach ($bad in @('Microsoft.WindowsStore', 'Microsoft.GamingApp', 'Microsoft.XboxGamingOverlay', 'Microsoft.BingNews', 'Clipchamp.Clipchamp')) {
            Assert-True ($prov -notcontains $bad) "$bad on yha esiasennettu"
        }
    } finally {
        Dismount-WindowsImage -Path $m -Discard | Out-Null
    }
}

Remove-Item -LiteralPath $MountDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host ("{0} tarkistusta epaonnistui" -f $failures.Count) -ForegroundColor Red
    exit 1
}
Write-Host 'Media kunnossa.' -ForegroundColor Green
