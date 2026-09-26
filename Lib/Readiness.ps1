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
        [string[]]$TimerOverrides = @()
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
    foreach ($g in @($gpu | Where-Object { $_.Active -and $_.CurrentHz -gt 0 -and $_.MaxHz -gt 0 })) {
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
    return [pscustomobject]@{ Memory = $mem; Gpus = $gpus; HasBattery = $battery; SystemDiskKind = $kind }
}
