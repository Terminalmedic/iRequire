# ==============================================================
#  WinPE\Deploy.ps1 - Windowsin asennus tyhjennetylle levylle
#
#  Windowsin omaa asennusohjelmaa (setup.exe) ei kayteta: kuva puretaan
#  suoraan DISMilla. Nain levyn valinta, osiointi ja uudelleenkaynnistys
#  ovat taysin taman skriptin hallinnassa, eika mitaan kysyta.
# ==============================================================

function Select-TargetDisk {
    <# Windows menee nopeimmalle levylle: NVMe > SSD > eMMC > tuntematon > HDD, tasatilanteessa
       pienin levynumero. Liian pienet levyt ohitetaan. #>
    param([Parameter(Mandatory)]$Disks, [int]$MinimumGb = 40)
    $rank = @{ 'NVMe' = 0; 'SSD' = 1; 'eMMC' = 2; 'Tuntematon' = 3; 'HDD' = 4 }
    $ok = @($Disks | Where-Object { $_.Size -ge ([int64]$MinimumGb * 1GB) })
    if ($ok.Count -eq 0) { return $null }
    return $ok | Sort-Object @{ Expression = { $rank[$_.Kind] } }, Number | Select-Object -First 1
}

function Get-FirmwareType {
    <# 1 = BIOS, 2 = UEFI. WinPE kirjaa taman rekisteriin kaynnistyessaan. #>
    try {
        $v = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PEFirmwareType -ErrorAction Stop).PEFirmwareType
        if ($v -eq 1) { return 'BIOS' }
    } catch { }
    return 'UEFI'
}

function Get-FreeDriveLetters {
    param([int]$Count = 2)
    $used = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name.ToUpper() })
    $free = @('S', 'W', 'T', 'V', 'R', 'Q', 'P', 'O', 'N', 'M') | Where-Object { $used -notcontains $_ }
    if ($free.Count -lt $Count) { throw 'Vapaita asematunnuksia ei ole tarpeeksi' }
    return $free[0..($Count - 1)]
}

function Invoke-Diskpart {
    param([Parameter(Mandatory)][string[]]$Commands, [Parameter(Mandatory)][string]$WorkDir)
    $script = Join-Path $WorkDir 'diskpart.txt'
    $Commands | Set-Content -LiteralPath $script -Encoding ASCII
    $r = Invoke-Native diskpart.exe @('/s', $script)
    $r.Output | ForEach-Object { Write-IRequireLog ("diskpart: " + $_) }
    if ($r.ExitCode -ne 0) { throw "diskpart epaonnistui (koodi $($r.ExitCode))" }
}

function New-WindowsPartitions {
    <# GPT (UEFI): EFI 260 Mt + MSR 16 Mt + Windows. MBR (BIOS): jarjestelma
       350 Mt + Windows. Erillista palautusosiota ei tehda: WinRE toimii
       Windows-osion sisalta. #>
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][string]$Firmware, [Parameter(Mandatory)][string]$WorkDir)

    $sys, $win = Get-FreeDriveLetters -Count 2
    if ($Firmware -eq 'UEFI') {
        $cmds = @(
            "select disk $Number", 'clean', 'convert gpt',
            'create partition efi size=260', 'format quick fs=fat32 label="System"', "assign letter=$sys",
            'create partition msr size=16',
            'create partition primary', 'format quick fs=ntfs label="Windows"', "assign letter=$win"
        )
    } else {
        $cmds = @(
            "select disk $Number", 'clean', 'convert mbr',
            'create partition primary size=350', 'format quick fs=ntfs label="System"', 'active', "assign letter=$sys",
            'create partition primary', 'format quick fs=ntfs label="Windows"', "assign letter=$win"
        )
    }
    Invoke-Diskpart -Commands $cmds -WorkDir $WorkDir
    return [pscustomobject]@{ System = "${sys}:"; Windows = "${win}:" }
}

function Get-InstallImage {
    param([Parameter(Mandatory)][string]$UsbRoot)
    $src = Join-Path $UsbRoot 'sources'
    $swm = Join-Path $src 'install.swm'
    if (Test-Path -LiteralPath $swm) { return [pscustomobject]@{ File = $swm; Split = (Join-Path $src 'install*.swm') } }
    foreach ($n in @('install.wim', 'install.esd')) {
        $p = Join-Path $src $n
        if (Test-Path -LiteralPath $p) { return [pscustomobject]@{ File = $p; Split = $null } }
    }
    throw "Asennuskuvaa ei loydy kansiosta $src"
}

function Install-WindowsImage {
    param([Parameter(Mandatory)][string]$UsbRoot, [Parameter(Mandatory)][string]$Target)
    $img = Get-InstallImage -UsbRoot $UsbRoot
    $dismArgs = @('/Apply-Image', "/ImageFile:$($img.File)", '/Index:1', "/ApplyDir:$Target\")
    if ($img.Split) { $dismArgs += "/SWMFile:$($img.Split)" }
    Write-IRequireLog ("Puretaan {0} -> {1}" -f $img.File, $Target)
    & dism.exe @dismArgs
    if ($LASTEXITCODE -ne 0) { throw "Kuvan purku epaonnistui (DISM $LASTEXITCODE)" }
}

function Add-MachineDrivers {
    <# Tikun iRequire\Drivers-kansion ajurit lisataan asennukseen. Taalla
       ovat konekohtaiset ajurit, joita ei haluttu leipoa kuvaan. #>
    param([Parameter(Mandatory)][string]$UsbRoot, [Parameter(Mandatory)][string]$Target)
    $dir = Join-Path $UsbRoot 'iRequire\Drivers'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    if (-not (Get-ChildItem -LiteralPath $dir -Recurse -Filter *.inf -ErrorAction SilentlyContinue | Select-Object -First 1)) { return }
    Write-IRequireLog 'Lisataan tikun ajurit asennukseen'
    & dism.exe "/Image:$Target\" /Add-Driver "/Driver:$dir" /Recurse
    if ($LASTEXITCODE -ne 0) { Write-IRequireLog "Ajurien lisays palautti koodin $LASTEXITCODE" 'Varoitus' }
}

function ConvertTo-XmlText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Security.SecurityElement]::Escape($Text)
}

function New-UnattendXml {
    <# Tayttaa pohjan asetuksilla. Tyhja tuoteavain poistaa elementin kokonaan. #>
    param([Parameter(Mandatory)][string]$TemplatePath, [Parameter(Mandatory)]$Config)

    $xml = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8
    $autoLogonCount = if ($Config.Asennus.AutomaattikirjautuminenPysyva) { 999 } else { 20 }
    $map = @{
        '{{KONENIMI}}'       = [string]$Config.Kone.Nimi
        '{{AIKAVYOHYKE}}'    = [string]$Config.Alue.Aikavyohyke
        '{{KAYTTOLIITTYMA}}' = [string]$Config.Alue.Kayttoliittyma
        '{{ALUE}}'           = [string]$Config.Alue.Alue
        '{{NAPPAIMISTO}}'    = [string]$Config.Alue.Nappaimisto
        '{{KAYTTAJA}}'       = [string]$Config.Kayttaja.Nimi
        '{{SALASANA}}'       = [string]$Config.Kayttaja.Salasana
        '{{TUOTEAVAIN}}'     = [string]$Config.Asennus.Tuoteavain
        '{{KIRJAUTUMISIA}}'  = [string]$autoLogonCount
    }
    if (-not $Config.Asennus.Tuoteavain) {
        $xml = [regex]::Replace($xml, '\s*<ProductKey>\{\{TUOTEAVAIN\}\}</ProductKey>', '')
    }
    foreach ($k in $map.Keys) { $xml = $xml.Replace($k, (ConvertTo-XmlText $map[$k])) }

    # Varmistetaan ettei rikkinaista XML:aa paase levylle: rikkinainen
    # vastaustiedosto pysayttaa asennuksen virheilmoitukseen.
    [void]([xml]$xml)
    return $xml
}

function Copy-Payload {
    <# Jalkiasennuksen skriptit, asetukset ja raportit Windows-osiolle. #>
    param([Parameter(Mandatory)][string]$UsbRoot, [Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)]$Config,
          [string]$ReportsDir)

    $src = Join-Path $UsbRoot 'iRequire'
    $dst = Join-Path $Target 'iRequire'
    # Kohde luotava ensin: muuten Copy-Item kopioi ensimmaisen kansion
    # kohteen NIMELLA (W:\iRequire\Invoke-PostInstall.ps1) eika sen sisaan.
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    foreach ($sub in @('PostInstall', 'Policies', 'Lib', 'Config', 'Tools')) {
        $s = Join-Path $src $sub
        if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination $dst -Recurse -Force }
    }
    New-Item -ItemType Directory -Path (Join-Path $dst 'Logs') -Force | Out-Null
    $rep = Join-Path $dst 'Reports'
    New-Item -ItemType Directory -Path $rep -Force | Out-Null
    if ($ReportsDir -and (Test-Path -LiteralPath $ReportsDir)) {
        Get-ChildItem -LiteralPath $ReportsDir -File | Copy-Item -Destination $rep -Force
    }

    $scripts = Join-Path $Target 'Windows\Setup\Scripts'
    New-Item -ItemType Directory -Path $scripts -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $src 'PostInstall\SetupComplete.cmd') -Destination $scripts -Force

    $panther = Join-Path $Target 'Windows\Panther'
    New-Item -ItemType Directory -Path $panther -Force | Out-Null
    $xml = New-UnattendXml -TemplatePath (Join-Path $src 'Unattend\unattend.template.xml') -Config $Config
    [System.IO.File]::WriteAllText((Join-Path $panther 'unattend.xml'), $xml, (New-Object System.Text.UTF8Encoding $false))

    # Merkki, jonka perusteella tikku tunnistaa keskeneraisen asennuksen
    # eika tyhjenna sita uudelleen, jos kone kaynnistyy taas tikulta.
    Set-Content -LiteralPath (Join-Path $dst 'ASENNUS-KESKEN.tag') -Value (Get-Date).ToString('s') -Encoding ASCII
}

function Set-BootFiles {
    param([Parameter(Mandatory)][string]$Windows, [Parameter(Mandatory)][string]$System, [Parameter(Mandatory)][string]$Firmware)
    $fwArg = if ($Firmware -eq 'UEFI') { 'UEFI' } else { 'BIOS' }
    $bcdArgs = @("$Windows\Windows", '/s', $System, '/f', $fwArg)
    if ($Firmware -eq 'UEFI') {
        # /bootex: 'Windows UEFI CA 2023' -allekirjoitettu kaynnistyksenhallinta,
        # jos laiteohjelmisto luottaa siihen (bcdboot paattaa itse). Muuten
        # asennettu Windows ei kaynnistyisi koneessa, jossa vanhat on mitatoity
        # (KB5025885). Jos lippua ei tueta, tavallinen tapa.
        $r = Invoke-Native bcdboot.exe ($bcdArgs + '/bootex')
        $r.Output | ForEach-Object { Write-IRequireLog ("bcdboot: " + $_) }
        if ($r.ExitCode -eq 0) { Set-InternalBootFirst; return }
        Write-IRequireLog ("bcdboot /bootex epaonnistui (koodi {0}), tavallinen kaynnistystiedostojen asennus" -f $r.ExitCode) 'Varoitus'
    }
    $r = Invoke-Native bcdboot.exe $bcdArgs
    $r.Output | ForEach-Object { Write-IRequireLog ("bcdboot: " + $_) }
    if ($r.ExitCode -ne 0) { throw "bcdboot epaonnistui (koodi $($r.ExitCode))" }
    if ($Firmware -eq 'UEFI') { Set-InternalBootFirst }
}

function Set-InternalBootFirst {
    <# bcdboot asettaa Windows Boot Managerin yleensa ensimmaiseksi, mutta
       osa laiteohjelmistoista suosii silti USB:ta. Siirretaan se ensimmaiseksi
       ja pyydetaan seuraava kaynnistys sen kautta. Paras yritys. #>
    try {
        $text = (& bcdedit.exe /enum firmware) -join "`n"
        $blocks = $text -split "`n\s*`n"
        foreach ($b in $blocks) {
            if ($b -match 'Windows Boot Manager' -and $b -match '(?m)^identifier\s+(\{[^}]+\})') {
                $id = $Matches[1]
                & bcdedit.exe /set '{fwbootmgr}' displayorder $id /addfirst | Out-Null
                & bcdedit.exe /set '{fwbootmgr}' bootsequence $id | Out-Null
                Write-IRequireLog "Kaynnistysjarjestys: $id ensimmaiseksi"
                return
            }
        }
        Write-IRequireLog 'Windows Boot Manageria ei loytynyt laiteohjelmiston listasta' 'Varoitus'
    } catch {
        Write-IRequireLog ('Kaynnistysjarjestyksen asetus epaonnistui: ' + $_.Exception.Message) 'Varoitus'
    }
}

function Test-Deployment {
    <# Viimeinen tarkistus ennen uudelleenkaynnistysta: jos jokin puuttuu,
       on parempi pysahtya tahan virheilmoitukseen kuin kaynnistaa kone
       joka ei kaynnisty. #>
    param([Parameter(Mandatory)][string]$Windows, [Parameter(Mandatory)][string]$System, [Parameter(Mandatory)][string]$Firmware)
    $must = @(
        "$Windows\Windows\System32\config\SYSTEM",
        "$Windows\Windows\System32\winload.efi",
        "$Windows\Windows\Panther\unattend.xml",
        "$Windows\Windows\Setup\Scripts\SetupComplete.cmd",
        "$Windows\iRequire\PostInstall\Invoke-PostInstall.ps1",
        "$Windows\iRequire\Lib\Common.ps1",
        "$Windows\iRequire\Lib\Stages.ps1",
        "$Windows\iRequire\Lib\Tuning.ps1",
        "$Windows\iRequire\Lib\Readiness.ps1",
        "$Windows\iRequire\Lib\Display.ps1",
        "$Windows\iRequire\Config\iRequire.json",
        "$Windows\iRequire\Policies\Debloat.json"
    )
    if ($Firmware -eq 'UEFI') { $must += "$System\EFI\Microsoft\Boot\bootmgfw.efi"; $must += "$System\EFI\Microsoft\Boot\BCD" }
    else { $must += "$System\bootmgr"; $must += "$System\Boot\BCD" }
    $missing = @($must | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missing.Count -gt 0) { throw ('Asennuksesta puuttuu: ' + ($missing -join ', ')) }
    Write-IRequireLog 'Asennus tarkistettu: kaynnistystiedostot, vastaustiedosto ja jalkiasennus paikallaan' 'Ok'
}

function Find-PendingInstall {
    <# Etsii sisaisilta levyilta keskeneraisen iRequire-asennuksen merkin. #>
    foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })) {
        $tag = "$($v.DriveLetter):\iRequire\ASENNUS-KESKEN.tag"
        if (Test-Path -LiteralPath $tag) { return "$($v.DriveLetter):" }
    }
    return $null
}
