#requires -Version 5.1
<#
.SYNOPSIS
    iRequiren jalkiasennus: kaytannot, karsinta, paivitykset, viimeistely.

.DESCRIPTION
    Ajetaan SYSTEM-tunnuksella ajastettuna tehtavana jokaisessa
    kaynnistyksessa, kunnes kaikki vaiheet on tehty. Tila tallennetaan
    tiedostoon, joten uudelleenkaynnistys kesken paivitysten jatkaa
    siita mihin jaatiin. Jokainen vaihe on turvallista ajaa uudelleen.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$base = Join-Path $env:SystemDrive 'iRequire'
. (Join-Path $base 'Lib\Common.ps1')
. (Join-Path $base 'Lib\Stages.ps1')
. (Join-Path $base 'Lib\Tuning.ps1')
. (Join-Path $base 'Lib\Readiness.ps1')

$stateFile = Join-Path $base 'Logs\tila.json'
$stages = @('Kaytannot', 'Palvelut', 'Poistot', 'Viritys', 'Verkko', 'Paivitykset', 'Sovellukset', 'Viimeistely')

# Estetaan kaksi samanaikaista ajoa (kaynnistystehtava + SetupCompleten kaynnistys).
$mutex = New-Object System.Threading.Mutex($false, 'Global\iRequirePostInstall')
if (-not $mutex.WaitOne(0)) { exit 0 }

Start-Log -Path (Join-Path $base 'Logs\postinstall.log')
$config = Get-IRequireConfig -Path (Join-Path $base 'Config\iRequire.json')
if ($config.Asennus.LokiSarjaporttiin) { Enable-SerialLog }
$debloat = Get-Content -LiteralPath (Join-Path $base 'Policies\Debloat.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-State {
    $s = $null
    if (Test-Path -LiteralPath $stateFile) {
        try { $s = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    return New-StageState -Stages $stages -Existing $s
}

function Save-State {
    param($State)
    $State | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
}

function Set-Status {
    param($State, [string]$Message)
    $State.Viesti = $Message
    Save-State $State
    Write-IRequireLog $Message
}

function Restart-ForStage {
    param($State, [string]$Reason)
    Save-State $State
    Write-IRequireLog "Uudelleenkaynnistys: $Reason"
    & shutdown.exe /r /t 30 /c "iRequire: $Reason. Kone kaynnistyy uudelleen ja jatkaa itsestaan."
    $mutex.ReleaseMutex()
    exit 0
}

# ==============================================================
#  Vaiheet
# ==============================================================

function Invoke-StagePolicies {
    # Vastaustiedostossa on kayttajan salasana selvakielisena.
    foreach ($f in @('Windows\Panther\unattend.xml', 'Windows\Panther\unattend-original.xml')) {
        $p = Join-Path $env:SystemDrive $f
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }

    $lgpo = Join-Path $base 'Tools\LGPO.exe'
    $files = @('machine.txt', 'user.txt') | ForEach-Object { Join-Path $base "Policies\$_" }

    if (Test-Path -LiteralPath $lgpo) {
        foreach ($f in $files) {
            Write-IRequireLog "LGPO: $f"
            $r = Invoke-Native $lgpo @('/t', $f)
            $r.Output | ForEach-Object { Write-IRequireLog ("  " + $_) }
            if ($r.ExitCode -ne 0) { throw "LGPO epaonnistui tiedostolle $f (koodi $($r.ExitCode))" }
        }
    } else {
        # Varamenetelma: samat arvot suoraan rekisteriin. Toimii, mutta
        # arvot eivat nay gpeditissa kaytantoina.
        Write-IRequireLog 'LGPO.exe puuttuu, kirjoitetaan kaytannot suoraan rekisteriin' 'Varoitus'
        $entries = @()
        foreach ($f in $files) { $entries += (Read-PolicyFile -Path $f).ToArray() }
        foreach ($e in @($entries | Where-Object { $_.Scope -eq 'Computer' })) { Set-PolicyEntry -Entry $e -Root 'HKLM:\' }
        $userEntries = @($entries | Where-Object { $_.Scope -eq 'User' })
        Invoke-ForEachUserHive {
            param($root)
            foreach ($e in $userEntries) { Set-PolicyEntry -Entry $e -Root $root }
        }
    }
    (Invoke-Native gpupdate.exe @('/force', '/wait:120')).Output | ForEach-Object { Write-IRequireLog ("gpupdate: " + $_) }
}

function Invoke-StageServices {
    foreach ($name in $debloat.Palvelut) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        try {
            Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
            Set-Service -Name $name -StartupType Disabled
            Write-IRequireLog "Palvelu pois kaytosta: $name"
        } catch {
            Write-IRequireLog ("Palvelua {0} ei voitu muuttaa: {1}" -f $name, $_.Exception.Message) 'Varoitus'
        }
    }
    foreach ($full in $debloat.Ajastukset) {
        $idx = $full.LastIndexOf('\')
        $path = $full.Substring(0, $idx + 1)
        $name = $full.Substring($idx + 1)
        $task = Get-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue
        if ($task) {
            $task | Disable-ScheduledTask | Out-Null
            Write-IRequireLog "Ajastus pois kaytosta: $full"
        }
    }
}

function Invoke-StageRemovals {
    foreach ($pattern in $debloat.Appx) {
        foreach ($p in @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like $pattern })) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName | Out-Null
                Write-IRequireLog "Poistettu esiasennus: $($p.DisplayName)"
            } catch { Write-IRequireLog ("Esiasennuksen {0} poisto epaonnistui: {1}" -f $p.DisplayName, $_.Exception.Message) 'Varoitus' }
        }
        foreach ($p in @(Get-AppxPackage -AllUsers -Name $pattern -ErrorAction SilentlyContinue)) {
            if ($p.NonRemovable) { continue }
            try {
                Remove-AppxPackage -Package $p.PackageFullName -AllUsers
                Write-IRequireLog "Poistettu sovellus: $($p.Name)"
            } catch { Write-IRequireLog ("Sovelluksen {0} poisto epaonnistui: {1}" -f $p.Name, $_.Exception.Message) 'Varoitus' }
        }
    }
    $caps = @(Get-WindowsCapability -Online | Where-Object { $_.State -eq 'Installed' })
    foreach ($pattern in $debloat.Kyvyt) {
        foreach ($c in @($caps | Where-Object { $_.Name -like $pattern })) {
            try {
                Remove-WindowsCapability -Online -Name $c.Name | Out-Null
                Write-IRequireLog "Poistettu ominaisuus: $($c.Name)"
            } catch { Write-IRequireLog ("Ominaisuuden {0} poisto epaonnistui: {1}" -f $c.Name, $_.Exception.Message) 'Varoitus' }
        }
    }
    foreach ($f in $debloat.Ominaisuudet) {
        $feat = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue
        if ($feat -and $feat.State -eq 'Enabled') {
            try {
                Disable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart | Out-Null
                Write-IRequireLog "Poistettu kaytosta: $f"
            } catch { Write-IRequireLog ("Ominaisuutta {0} ei voitu poistaa kaytosta: {1}" -f $f, $_.Exception.Message) 'Varoitus' }
        }
    }
}

function Add-WlanProfile {
    $ssid = [string]$config.Wlan.Ssid
    if (-not $ssid) { return }
    $key = [string]$config.Wlan.Salasana
    $esc = { param($s) [System.Security.SecurityElement]::Escape($s) }
    $security = if ($key) {
        "<security><authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption><sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>$(& $esc $key)</keyMaterial></sharedKey></security>"
    } else {
        '<security><authEncryption><authentication>open</authentication><encryption>none</encryption><useOneX>false</useOneX></authEncryption></security>'
    }
    $xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$(& $esc $ssid)</name>
  <SSIDConfig><SSID><name>$(& $esc $ssid)</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM>$security</MSM>
</WLANProfile>
"@
    $tmp = Join-Path $env:TEMP 'irequire-wlan.xml'
    Set-Content -LiteralPath $tmp -Value $xml -Encoding UTF8
    & netsh.exe wlan add profile filename="$tmp" user=all | ForEach-Object { Write-IRequireLog ("netsh: " + $_) }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    & netsh.exe wlan connect name="$ssid" | ForEach-Object { Write-IRequireLog ("netsh: " + $_) }
}

function Invoke-StageNetwork {
    if (Test-InternetConnection) { Write-IRequireLog 'Internet-yhteys toimii' 'Ok'; return }
    Add-WlanProfile
    if (Wait-Internet -Minutes ([int]$config.Paivitykset.VerkonOdotusMinuuttia)) { Write-IRequireLog 'Internet-yhteys toimii' 'Ok'; return }
    Write-IRequireLog 'Ei internet-yhteytta: paivitykset ja sovellukset ohitetaan' 'Varoitus'
}

function Test-OnlineForStage {
    <# Kaynnistyksen jalkeen verkko nousee vasta hetken kuluttua, joten
       odotetaan ennen kuin vaihe ohitetaan verkon puuttumisen vuoksi. #>
    param([string]$What)
    if (Wait-Internet -Minutes ([int]$config.Paivitykset.VerkonOdotusMinuuttia)) { return $true }
    Write-IRequireLog "$What ohitettu: ei verkkoa" 'Varoitus'
    return $false
}

function Invoke-StageUpdates {
    param($State)
    if (-not (Test-OnlineForStage 'Paivitykset')) { return }
    $max = [int]$config.Paivitykset.MaksimiKierrokset
    while ($State.Kierros -lt $max) {
        $State.Kierros++
        Set-Status $State ("Windows Update, kierros {0}/{1}" -f $State.Kierros, $max)
        $r = Invoke-UpdateRound
        $State.Paivityksia += $r.Count
        Write-IRequireLog ("Kierros {0}: {1} paivitysta asennettu" -f $State.Kierros, $r.Count)
        if ($r.Reboot) { return (New-RebootRequest 'paivitykset vaativat uudelleenkaynnistyksen') }
        if ($r.Count -eq 0) { return }
    }
    Write-IRequireLog "Paivityskierrosten enimmaismaara ($max) taynna" 'Varoitus'
}

function Invoke-StageApps {
    param($State)
    if (-not ($config.Sovellukset.VCRedist -or $config.Sovellukset.Firefox -or $config.Sovellukset.DirectX -or $config.Sovellukset.Steam)) { return }
    if (-not (Test-OnlineForStage 'Sovellukset')) { return }
    if ($config.Sovellukset.VCRedist) {
        Set-Status $State 'Asennetaan Visual C++ -kirjastot'
        # 3010 = onnistui, vaatii uudelleenkaynnistyksen; 1638 = uudempi jo asennettu
        foreach ($arch in @('x64', 'x86')) {
            try {
                Install-SignedInstaller -Url "https://aka.ms/vs/17/release/vc_redist.$arch.exe" -Publisher 'Microsoft Corporation' `
                    -Arguments '/install /quiet /norestart' -Name "Visual C++ $arch" -OkCodes @(0, 1638, 3010)
            } catch { Write-IRequireLog $_.Exception.Message 'Varoitus' }
        }
    }
    if ($config.Sovellukset.DirectX) {
        Set-Status $State 'Asennetaan DirectX-lisakirjastot'
        try {
            Install-SignedInstaller -Url 'https://download.microsoft.com/download/1/7/1/1718CCC4-6315-4D8E-9543-8E28A4E18C4C/dxwebsetup.exe' `
                -Publisher 'Microsoft Corporation' -Arguments '/Q' -Name 'DirectX-lisakirjastot'
        } catch { Write-IRequireLog $_.Exception.Message 'Varoitus' }
    }
    if ($config.Sovellukset.Firefox) {
        Set-Status $State 'Asennetaan Firefox'
        try {
            Install-SignedInstaller -Url 'https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=fi' `
                -Publisher 'Mozilla Corporation' -Arguments '/S' -Name 'Firefox'
        } catch { Write-IRequireLog $_.Exception.Message 'Varoitus' }
    }
    if ($config.Sovellukset.Steam) {
        # Konekohtainen asennus (Program Files); Steam paivittaa itsensa
        # ensimmaisella kaynnistyksella kayttajan istunnossa.
        Set-Status $State 'Asennetaan Steam'
        try {
            Install-SignedInstaller -Url 'https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe' `
                -Publisher 'Valve' -Arguments '/S' -Name 'Steam'
        } catch { Write-IRequireLog $_.Exception.Message 'Varoitus' }
    }
}

function Invoke-UpdateRound {
    <# Yksi hakukierros Windows Updatesta (COM-rajapinta, ei lisamoduuleja).
       Palauttaa asennettujen maaran ja tarvitaanko uudelleenkaynnistys. #>
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'iRequire'
    $searcher = $session.CreateUpdateSearcher()

    $criteria = @("IsInstalled=0 and IsHidden=0 and Type='Software'")
    if ($config.Paivitykset.Ajurit) { $criteria += "IsInstalled=0 and IsHidden=0 and Type='Driver'" }

    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($c in $criteria) {
        $res = $searcher.Search($c)
        foreach ($u in $res.Updates) {
            if ($u.BrowseOnly) { continue }   # valinnaiset esiversiot
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$coll.Add($u)
            Write-IRequireLog ("  loytyi: " + $u.Title)
        }
    }
    if ($coll.Count -eq 0) { return [pscustomobject]@{ Count = 0; Reboot = $false } }

    # Suuri kumulatiivinen paivitys voi ladata ja asentua pitkaan ilman
    # nakyvaa edistysta, joten kerrotaan mita tehdaan ja kuinka paljon.
    $bytes = 0
    for ($i = 0; $i -lt $coll.Count; $i++) { $bytes += [double]$coll.Item($i).MaxDownloadSize }
    Write-IRequireLog ("Ladataan {0} paivitysta, enintaan {1:N0} Mt" -f $coll.Count, ($bytes / 1MB))
    $dl = $session.CreateUpdateDownloader()
    $dl.Updates = $coll
    $dr = $dl.Download()
    Write-IRequireLog ("Lataus valmis (tulos {0}), asennetaan" -f $dr.ResultCode)

    $inst = $session.CreateUpdateInstaller()
    $inst.Updates = $coll
    $r = $inst.Install()
    $ok = 0
    for ($i = 0; $i -lt $coll.Count; $i++) {
        $code = $r.GetUpdateResult($i).ResultCode   # 2 = onnistui, 3 = onnistui varoituksin
        if ($code -in 2, 3) { $ok++ } else { Write-IRequireLog ("  epaonnistui (koodi {0}): {1}" -f $code, $coll.Item($i).Title) 'Varoitus' }
    }
    return [pscustomobject]@{ Count = $ok; Reboot = [bool]$r.RebootRequired }
}

function Install-SignedInstaller {
    <# Lataa asennusohjelman, tarkistaa julkaisijan allekirjoituksen ja
       ajaa sen. Allekirjoittamatonta tai vaaran julkaisijan tiedostoa ei ajeta. #>
    param([string]$Url, [string]$Publisher, [string]$Arguments, [string]$Name, [int[]]$OkCodes = @(0))
    $file = Join-Path $env:TEMP ("irequire-" + [guid]::NewGuid().ToString('N') + '.exe')
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    (New-Object System.Net.WebClient).DownloadFile($Url, $file)
    try {
        $sig = Get-AuthenticodeSignature -FilePath $file
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch [regex]::Escape($Publisher)) {
            throw "$Name`: allekirjoitus ei kelpaa ($($sig.Status), $($sig.SignerCertificate.Subject))"
        }
        $p = Start-Process -FilePath $file -ArgumentList $Arguments -Wait -PassThru
        if ($OkCodes -notcontains $p.ExitCode) { throw "$Name`: asennus palautti koodin $($p.ExitCode)" }
        Write-IRequireLog "$Name asennettu" 'Ok'
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Find-UsbStick {
    foreach ($d in @(Get-PSDrive -PSProvider FileSystem)) {
        if (Test-Path -LiteralPath (Join-Path $d.Root 'iRequire\iRequire.tag')) { return $d.Root.TrimEnd('\') }
    }
    return $null
}

function Write-Summary {
    param($State)
    $os = Get-CimInstance Win32_OperatingSystem
    $problems = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -in @('Error', 'Unknown') -or $_.ConfigManagerErrorCode -ne 0 })

    $t = New-Object System.Collections.Generic.List[string]
    $t.Add('iRequire - asennuksen yhteenveto')
    $t.Add('Valmistui: ' + (Get-Date).ToString('s'))
    $t.Add('Kone:      ' + $env:COMPUTERNAME)
    $t.Add(('Windows:   {0} {1} (koontiversio {2})' -f $os.Caption, $os.Version, $os.BuildNumber))
    $t.Add('Paivityksia asennettu: ' + $State.Paivityksia)
    $t.Add('Internet:  ' + $(if (Test-InternetConnection) { 'toimii' } else { 'EI YHTEYTTA' }))
    $t.Add('')
    if ($problems.Count -gt 0) {
        $t.Add('Laitteet ilman toimivaa ajuria:')
        foreach ($p in $problems) { $t.Add(('  - {0} [{1}] {2}' -f $p.FriendlyName, $p.Class, $p.InstanceId)) }
    } else {
        $t.Add('Kaikilla laitteilla on toimiva ajuri.')
    }
    $t.Add('')
    $t.Add('PELIKUNTO')
    $inputs = Get-GamingInputs
    $timerFile = Join-Path $base 'Logs\ajastimet.txt'
    $timers = if (Test-Path -LiteralPath $timerFile) { @(Get-Content -LiteralPath $timerFile) } else { @() }
    $findings = Get-GamingFindings -Memory $inputs.Memory -Gpus $inputs.Gpus -HasBattery $inputs.HasBattery `
        -SystemDiskKind $inputs.SystemDiskKind -TimerOverrides $timers -SecureBoot $inputs.SecureBoot -Tpm $inputs.Tpm
    foreach ($level in @('Toimi', 'Huomio', 'OK')) {
        foreach ($x in @($findings.ToArray() | Where-Object { $_.Taso -eq $level })) { $t.Add(('  [{0}] {1}' -f $x.Taso.ToUpper(), $x.Teksti)) }
    }
    $t.Add('')
    $t.Add('TIETOTURVA JA ASETUKSET')
    foreach ($line in (Get-SecuritySummary)) { $t.Add('  ' + $line) }
    $t.Add('')
    foreach ($gpu in @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) {
        $t.Add(('Naytonohjain: {0} (ajuri {1})' -f $gpu.Name, $gpu.DriverVersion))
        # Windows Updaten naytonohjainajuri on toimiva mutta usein vanha. Peleihin kannattaa valmistajan oma.
        if ($gpu.Name -match 'NVIDIA') { $t.Add('  Peleihin: uusin ajuri osoitteesta https://www.nvidia.com/drivers') }
        elseif ($gpu.Name -match 'AMD|Radeon') { $t.Add('  Peleihin: uusin ajuri osoitteesta https://www.amd.com/support') }
        elseif ($gpu.Name -match 'Intel') { $t.Add('  Peleihin: uusin ajuri osoitteesta https://www.intel.com/content/www/us/en/download-center/home.html') }
        elseif ($gpu.Name -match 'Basic Display|Perusnaytto') { $t.Add('  VAROITUS: naytonohjaimelle ei loytynyt ajuria') }
    }
    $path = Join-Path $base 'Reports\yhteenveto.txt'
    $t | Set-Content -LiteralPath $path -Encoding UTF8
    Write-IRequireLog "Yhteenveto: $path" 'Ok'
}

function Add-SummaryShortcut {
    <# Yhteenveto (pelikuntoraportti) kaikkien kayttajien tyopoydalle.
       Pikakuvake eika kopio: naytot lisataan yhteenvetoon myohemmin. #>
    $target = Join-Path $base 'Reports\yhteenveto.txt'
    $desktop = Join-Path $env:PUBLIC 'Desktop'
    try {
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut((Join-Path $desktop 'iRequire - yhteenveto.lnk'))
        $lnk.TargetPath = $target
        $lnk.Description = 'Pelikuntoraportti ja tietoturvan tila'
        $lnk.Save()
        Write-IRequireLog 'Yhteenveto tyopoydalle' 'Ok'
    } catch {
        Write-IRequireLog ('Tyopoydan pikakuvake epaonnistui: ' + $_.Exception.Message) 'Varoitus'
    }
}

function Invoke-StageFinish {
    param($State)
    Write-IRequireLog 'Paivitetaan Defenderin maaritykset'
    try { Update-MpSignature -ErrorAction Stop; Write-IRequireLog 'Defenderin maaritykset paivitetty' } catch {
        Write-IRequireLog ('Defenderin maaritysten paivitys epaonnistui: ' + $_.Exception.Message) 'Varoitus'
    }

    Write-IRequireLog 'Siivotaan komponenttivarasto (vapauttaa levytilaa)'
    & dism.exe /Online /Cleanup-Image /StartComponentCleanup /Quiet | Out-Null

    if (-not $config.Asennus.AutomaattikirjautuminenPysyva) {
        $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty -LiteralPath $wl -Name AutoAdminLogon -Value '0'
        foreach ($n in @('DefaultPassword', 'AutoLogonCount')) {
            Remove-ItemProperty -LiteralPath $wl -Name $n -ErrorAction SilentlyContinue
        }
        try {
            $r = Clear-AutoLogonSecret
            if ($r -gt 1) { Write-IRequireLog "Kirjautumissalasanan LSA-salaisuutta ei voitu poistaa (virhe $r)" 'Varoitus' }
        } catch { Write-IRequireLog ('LSA-salaisuus: ' + $_.Exception.Message) 'Varoitus' }
        Write-IRequireLog 'Automaattinen kirjautuminen ja sen salasana poistettu'
    }

    # Uudet verkkoliitannat (esim. WLAN-ajuri paivityksista) saavat NetBIOSin
    # oletuksena paalle, joten ajetaan uudelleen.
    Disable-NetBios
    Write-Summary -State $State
    Add-SummaryShortcut
    Remove-Item -LiteralPath (Join-Path $base 'ASENNUS-KESKEN.tag') -Force -ErrorAction SilentlyContinue

    # Kirjoitussuojattu tikku (tai ISO) ei saa kaataa viimeistelya.
    $usb = Find-UsbStick
    if ($usb) {
        $dst = Join-Path $usb ("iRequire\Reports\{0}-{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        try {
            New-Item -ItemType Directory -Path $dst -Force | Out-Null
            Copy-Item -Path (Join-Path $base 'Reports\*') -Destination $dst -Force -ErrorAction SilentlyContinue
            Copy-Item -Path (Join-Path $base 'Logs\*.log') -Destination $dst -Force -ErrorAction SilentlyContinue
            Write-IRequireLog "Raportit kopioitu tikulle: $dst" 'Ok'
        } catch {
            Write-IRequireLog ('Raportteja ei voitu kopioida tikulle: ' + $_.Exception.Message) 'Varoitus'
        }
    }
}

function Remove-Secrets {
    <# Salasanat eivat saa jaada koneelle. Kutsutaan vasta kun tilakone on
       paassa: jos viimeistely kaatuu ja yritetaan uudelleen, uusintakierros
       tarvitsee samat asetukset (muuten se ajettaisiin oletuksilla). #>
    Remove-Item -LiteralPath (Join-Path $base 'Config\iRequire.json') -Force -ErrorAction SilentlyContinue
}

# ==============================================================
#  Paaohjelma
# ==============================================================

$state = Get-State
if ($state.Valmis) {
    # Ajastetut tehtavat jatetaan paikalleen kunnes kayttajan istunto on
    # asettanut naytot (merkki), tai viikko on kulunut. Sitten siivotaan.
    $marker = Join-Path $base 'Kayttaja\naytto-valmis.txt'
    $age = ((Get-Date) - (Get-Item -LiteralPath $stateFile).LastWriteTime).TotalDays
    if ((Test-Path -LiteralPath $marker) -or $age -gt 7) {
        # Kayttajan istunto ei saa kirjoittaa yhteenvetoon (Reports on vain
        # SYSTEMin ja jarjestelmanvalvojien), joten naytot lisataan taalta.
        $summary = Join-Path $base 'Reports\yhteenveto.txt'
        if ((Test-Path -LiteralPath $marker) -and (Test-Path -LiteralPath $summary) -and
            -not (Select-String -LiteralPath $summary -Pattern '^NAYTOT$' -Quiet)) {
            $lines = @(Get-Content -LiteralPath $marker -TotalCount 20 | Select-Object -Skip 1 | ForEach-Object { '  ' + ($_ -replace '[^\x20-\x7E]', '') })
            if ($lines.Count -gt 0) { Add-Content -LiteralPath $summary -Value (@('', 'NAYTOT') + $lines) }
        }
        Unregister-ScheduledTask -TaskName 'iRequire-edistys' -Confirm:$false -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName 'iRequire' -Confirm:$false -ErrorAction SilentlyContinue
        Write-IRequireLog 'Ajastetut tehtavat poistettu, iRequire on valmis' 'Ok'
    }
    $mutex.ReleaseMutex()
    exit 0
}

$handlers = @{
    'Kaytannot'   = { param($s) Set-Status $s 'Otetaan ryhmakaytannot kayttoon'; Invoke-StagePolicies }
    'Palvelut'    = { param($s) Set-Status $s 'Pysaytetaan telemetriapalvelut ja -ajastukset'; Invoke-StageServices }
    'Poistot'     = { param($s) Set-Status $s 'Poistetaan turhat sovellukset ja ominaisuudet'; Invoke-StageRemovals }
    'Viritys'     = { param($s) Set-Status $s 'Viritetaan suorituskyky ja tietoturva'; Invoke-StageTuning -Config $config -UsbRoot (Find-UsbStick) }
    'Verkko'      = { param($s) Set-Status $s 'Odotetaan verkkoyhteytta'; Invoke-StageNetwork }
    'Paivitykset' = { param($s) Invoke-StageUpdates -State $s }
    'Sovellukset' = { param($s) Invoke-StageApps -State $s }
    'Viimeistely' = { param($s) Set-Status $s 'Viimeistellaan'; Invoke-StageFinish -State $s }
}

try {
    $result = Invoke-StageMachine -State $state -Stages $stages -Handlers $handlers -Save { param($s) Save-State $s }
    switch ($result.Result) {
        'Reboot' { Restart-ForStage $state $result.Reason }
        default {
            Remove-Secrets
            # Tehtavat poistetaan vasta seuraavalla kaynnistyksella, kun
            # kayttajan istunto on ehtinyt asettaa naytot (ks. alku).
            Write-IRequireLog ('Jalkiasennus paattyi: ' + $result.Reason) 'Ok'
            if ($config.Asennus.LopuksiSammutus) {
                # Automaattinen testi: sammutus kertoo testiajurille etta ketju on paassa.
                # Minuutti aikaa kayttajan istunnolle nayttojen asettamiseen.
                Write-IRequireLog 'Sammutetaan (LopuksiSammutus)'
                & shutdown.exe /s /t 60 /c 'iRequire valmis, kone sammuu.'
            } elseif ($result.Result -eq 'Done') {
                Restart-ForStage $state 'asennus valmis'
            }
        }
    }
} catch {
    # Tilakone itse ei heita; tama on viimeinen turvaverkko. Ei uudelleen-
    # kaynnistysta: seuraava kaynnistys yrittaa joka tapauksessa uudelleen.
    Write-IRequireLog ('Odottamaton virhe: ' + $_.Exception.Message) 'Virhe'
} finally {
    try { $mutex.ReleaseMutex() } catch { }
}
