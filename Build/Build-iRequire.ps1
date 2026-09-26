#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Rakentaa iRequire-asennusmedian virallisesta Windows-ISOsta.

.DESCRIPTION
    Kaikki raskas tyo tehdaan tassa kerran, eika jokaisella asennuskerralla:
      1. Valittu versio (oletus IoT Enterprise LTSC) irrotetaan omaksi kuvakseen
      2. Build\Updates-kansion paivitykset (.msu/.cab) lisataan kuvaan
      3. Build\Drivers-kansion ajurit lisataan kuvaan
      4. Turhat sovellukset ja ominaisuudet poistetaan jo kuvasta
      5. Oletuskayttajan asetukset kirjoitetaan kuvaan
      6. boot.wim:iin lisataan PowerShell ja iRequiren kaynnistin
      7. install.wim pilkotaan FAT32:lle sopiviksi paloiksi

    Vaatii Windows 10/11 -koneen, jossa on Windows ADK ja sen WinPE-lisaosa
    (samaa versiota kuin ISO, esim. 24H2 / 26100).

.EXAMPLE
    .\Build-iRequire.ps1 -IsoPath D:\ISO\ltsc2024.iso
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$IsoPath,
    [string]$WorkDir = (Join-Path $PSScriptRoot '..\Out'),
    [string[]]$Edition = @('*IoT Enterprise LTSC*', '*Enterprise LTSC*', '*Pro'),
    [string]$AdkRoot = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit",
    [switch]$SkipLgpoDownload
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repo 'Lib\Common.ps1')

$WorkDir = [System.IO.Path]::GetFullPath($WorkDir)
$media = Join-Path $WorkDir 'Media'
$mount = Join-Path $WorkDir 'Mount'
$tmp = Join-Path $WorkDir 'Temp'
Start-Log -Path (Join-Path $WorkDir 'build.log')

foreach ($d in @($WorkDir, $mount, $tmp)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
if (Test-Path -LiteralPath $media) { Remove-Item -LiteralPath $media -Recurse -Force }

$debloat = Get-Content -LiteralPath (Join-Path $repo 'Policies\Debloat.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function Invoke-Checked {
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe palautti koodin $LASTEXITCODE" }
}

# --------------------------------------------------------------
Write-IRequireLog '1/8 Kopioidaan ISO'
# --------------------------------------------------------------
$iso = Mount-DiskImage -ImagePath (Resolve-Path $IsoPath).Path -PassThru
try {
    $isoRoot = ($iso | Get-Volume).DriveLetter + ':\'
    & robocopy.exe $isoRoot $media /E /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy epaonnistui ($LASTEXITCODE)" }
} finally {
    Dismount-DiskImage -ImagePath $iso.ImagePath | Out-Null
}
Get-ChildItem -LiteralPath $media -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }

# --------------------------------------------------------------
Write-IRequireLog '2/8 Valitaan versio'
# --------------------------------------------------------------
$src = @('install.wim', 'install.esd') | ForEach-Object { Join-Path $media "sources\$_" } |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $src) { throw 'ISOsta ei loydy install.wim/.esd -tiedostoa' }

$images = @(Get-WindowsImage -ImagePath $src)
$images | ForEach-Object { Write-IRequireLog ("  indeksi {0}: {1}" -f $_.ImageIndex, $_.ImageName) }
$chosen = $null
foreach ($pattern in $Edition) {
    $chosen = $images | Where-Object { $_.ImageName -like $pattern } | Select-Object -First 1
    if ($chosen) { break }
}
if (-not $chosen) { throw ('Yksikaan versio ei vastaa kuvioita: ' + ($Edition -join ', ')) }
Write-IRequireLog ("Valittu: {0} (indeksi {1})" -f $chosen.ImageName, $chosen.ImageIndex) 'Ok'

$wim = Join-Path $tmp 'install.wim'
if (Test-Path -LiteralPath $wim) { Remove-Item -LiteralPath $wim -Force }
Export-WindowsImage -SourceImagePath $src -SourceIndex $chosen.ImageIndex -DestinationImagePath $wim -CompressionType max | Out-Null
Remove-Item -LiteralPath $src -Force

# --------------------------------------------------------------
Write-IRequireLog '3/8 Muokataan asennuskuvaa'
# --------------------------------------------------------------
Mount-WindowsImage -ImagePath $wim -Index 1 -Path $mount | Out-Null
$saved = $false
try {
    $updates = @(Get-ChildItem -LiteralPath (Join-Path $repo 'Build\Updates') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.msu', '.cab' } | Sort-Object Name)
    foreach ($u in $updates) {
        Write-IRequireLog "  paivitys: $($u.Name)"
        Add-WindowsPackage -Path $mount -PackagePath $u.FullName | Out-Null
    }

    $drivers = Join-Path $repo 'Build\Drivers'
    if (Get-ChildItem -LiteralPath $drivers -Recurse -Filter *.inf -ErrorAction SilentlyContinue | Select-Object -First 1) {
        Write-IRequireLog '  ajurit: Build\Drivers'
        Add-WindowsDriver -Path $mount -Driver $drivers -Recurse | Out-Null
    }

    $prov = @(Get-AppxProvisionedPackage -Path $mount)
    foreach ($pattern in $debloat.Appx) {
        foreach ($p in @($prov | Where-Object { $_.DisplayName -like $pattern })) {
            Write-IRequireLog "  poistetaan: $($p.DisplayName)"
            Remove-AppxProvisionedPackage -Path $mount -PackageName $p.PackageName | Out-Null
        }
    }
    $caps = @(Get-WindowsCapability -Path $mount | Where-Object { $_.State -eq 'Installed' })
    foreach ($pattern in $debloat.Kyvyt) {
        foreach ($c in @($caps | Where-Object { $_.Name -like $pattern })) {
            Write-IRequireLog "  poistetaan ominaisuus: $($c.Name)"
            try { Remove-WindowsCapability -Path $mount -Name $c.Name | Out-Null }
            catch { Write-IRequireLog ("  {0}: {1}" -f $c.Name, $_.Exception.Message) 'Varoitus' }
        }
    }
    foreach ($f in $debloat.Ominaisuudet) {
        $feat = Get-WindowsOptionalFeature -Path $mount -FeatureName $f -ErrorAction SilentlyContinue
        if ($feat -and $feat.State -eq 'Enabled') {
            Write-IRequireLog "  pois kaytosta: $f"
            Disable-WindowsOptionalFeature -Path $mount -FeatureName $f | Out-Null
        }
    }

    Write-IRequireLog '  oletuskayttajan asetukset'
    $hive = 'HKU\iRequireDefault'
    Invoke-Checked reg.exe @('load', $hive, (Join-Path $mount 'Users\Default\NTUSER.DAT'))
    try {
        foreach ($e in (Read-PolicyFile -Path (Join-Path $repo 'Policies\defaultuser.txt'))) {
            Set-PolicyEntry -Entry $e -Root 'Registry::HKEY_USERS\iRequireDefault'
        }
    } finally {
        [GC]::Collect()
        Start-Sleep -Seconds 1
        Invoke-Checked reg.exe @('unload', $hive)
    }

    if ($updates.Count -gt 0) {
        Write-IRequireLog '  siivotaan korvautuneet komponentit'
        Invoke-Checked dism.exe @("/Image:$mount", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase')
    }
    Dismount-WindowsImage -Path $mount -Save | Out-Null
    $saved = $true
} finally {
    if (-not $saved) { Dismount-WindowsImage -Path $mount -Discard | Out-Null }
}

# --------------------------------------------------------------
Write-IRequireLog '4/8 Pakataan ja pilkotaan asennuskuva'
# --------------------------------------------------------------
$final = Join-Path $tmp 'install-final.wim'
if (Test-Path -LiteralPath $final) { Remove-Item -LiteralPath $final -Force }
Export-WindowsImage -SourceImagePath $wim -SourceIndex 1 -DestinationImagePath $final -CompressionType max | Out-Null
Remove-Item -LiteralPath $wim -Force
if ((Get-Item -LiteralPath $final).Length -gt 3.9GB) {
    # FAT32 ei salli yli 4 Gt:n tiedostoja.
    Split-WindowsImage -ImagePath $final -SplitImagePath (Join-Path $media 'sources\install.swm') -FileSize 3800 | Out-Null
    Remove-Item -LiteralPath $final -Force
} else {
    Move-Item -LiteralPath $final -Destination (Join-Path $media 'sources\install.wim')
}

# --------------------------------------------------------------
Write-IRequireLog '5/8 Muokataan kaynnistyskuvaa (boot.wim)'
# --------------------------------------------------------------
$ocRoot = Join-Path $AdkRoot 'Windows Preinstallation Environment\amd64\WinPE_OCs'
if (-not (Test-Path -LiteralPath $ocRoot)) { throw "WinPE-lisaosaa ei loydy: $ocRoot. Asenna Windows ADK + WinPE add-on." }

$bootWim = Join-Path $media 'sources\boot.wim'
$bootInfo = Get-WindowsImage -ImagePath $bootWim -Index 2
$lang = (@($bootInfo.Languages)[0] -replace '\s.*$', '')   # "en-US (Default)" -> "en-US"
Mount-WindowsImage -ImagePath $bootWim -Index 2 -Path $mount | Out-Null
$saved = $false
try {
    # Jarjestys on merkitseva: PowerShell vaatii NetFx:n, joka vaatii WMI:n.
    foreach ($oc in @('WinPE-WMI', 'WinPE-NetFx', 'WinPE-Scripting', 'WinPE-PowerShell',
                      'WinPE-StorageWMI', 'WinPE-DismCmdlets')) {
        $cab = Join-Path $ocRoot "$oc.cab"
        if (-not (Test-Path -LiteralPath $cab)) { throw "Puuttuu: $cab" }
        Write-IRequireLog "  $oc"
        Add-WindowsPackage -Path $mount -PackagePath $cab | Out-Null
        $langCab = Join-Path $ocRoot "$lang\${oc}_$lang.cab"
        if (Test-Path -LiteralPath $langCab) { Add-WindowsPackage -Path $mount -PackagePath $langCab | Out-Null }
    }

    $peDrivers = Join-Path $repo 'Build\Drivers\WinPE'
    if (Get-ChildItem -LiteralPath $peDrivers -Recurse -Filter *.inf -ErrorAction SilentlyContinue | Select-Object -First 1) {
        Write-IRequireLog '  WinPE-ajurit: Build\Drivers\WinPE'
        Add-WindowsDriver -Path $mount -Driver $peDrivers -Recurse | Out-Null
    }

    $sys32 = Join-Path $mount 'Windows\System32'
    Copy-Item -LiteralPath (Join-Path $repo 'WinPE\Bootstrap.ps1') -Destination (Join-Path $sys32 'iRequire-Bootstrap.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $repo 'WinPE\winpeshl.ini') -Destination (Join-Path $sys32 'winpeshl.ini') -Force

    Dismount-WindowsImage -Path $mount -Save | Out-Null
    $saved = $true
} finally {
    if (-not $saved) { Dismount-WindowsImage -Path $mount -Discard | Out-Null }
}
# Ensimmaista indeksia (WinPE ilman asennusohjelmaa) ei tarvita, pakataan pienemmaksi.
$bootNew = Join-Path $tmp 'boot.wim'
if (Test-Path -LiteralPath $bootNew) { Remove-Item -LiteralPath $bootNew -Force }
Export-WindowsImage -SourceImagePath $bootWim -SourceIndex 2 -DestinationImagePath $bootNew -CompressionType max -Setbootable | Out-Null
Move-Item -LiteralPath $bootNew -Destination $bootWim -Force

# --------------------------------------------------------------
Write-IRequireLog '6/8 LGPO.exe (Microsoft Security Compliance Toolkit)'
# --------------------------------------------------------------
$tools = Join-Path $repo 'Tools'
New-Item -ItemType Directory -Path $tools -Force | Out-Null
$lgpo = Join-Path $tools 'LGPO.exe'
if (-not (Test-Path -LiteralPath $lgpo) -and -not $SkipLgpoDownload) {
    try {
        $zip = Join-Path $tmp 'LGPO.zip'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri 'https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip' -OutFile $zip
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tmp 'LGPO') -Force
        $exe = Get-ChildItem -LiteralPath (Join-Path $tmp 'LGPO') -Recurse -Filter LGPO.exe | Select-Object -First 1
        $sig = Get-AuthenticodeSignature -FilePath $exe.FullName
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
            throw "allekirjoitus ei kelpaa ($($sig.Status))"
        }
        Copy-Item -LiteralPath $exe.FullName -Destination $lgpo -Force
        Write-IRequireLog 'LGPO.exe haettu ja allekirjoitus tarkistettu' 'Ok'
    } catch {
        Write-IRequireLog ('LGPO.exe:n haku epaonnistui, kaytetaan varamenetelmaa: ' + $_.Exception.Message) 'Varoitus'
    }
}

# --------------------------------------------------------------
Write-IRequireLog '7/8 Kopioidaan iRequire-skriptit mediaan'
# --------------------------------------------------------------
$payload = Join-Path $media 'iRequire'
New-Item -ItemType Directory -Path $payload -Force | Out-Null
foreach ($sub in @('WinPE', 'PostInstall', 'Policies', 'Lib', 'Config', 'Unattend', 'Tools')) {
    $s = Join-Path $repo $sub
    if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination $payload -Recurse -Force }
}
New-Item -ItemType Directory -Path (Join-Path $payload 'Drivers') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $payload 'Reports') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $payload 'iRequire.tag') -Value ('iRequire ' + (Get-Date -Format s)) -Encoding ASCII

# Asennusohjelman omat vastaustiedostot sotkisivat: niita ei kayteta.
foreach ($f in @('autounattend.xml', 'sources\ei.cfg')) {
    $p = Join-Path $media $f
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}

# Tiivisteet viimeisena, kun mediaan ei enaa tule muutoksia. WinPE
# tarkistaa ne ennen kuin koskee koneen levyihin.
. (Join-Path $repo 'Lib\Media.ps1')
Write-IRequireLog '  lasketaan tiivisteet'
$count = New-MediaManifest -MediaRoot $media
Write-IRequireLog "  $count tiedostoa manifestissa"

# --------------------------------------------------------------
Write-IRequireLog '8/8 Valmis'
# --------------------------------------------------------------
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
$size = (Get-ChildItem -LiteralPath $media -Recurse -File | Measure-Object Length -Sum).Sum
Write-IRequireLog ("Media: {0} ({1})" -f $media, (Format-Size $size)) 'Ok'
Write-IRequireLog 'Seuraavaksi: .\Build\New-iRequireUsb.ps1 -DiskNumber <tikun numero>  (tai New-iRequireIso.ps1 virtuaalikonetta varten)' 'Ok'
