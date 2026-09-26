# ==============================================================
#  Lib\Readiness.ps1 - pelikuntotarkistus
#
#  Suurimmat suorituskykyerot tulevat laitteistosta ja BIOSista, eivat
#  Windowsin saadoista. Naita iRequire ei voi korjata itse, mutta se voi
#  huomata ne ja kertoa mita tehda. Tarkistukset ovat sellaisia, joiden
#  vaikutus on mitattu toistuvasti riippumattomissa testeissa:
#
#   - RAM perusnopeudella (XMP/EXPO pois paalta)
#   - yksikanavainen muisti (yksi kampa)
#   - naytto kytketty emolevyyn eika naytonohjaimeen
#   - naytto alle suurimman virkistystaajuutensa
#   - naytonohjaimelle ei ajuria (Microsoft Basic Display)
#   - Windows kiintolevylla
#   - pakotetut ajastinasetukset (useplatformclock ym.)
#
#  Get-GamingFindings on puhdas funktio: syotteet keraa Get-GamingInputs.
# ==============================================================

function New-Finding {
    param([ValidateSet('OK', 'Huomio', 'Toimi')][string]$Level, [string]$Text)
    return [pscustomobject]@{ Taso = $Level; Teksti = $Text }
}

function Test-DiscreteGpuName {
    param([string]$Name)
    # Integroidut: "Radeon(TM) Graphics", "Radeon 780M Graphics", "Radeon Vega 8",
    # "Intel UHD/Iris". Niita ei saa tulkita erillisiksi.
    return ($Name -match 'GeForce|RTX|GTX|Quadro|Radeon RX|Radeon Pro|Radeon R[579] |Radeon HD |Radeon VII|Arc(\(TM\))?\s*[AB]\d')
}

function Get-GamingFindings {
    param(
        $Memory = @(),        # @{ Type = SMBIOSMemoryType; Configured = MT/s; CapacityGb }
        $Gpus = @(),          # @{ Name; Active = bool; CurrentHz; MaxHz; Basic = bool }
        [bool]$HasBattery,
        [string]$SystemDiskKind = '',
        [string[]]$TimerOverrides = @(),
        [ValidateSet('', 'On', 'Off', 'Legacy')][string]$SecureBoot = '',
        [ValidateSet('', 'Ready', 'NotReady', 'Old', 'None')][string]$Tpm = ''
    )
    $f = New-Object System.Collections.Generic.List[object]
    $mem = @($Memory)
    $gpu = @($Gpus)

    # --- Muisti ---
    if ($mem.Count -gt 0) {
        $speed = ($mem | Measure-Object -Property Configured -Minimum).Minimum
        $type = [int]$mem[0].Type
        $total = ($mem | Measure-Object -Property CapacityGb -Sum).Sum
        $ddr = switch ($type) { 26 { 'DDR4' } 34 { 'DDR5' } default { '' } }
        $base = switch ($type) { 26 { 2400 } 34 { 4800 } default { 0 } }
        if ($base -gt 0 -and $speed -gt 0 -and $speed -le $base) {
            $f.Add((New-Finding 'Toimi' ("RAM toimii perusnopeudella {0} {1} MT/s. Pelimuistit ovat yleensa nopeampia (DDR4 3200-3600, DDR5 6000+), mutta nopeus pitaa ottaa kayttoon BIOSista: XMP (Intel) tai EXPO/DOCP (AMD). Prosessorisidonnaisissa peleissa ero on usein kymmenia prosentteja." -f $ddr, $speed)))
        } elseif ($speed -gt 0) {
            $f.Add((New-Finding 'OK' ("RAM {0} {1} MT/s" -f $ddr, $speed).Replace('  ', ' ')))
        }
        if ($mem.Count -eq 1) {
            $f.Add((New-Finding 'Toimi' ("Vain yksi muistikampa ({0} Gt): muisti toimii yksikanavaisena. Kaksi kampaa (dual channel) kaksinkertaistaa muistikaistan, mika nakyy selvasti peleissa ja erityisesti integroidulla grafiikalla." -f $total)))
        }
        if ($total -gt 0 -and $total -lt 16) {
            $f.Add((New-Finding 'Huomio' ("Muistia {0} Gt. Nykyiset pelit suosittelevat 16 Gt, osa 32 Gt." -f $total)))
        }
    }

    # --- Naytonohjain ja naytot ---
    $discrete = @($gpu | Where-Object { Test-DiscreteGpuName $_.Name })
    $integrated = @($gpu | Where-Object { -not (Test-DiscreteGpuName $_.Name) -and -not $_.Basic })
    foreach ($g in @($gpu | Where-Object { $_.Basic })) {
        $f.Add((New-Finding 'Toimi' ("Naytonohjaimelle ei ole ajuria ({0}). Asenna valmistajan ajuri." -f $g.Name)))
    }
    if (-not $HasBattery -and $discrete.Count -gt 0) {
        $discreteActive = @($discrete | Where-Object { $_.Active }).Count -gt 0
        $igpuActive = @($integrated | Where-Object { $_.Active }).Count -gt 0
        if ($igpuActive -and -not $discreteActive) {
            $f.Add((New-Finding 'Toimi' ("Naytto on kytketty emolevyn liitantaan, joten pelit pyorivat integroidulla grafiikalla eika {0}:lla. Kytke naytto naytonohjaimen liitantaan." -f $discrete[0].Name)))
        }
    }
    # WMI:n CurrentRefreshRate 0 ja 1 ovat erikoisarvoja (oletus / optimaalinen),
    # eivat taajuuksia. Alle 24 Hz ei ole todellinen pelinaytto.
    foreach ($g in @($gpu | Where-Object { $_.Active -and $_.CurrentHz -ge 24 -and $_.MaxHz -ge 24 })) {
        if ($g.CurrentHz -lt $g.MaxHz) {
            $f.Add((New-Finding 'Huomio' ("Naytto ({0}) toimii {1} Hz, suurin tuettu {2} Hz. iRequire nostaa taajuuden kirjautumisen yhteydessa; tarkista myos kaapeli (HDMI 1.4 rajoittaa)." -f $g.Name, $g.CurrentHz, $g.MaxHz)))
        } else {
            $f.Add((New-Finding 'OK' ("Naytto ({0}) {1} Hz" -f $g.Name, $g.CurrentHz)))
        }
    }

    # --- Levy ---
    if ($SystemDiskKind -eq 'HDD') {
        $f.Add((New-Finding 'Toimi' 'Windows on kiintolevylla. SSD lyhentaa kaynnistyksen ja pelien latausajat moninkertaisesti ja poistaa latausnykimisen.'))
    }

    # --- Huijauksenestot: Secure Boot ja TPM 2.0 ---
    # Esim. Valorant (Vanguard) ja Battlefield 6 eivat kaynnisty ilman niita.
    if ($SecureBoot -eq 'Legacy') {
        $f.Add((New-Finding 'Toimi' 'Secure Boot ei ole kaytettavissa: kone kaynnistyi vanhassa BIOS-tilassa (CSM/Legacy) tai laiteohjelmisto ei tue sita. Osa kilpailullisista peleista (esim. Valorant, Battlefield 6) vaatii sen. Kytke BIOSista CSM pois, kaynnista tikku UEFI-tilassa ja asenna uudelleen.'))
    } elseif ($SecureBoot -eq 'Off') {
        $f.Add((New-Finding 'Toimi' 'Secure Boot on pois paalta. Osa kilpailullisista peleista (esim. Valorant, Battlefield 6) vaatii sen. Kytke se BIOSista (Secure Boot / Windows UEFI mode); uudelleenasennusta ei tarvita.'))
    }
    if ($Tpm -eq 'None') {
        $f.Add((New-Finding 'Toimi' 'TPM 2.0 ei ole kaytossa. Kytke se BIOSista (Intel: PTT, AMD: fTPM). Osa huijauksenestoista (esim. Valorant) vaatii sen.'))
    } elseif ($Tpm -eq 'Old') {
        $f.Add((New-Finding 'Huomio' 'TPM on vanhaa 1.2-versiota. Windows 11 ja huijauksenestot odottavat versiota 2.0; tarkista BIOSista voiko sen vaihtaa.'))
    } elseif ($Tpm -eq 'NotReady') {
        $f.Add((New-Finding 'Huomio' 'TPM loytyy, mutta se ei ole valmiina kayttoon. Tarkista BIOSin TPM-asetukset tai tyhjenna TPM (tpm.msc).'))
    }
    if ($SecureBoot -eq 'On' -and $Tpm -eq 'Ready') {
        $f.Add((New-Finding 'OK' 'Secure Boot ja TPM 2.0 paalla (huijauksenestot toimivat)'))
    }

    # --- Ajastimet ---
    if (@($TimerOverrides).Count -gt 0) {
        $f.Add((New-Finding 'Huomio' ('Pakotetut ajastinasetukset poistettiin: ' + (@($TimerOverrides) -join ', ') + '. Windowsin oma valinta on nopein.')))
    }
    return ,$f
}

function Get-TimerOverrides {
    <# Loytaa bcdeditilla pakotetut ajastinasetukset. Microsoft dokumentoi ne
       vain vianetsintaan; pakotettu HPET hidastaa ajastinkutsuja moninkertaisesti. #>
    param([string]$BcdText)
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('useplatformclock', 'useplatformtick', 'disabledynamictick', 'tscsyncpolicy')) {
        if ($BcdText -match ("(?im)^\s*{0}\s+" -f $name)) { $found.Add($name) }
    }
    return ,$found
}

function Get-GamingInputs {
    <# Keraa syotteet jarjestelmasta. Paras yritys: puuttuva tieto jatetaan pois. #>
    $mem = @()
    try {
        $mem = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Type = [int]$_.SMBIOSMemoryType; Configured = [int]$_.ConfiguredClockSpeed; CapacityGb = [math]::Round($_.Capacity / 1GB) }
        })
    } catch { }
    $gpus = @()
    try {
        $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                Name      = [string]$_.Name
                Active    = ([int]$_.CurrentHorizontalResolution -gt 0)
                CurrentHz = [int]$_.CurrentRefreshRate
                MaxHz     = [int]$_.MaxRefreshRate
                Basic     = ([string]$_.Name -match 'Basic Display|Perusnaytto')
            }
        })
    } catch { }
    $battery = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).Count -gt 0
    $kind = ''
    try {
        $part = Get-Partition -DriveLetter $env:SystemDrive.Substring(0, 1) -ErrorAction Stop
        $pd = Get-PhysicalDisk | Where-Object { [string]$_.DeviceId -eq [string]$part.DiskNumber } | Select-Object -First 1
        if ($pd) { $kind = [string]$pd.MediaType }
    } catch { }
    $sb = ''
    try { $sb = $(if (Confirm-SecureBootUEFI -ErrorAction Stop) { 'On' } else { 'Off' }) } catch [System.PlatformNotSupportedException] { $sb = 'Legacy' } catch { }
    $tpm = ''
    try {
        $t = Get-Tpm -ErrorAction Stop
        if (-not $t.TpmPresent) { $tpm = 'None' }
        else {
            $spec = [string](Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction SilentlyContinue).SpecVersion
            $tpm = $(if ($spec -and $spec -notmatch '^2\.0') { 'Old' } elseif ($t.TpmReady) { 'Ready' } else { 'NotReady' })
        }
    } catch { }
    return [pscustomobject]@{ Memory = $mem; Gpus = $gpus; HasBattery = $battery; SystemDiskKind = $kind; SecureBoot = $sb; Tpm = $tpm }
}

function Get-SecureBootCaAdvice {
    <# Kumpi Secure Boot -varmenne tikulle (Build-iRequire.ps1 -SecureBootCA)?
       Puhdas paatos: syotteet keraa Tools\Test-TargetMachine.ps1.
       KB5025885: kun 'Microsoft Windows Production PCA 2011' on DBX:ssa,
       2011-allekirjoitettu tikku ei kaynnisty. 2023-tikku vaatii etta
       'Windows UEFI CA 2023' on DB:ssa. #>
    param(
        [ValidateSet('', 'On', 'Off', 'Legacy')][string]$SecureBoot = '',
        $Db2023 = $null,            # $true / $false / $null (ei tiedossa)
        $Pca2011Revoked = $null
    )
    if ($SecureBoot -ne 'On') {
        $why = if ($SecureBoot -eq '') { 'Secure Bootin tilaa ei saatu (aja jarjestelmanvalvojana).' } else { 'Secure Boot ei ole paalla, joten allekirjoitusta ei tarkisteta.' }
        return [pscustomobject]@{ Ca = 'Kumpi tahansa'; Varma = ($SecureBoot -ne ''); Syy = $why }
    }
    if ($Pca2011Revoked -eq $true) {
        return [pscustomobject]@{ Ca = '2023'; Varma = $true; Syy = 'Vanhat kaynnistyksenhallinnat on mitatoity tassa koneessa: 2011-tikku ei kaynnisty.' }
    }
    if ($Db2023 -eq $false) {
        return [pscustomobject]@{ Ca = '2011'; Varma = $true; Syy = "Laiteohjelmisto ei viela luota 'Windows UEFI CA 2023' -varmenteeseen: 2023-tikku ei kaynnisty." }
    }
    if ($Db2023 -eq $true -and $Pca2011Revoked -eq $false) {
        return [pscustomobject]@{ Ca = 'Kumpi tahansa'; Varma = $true; Syy = 'Kone luottaa molempiin. 2023 on tulevaisuudenkestavampi.' }
    }
    return [pscustomobject]@{ Ca = '2011'; Varma = $false; Syy = 'Varmenteiden tilaa ei saatu kokonaan selville. 2011 toimii useimmissa koneissa; jos tikku ei kaynnisty, rakenna -SecureBootCA 2023.' }
}

function Test-ThirdPartyStorageDriver {
    <# Tarvitaanko tallennusohjaimelle ajuri tikulle? Windowsin omat ajurit
       (stornvme, storahci ...) ovat myos WinPE:ssa; kolmannen osapuolen
       (oemNN.inf, esim. Intel RST/VMD) eivat. #>
    param([string]$InfPath, [string]$Class)
    if (@('SCSIAdapter', 'HDC') -notcontains $Class) { return $false }
    return ($InfPath -match '^oem\d+\.inf$')
}
