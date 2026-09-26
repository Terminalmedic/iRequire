# ==============================================================
#  Lib\Tuning.ps1 - pelikoneen viritys ja tietoturva
#
#  Periaate: vain muutoksia joiden hyoty on mitattu tai Microsoftin
#  dokumentoima. Ei "tweak-listojen" plaseboja (HPET, timer resolution,
#  Nagle, prosessoriytimien "vapautus" jne.), jotka parhaimmillaankin
#  eivat tee mitaan ja pahimmillaan rikkovat jotain.
#
#  Paatoslogiikka on puhtaina funktioina (Get-*Choice), jotta sen voi
#  testata ilman Windowsia. Varsinaiset muutokset tekee Invoke-StageTuning.
# ==============================================================

$script:PowerPlans = @{
    Ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'   # piilotettu malli, kopioidaan kayttoon
    High     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    Balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
}
# Windows 11:n "virtatila"-liukusaatimen paras suorituskyky -tila.
$script:BestPerformanceOverlay = 'ded574b5-45a0-4f42-8737-46345c09c238'

function Get-PowerPlanChoice {
    <# auto: poytakone -> ultimate, kannettava -> balanced (+ paras suorituskyky
       laturissa). Kannettavassa ultimate estaa prosessoria laskemasta
       kellotaajuutta, mika kuumentaa ja kuluttaa akkua ilman hyotya. #>
    param([string]$Setting = 'auto', [bool]$HasBattery)
    switch -Regex ($Setting) {
        '^(?i)ultimate$' { return 'Ultimate' }
        '^(?i)high$'     { return 'High' }
        '^(?i)balanced$' { return 'Balanced' }
        default          { if ($HasBattery) { return 'Balanced' } else { return 'Ultimate' } }
    }
}

function Get-HibernateChoice {
    <# Palauttaa $true jos horrostila poistetaan. Kannettavassa horrostila
       suojaa tyot akun loppuessa, joten auto jattaa sen paalle. #>
    param($Setting = 'auto', [bool]$HasBattery)
    if ($Setting -is [bool]) { return $Setting }
    if ([string]$Setting -match '^(?i)(true|kylla)$') { return $true }
    if ([string]$Setting -match '^(?i)(false|ei)$') { return $false }
    return (-not $HasBattery)
}

function Test-ActiveHours {
    <# Windows sallii aktiivisiksi tunneiksi enintaan 18 tunnin ikkunan. #>
    param([int]$Start, [int]$End)
    if ($Start -lt 0 -or $Start -gt 23 -or $End -lt 0 -or $End -gt 23 -or $Start -eq $End) { return $false }
    $span = ($End - $Start + 24) % 24
    return ($span -le 18)
}

function Set-RegistryValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Set-PowerPlan {
    param([Parameter(Mandatory)][string]$Choice)
    $list = (& powercfg.exe /list) -join "`n"

    if ($Choice -eq 'Ultimate') {
        # Kopioidaan vain kerran: toinen ajo loytaa olemassa olevan.
        $m = [regex]::Match($list, '([0-9a-f-]{36})\s+\(Ultimate Performance\)')
        $guid = if ($m.Success) { $m.Groups[1].Value } else {
            $dup = (& powercfg.exe /duplicatescheme $script:PowerPlans.Ultimate) -join ' '
            $d = [regex]::Match($dup, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
            if ($d.Success) { $d.Value } else { $null }
        }
        if ($guid) {
            & powercfg.exe /setactive $guid
            if ($LASTEXITCODE -eq 0) { Write-IRequireLog 'Virrankaytto: Ultimate Performance' 'Ok'; return }
        }
        # Modern Standby -koneissa (S0) vain Balanced on kaytettavissa.
        Write-IRequireLog 'Ultimate Performance ei kaytettavissa, kokeillaan High performance' 'Varoitus'
        $Choice = 'High'
    }
    if ($Choice -eq 'High') {
        if ((Invoke-Native powercfg.exe @('/setactive', $script:PowerPlans.High)).ExitCode -eq 0) { Write-IRequireLog 'Virrankaytto: High performance' 'Ok'; return }
        Write-IRequireLog 'High performance ei kaytettavissa, kaytetaan Balanced + paras suorituskyky' 'Varoitus'
    }

    & powercfg.exe /setactive $script:PowerPlans.Balanced | Out-Null
    # Laturissa paras suorituskyky, akulla Windowsin oletus. Sama arvo jonka
    # Asetukset > Virta > Virtatila kirjoittaa.
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
    Set-RegistryValue -Path $key -Name 'ActiveOverlayAcPowerScheme' -Value $script:BestPerformanceOverlay -Type String
    Write-IRequireLog 'Virrankaytto: Balanced, laturissa paras suorituskyky' 'Ok'
}

function Enable-BitLockerWithUsbKey {
    <# Salaa C:n vain jos palautusavain saadaan talteen tikulle ja luettua
       sielta takaisin. Ilman avainta salattu levy on aikapommi: BIOS-paivitys
       tai emolevyn vaihto voi lukita koneen pysyvasti. #>
    param([string]$UsbRoot)
    if (-not $UsbRoot) { Write-IRequireLog 'BitLocker ohitettu: tikku ei ole kiinni, palautusavainta ei voisi tallentaa' 'Varoitus'; return }
    $tpm = Get-Tpm -ErrorAction SilentlyContinue
    if (-not $tpm -or -not $tpm.TpmReady) { Write-IRequireLog 'BitLocker ohitettu: TPM ei ole valmiina' 'Varoitus'; return }
    $vol = Get-BitLockerVolume -MountPoint $env:SystemDrive
    if ($vol.VolumeStatus -ne 'FullyDecrypted') { Write-IRequireLog ('BitLocker: levy on jo tilassa ' + $vol.VolumeStatus); return }

    $protector = Add-BitLockerKeyProtector -MountPoint $env:SystemDrive -RecoveryPasswordProtector -WarningAction SilentlyContinue
    $rp = @($protector.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }) | Select-Object -Last 1
    $dir = Join-Path $UsbRoot ("iRequire\Reports\{0}-bitlocker" -f $env:COMPUTERNAME)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir 'BitLocker-palautusavain.txt'
    $text = @(
        "BitLocker-palautusavain, kone $env:COMPUTERNAME, luotu $((Get-Date).ToString('s'))",
        "Tunniste: $($rp.KeyProtectorId)",
        "Avain:    $($rp.RecoveryPassword)",
        '',
        'Sailyta tama tallessa muualla kuin koneessa itsessaan.'
    )
    $text | Set-Content -LiteralPath $file -Encoding ASCII
    if ((Get-Content -LiteralPath $file -Raw) -notmatch [regex]::Escape($rp.RecoveryPassword)) {
        Remove-BitLockerKeyProtector -MountPoint $env:SystemDrive -KeyProtectorId $rp.KeyProtectorId | Out-Null
        throw 'Palautusavaimen tallennus tikulle ei varmistunut. BitLockeria ei otettu kayttoon.'
    }
    Enable-BitLocker -MountPoint $env:SystemDrive -EncryptionMethod XtsAes128 -UsedSpaceOnly -TpmProtector -SkipHardwareTest -WarningAction SilentlyContinue | Out-Null
    Write-IRequireLog "BitLocker kaytossa, palautusavain tikulla: $file" 'Ok'
}

function Remove-TimerOverrides {
    <# Poistaa pakotetut ajastinasetukset (useplatformclock ym.). Puhtaassa
       asennuksessa niita ei ole, mutta tarkistus on halpa ja varmistaa ettei
       mikaan ajuri tai tyokalu ole asettanut niita. Palauttaa poistetut. #>
    $text = (& bcdedit.exe /enum '{current}') -join "`n"
    $found = Get-TimerOverrides -BcdText $text
    foreach ($name in $found) {
        & bcdedit.exe /deletevalue '{current}' $name | Out-Null
        Write-IRequireLog "Poistettu pakotettu ajastinasetus: $name" 'Ok'
    }
    return ,$found
}

function Disable-DevicePowerSaving {
    <# "Salli tietokoneen sammuttaa tama laite virran saastamiseksi" pois
       kaikilta laitteilta. Estaa USB-hiiren, nappaimiston ja verkkokortin
       nukahtamisen, joka nakyy viiveena tai katkoksina. Vain poytakoneissa:
       kannettavassa se kuluttaisi akkua. #>
    $n = 0
    foreach ($d in @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue)) {
        if (-not $d.Enable) { continue }
        try { Set-CimInstance -InputObject $d -Property @{ Enable = $false } -ErrorAction Stop; $n++ } catch { }
    }
    Write-IRequireLog "Laitteiden virransaasto pois: $n laitetta"
}

function Disable-NetBios {
    <# NetBIOS over TCP/IP pois: kuuntelee turhaan portteja 137-139 ja on
       vanha hyokkayspinta. Kotikoneessa sita ei tarvita mihinkaan. #>
    $n = 0
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces'
    foreach ($k in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
        Set-ItemProperty -LiteralPath $k.PSPath -Name 'NetbiosOptions' -Value 2 -Type DWord
        $n++
    }
    Write-IRequireLog "NetBIOS pois: $n verkkoliitantaa"
}

function Invoke-StageTuning {
    <# Suorituskyky- ja tietoturvaviritys. Jokainen kohta on turvallista
       ajaa uudelleen. #>
    param([Parameter(Mandatory)]$Config, [string]$UsbRoot)

    $hasBattery = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).Count -gt 0
    Write-IRequireLog ("Koneen tyyppi: {0}" -f $(if ($hasBattery) { 'kannettava' } else { 'poytakone' }))

    Set-PowerPlan -Choice (Get-PowerPlanChoice -Setting ([string]$Config.Suorituskyky.Virrankaytto) -HasBattery $hasBattery)

    if (Get-HibernateChoice -Setting $Config.Suorituskyky.HorrostilaPois -HasBattery $hasBattery) {
        & powercfg.exe /hibernate off
        Write-IRequireLog 'Horrostila pois (hiberfil.sys poistettu)'
    }

    if ($Config.Suorituskyky.GpuAjoitus) {
        Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -Value 2
        Write-IRequireLog 'Laitteistokiihdytetty GPU-ajoitus paalle (voimaan uudelleenkaynnistyksen jalkeen)'
    }

    $windowed = [bool]$Config.Suorituskyky.IkkunoidutPelit
    Invoke-ForEachUserHive {
        param($root)
        # Game Mode: Windows antaa pelille etusijan ja lykkaa taustatoimintoja.
        Set-RegistryValue -Path (Join-Path $root 'Software\Microsoft\GameBar') -Name 'AutoGameModeEnabled' -Value 1
        Set-RegistryValue -Path (Join-Path $root 'Software\Microsoft\GameBar') -Name 'AllowAutoGameMode' -Value 1
        if ($windowed) {
            Set-RegistryValue -Path (Join-Path $root 'Software\Microsoft\DirectX\UserGpuPreferences') `
                -Name 'DirectXUserGlobalSettings' -Value 'SwapEffectUpgradeEnable=1;' -Type String
        }
    }
    Write-IRequireLog 'Game Mode paalle kaikille kayttajille'
    if ($windowed) { Write-IRequireLog 'Ikkunoitujen pelien optimoinnit paalle' }

    $start = [int]$Config.Suorituskyky.AktiivisetTunnitAlku
    $end = [int]$Config.Suorituskyky.AktiivisetTunnitLoppu
    if (Test-ActiveHours -Start $start -End $end) {
        $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        Set-RegistryValue -Path $wu -Name 'SetActiveHours' -Value 1
        Set-RegistryValue -Path $wu -Name 'ActiveHoursStart' -Value $start
        Set-RegistryValue -Path $wu -Name 'ActiveHoursEnd' -Value $end
        Write-IRequireLog ("Aktiiviset tunnit {0}-{1}: ei paivitysten uudelleenkaynnistyksia" -f $start, $end)
    } else {
        Write-IRequireLog ("Aktiiviset tunnit {0}-{1} eivat kelpaa (enintaan 18 h), ohitetaan" -f $start, $end) 'Varoitus'
    }

    $removed = Remove-TimerOverrides
    if ($removed.Count -gt 0) {
        # Yhteenveto kirjoitetaan myohemmalla kaynnistyksella, joten talteen tiedostoon.
        $removed.ToArray() | Set-Content -LiteralPath (Join-Path $env:SystemDrive 'iRequire\Logs\ajastimet.txt') -Encoding ASCII
    }
    if (-not $hasBattery) { Disable-DevicePowerSaving }
    Disable-NetBios

    if ($Config.Tietoturva.BitLocker) {
        try { Enable-BitLockerWithUsbKey -UsbRoot $UsbRoot } catch { Write-IRequireLog ('BitLocker: ' + $_.Exception.Message) 'Varoitus' }
    }
}

function Get-SecuritySummary {
    <# Yhteenvetoon: mika suojaus on paalla. Paras yritys, virhe ei haittaa. #>
    $lines = New-Object System.Collections.Generic.List[string]
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $lines.Add(('Defender: reaaliaikainen suojaus {0}, maaritykset {1}, tila {2}' -f $(if ($mp.RealTimeProtectionEnabled) { 'paalla' } else { 'POIS' }), $mp.AntivirusSignatureVersion, $mp.AMRunningMode))
    } catch { $lines.Add('Defender: tilaa ei saatu') }
    try {
        $fw = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { -not $_.Enabled })
        $lines.Add($(if ($fw.Count -eq 0) { 'Palomuuri: paalla kaikissa profiileissa' } else { 'Palomuuri: POIS profiileissa ' + (($fw | ForEach-Object { $_.Name }) -join ', ') }))
    } catch { }
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        $hvci = @($dg.SecurityServicesRunning) -contains 2
        $lines.Add(('Muistin eheys (HVCI): {0}' -f $(if ($hvci) { 'paalla' } else { 'pois (laite ei tue tai ei kaytossa)' })))
    } catch { }
    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction Stop
        $lines.Add(('Secure Boot: {0}' -f $(if ($sb) { 'paalla' } else { 'POIS' })))
    } catch { $lines.Add('Secure Boot: ei tuettu (BIOS-tila)') }
    try {
        $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        $lines.Add(('BitLocker: {0}' -f $bl.VolumeStatus))
    } catch { }
    try {
        $nf = Get-WindowsOptionalFeature -Online -FeatureName NetFx3 -ErrorAction Stop
        $lines.Add(('.NET Framework 3.5: {0}' -f $nf.State))
    } catch { }
    try {
        $plan = ((& powercfg.exe /getactivescheme) -join ' ') -replace '^.*\((.*)\).*$', '$1'
        $lines.Add("Virrankaytto: $plan")
    } catch { }
    return ,$lines
}
