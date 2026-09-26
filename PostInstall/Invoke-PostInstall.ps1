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

$stateFile = Join-Path $base 'Logs\tila.json'
$stages = @('Kaytannot', 'Palvelut', 'Poistot', 'Verkko', 'Paivitykset', 'Sovellukset', 'Viimeistely')

# Estetaan kaksi samanaikaista ajoa (kaynnistystehtava + SetupCompleten kaynnistys).
$mutex = New-Object System.Threading.Mutex($false, 'Global\iRequirePostInstall')
if (-not $mutex.WaitOne(0)) { exit 0 }

Start-Log -Path (Join-Path $base 'Logs\postinstall.log')
$config = Get-IRequireConfig -Path (Join-Path $base 'Config\iRequire.json')
$debloat = Get-Content -LiteralPath (Join-Path $base 'Policies\Debloat.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-State {
    $s = $null
    if (Test-Path -LiteralPath $stateFile) {
        try { $s = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    if (-not $s) { $s = [pscustomobject]@{} }
    $defaults = [ordered]@{ Vaihe = $stages[0]; Kierros = 0; Valmis = $false; Viesti = ''; Paivityksia = 0; Virheita = 0 }
    foreach ($k in $defaults.Keys) {
        if ($s.PSObject.Properties.Name -notcontains $k) { $s | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] }
    }
    return $s
}

function Save-State {
    param($State)
    $State | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
}

function Set-Status {
    param($State, [string]$Message)
    $State.Viesti = $Message
    Save-State $State
    Write-Log $Message
}

function Restart-ForStage {
    param($State, [string]$Reason)
    Save-State $State
    Write-Log "Uudelleenkaynnistys: $Reason"
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
            Write-Log "LGPO: $f"
            $out = & $lgpo /t $f 2>&1
            $out | ForEach-Object { Write-Log ("  " + $_) }
            if ($LASTEXITCODE -ne 0) { throw "LGPO epaonnistui tiedostolle $f (koodi $LASTEXITCODE)" }
        }
    } else {
        # Varamenetelma: samat arvot suoraan rekisteriin. Toimii, mutta
        # arvot eivat nay gpeditissa kaytantoina.
        Write-Log 'LGPO.exe puuttuu, kirjoitetaan kaytannot suoraan rekisteriin' 'Varoitus'
        $userRoots = @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' |
            Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } |
            ForEach-Object { 'Registry::HKEY_USERS\' + $_.PSChildName })
        foreach ($f in $files) {
            foreach ($e in (Read-PolicyFile -Path $f)) {
                if ($e.Scope -eq 'Computer') {
                    Set-PolicyEntry -Entry $e -Root 'HKLM:\'
                } else {
                    foreach ($r in $userRoots) { Set-PolicyEntry -Entry $e -Root $r }
                }
            }
        }
    }
    & gpupdate.exe /force /wait:120 2>&1 | ForEach-Object { Write-Log ("gpupdate: " + $_) }
}

function Invoke-StageServices {
    foreach ($name in $debloat.Palvelut) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        try {
            Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
            Set-Service -Name $name -StartupType Disabled
            Write-Log "Palvelu pois kaytosta: $name"
        } catch {
            Write-Log ("Palvelua {0} ei voitu muuttaa: {1}" -f $name, $_.Exception.Message) 'Varoitus'
        }
    }
    foreach ($full in $debloat.Ajastukset) {
        $idx = $full.LastIndexOf('\')
        $path = $full.Substring(0, $idx + 1)
        $name = $full.Substring($idx + 1)
        $task = Get-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue
        if ($task) {
            $task | Disable-ScheduledTask | Out-Null
            Write-Log "Ajastus pois kaytosta: $full"
        }
    }
}

function Invoke-StageRemovals {
    foreach ($pattern in $debloat.Appx) {
        foreach ($p in @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like $pattern })) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName | Out-Null
                Write-Log "Poistettu esiasennus: $($p.DisplayName)"
            } catch { Write-Log ("Esiasennuksen {0} poisto epaonnistui: {1}" -f $p.DisplayName, $_.Exception.Message) 'Varoitus' }
        }
        foreach ($p in @(Get-AppxPackage -AllUsers -Name $pattern -ErrorAction SilentlyContinue)) {
            if ($p.NonRemovable) { continue }
            try {
                Remove-AppxPackage -Package $p.PackageFullName -AllUsers
                Write-Log "Poistettu sovellus: $($p.Name)"
            } catch { Write-Log ("Sovelluksen {0} poisto epaonnistui: {1}" -f $p.Name, $_.Exception.Message) 'Varoitus' }
        }
    }
    $caps = @(Get-WindowsCapability -Online | Where-Object { $_.State -eq 'Installed' })
    foreach ($pattern in $debloat.Kyvyt) {
        foreach ($c in @($caps | Where-Object { $_.Name -like $pattern })) {
            try {
                Remove-WindowsCapability -Online -Name $c.Name | Out-Null
                Write-Log "Poistettu ominaisuus: $($c.Name)"
            } catch { Write-Log ("Ominaisuuden {0} poisto epaonnistui: {1}" -f $c.Name, $_.Exception.Message) 'Varoitus' }
        }
    }
    foreach ($f in $debloat.Ominaisuudet) {
        $feat = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue
        if ($feat -and $feat.State -eq 'Enabled') {
            try {
                Disable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart | Out-Null
                Write-Log "Poistettu kaytosta: $f"
            } catch { Write-Log ("Ominaisuutta {0} ei voitu poistaa kaytosta: {1}" -f $f, $_.Exception.Message) 'Varoitus' }
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
    & netsh.exe wlan add profile filename="$tmp" user=all | ForEach-Object { Write-Log ("netsh: " + $_) }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    & netsh.exe wlan connect name="$ssid" | ForEach-Object { Write-Log ("netsh: " + $_) }
}

function Invoke-StageNetwork {
    if (Test-InternetConnection) { Write-Log 'Internet-yhteys toimii' 'Ok'; return $true }
    Add-WlanProfile
    $deadline = (Get-Date).AddMinutes([int]$config.Paivitykset.VerkonOdotusMinuuttia)
    while ((Get-Date) -lt $deadline) {
        if (Test-InternetConnection) { Write-Log 'Internet-yhteys toimii' 'Ok'; return $true }
        Start-Sleep -Seconds 10
    }
    Write-Log 'Ei internet-yhteytta: paivitykset ja sovellukset ohitetaan' 'Varoitus'
    return $false
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
            Write-Log ("  loytyi: " + $u.Title)
        }
    }
    if ($coll.Count -eq 0) { return [pscustomobject]@{ Count = 0; Reboot = $false } }

    $dl = $session.CreateUpdateDownloader()
    $dl.Updates = $coll
    [void]$dl.Download()

    $inst = $session.CreateUpdateInstaller()
    $inst.Updates = $coll
    $r = $inst.Install()
    $ok = 0
    for ($i = 0; $i -lt $coll.Count; $i++) {
        $code = $r.GetUpdateResult($i).ResultCode   # 2 = onnistui, 3 = onnistui varoituksin
        if ($code -in 2, 3) { $ok++ } else { Write-Log ("  epaonnistui (koodi {0}): {1}" -f $code, $coll.Item($i).Title) 'Varoitus' }
    }
    return [pscustomobject]@{ Count = $ok; Reboot = [bool]$r.RebootRequired }
}

function Install-Firefox {
    $url = 'https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=fi'
    $file = Join-Path $env:TEMP 'firefox-setup.exe'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    (New-Object System.Net.WebClient).DownloadFile($url, $file)
    $sig = Get-AuthenticodeSignature -FilePath $file
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Mozilla Corporation') {
        Remove-Item -LiteralPath $file -Force
        throw "Firefox-asennusohjelman allekirjoitus ei kelpaa ($($sig.Status))"
    }
    $p = Start-Process -FilePath $file -ArgumentList '/S' -Wait -PassThru
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0) { throw "Firefox-asennus palautti koodin $($p.ExitCode)" }
    Write-Log 'Firefox asennettu' 'Ok'
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
    $path = Join-Path $base 'Reports\yhteenveto.txt'
    $t | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Log "Yhteenveto: $path" 'Ok'
}

function Invoke-StageFinish {
    param($State)
    try { Update-MpSignature -ErrorAction Stop; Write-Log 'Defenderin maaritykset paivitetty' } catch { }

    Write-Log 'Siivotaan komponenttivarasto (vapauttaa levytilaa)'
    & dism.exe /Online /Cleanup-Image /StartComponentCleanup /Quiet | Out-Null

    if (-not $config.Asennus.AutomaattikirjautuminenPysyva) {
        $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty -LiteralPath $wl -Name AutoAdminLogon -Value '0'
        foreach ($n in @('DefaultPassword', 'AutoLogonCount')) {
            Remove-ItemProperty -LiteralPath $wl -Name $n -ErrorAction SilentlyContinue
        }
        Write-Log 'Automaattinen kirjautuminen poistettu'
    }

    Write-Summary -State $State
    Remove-Item -LiteralPath (Join-Path $base 'ASENNUS-KESKEN.tag') -Force -ErrorAction SilentlyContinue

    $usb = Find-UsbStick
    if ($usb) {
        $dst = Join-Path $usb ("iRequire\Reports\{0}-{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        Copy-Item -Path (Join-Path $base 'Reports\*') -Destination $dst -Force -ErrorAction SilentlyContinue
        Copy-Item -Path (Join-Path $base 'Logs\*.log') -Destination $dst -Force -ErrorAction SilentlyContinue
        Write-Log "Raportit kopioitu tikulle: $dst" 'Ok'
    }
}

# ==============================================================
#  Paaohjelma
# ==============================================================

$state = Get-State
if ($state.Valmis) { $mutex.ReleaseMutex(); exit 0 }
$online = $true

try {
    for ($i = [Array]::IndexOf($stages, [string]$state.Vaihe); $i -lt $stages.Count; $i++) {
        $state.Vaihe = $stages[$i]
        switch ($state.Vaihe) {
            'Kaytannot'   { Set-Status $state 'Otetaan ryhmakaytannot kayttoon'; Invoke-StagePolicies }
            'Palvelut'    { Set-Status $state 'Pysaytetaan telemetriapalvelut ja -ajastukset'; Invoke-StageServices }
            'Poistot'     { Set-Status $state 'Poistetaan turhat sovellukset ja ominaisuudet'; Invoke-StageRemovals }
            'Verkko'      { Set-Status $state 'Odotetaan verkkoyhteytta'; $online = Invoke-StageNetwork }
            'Paivitykset' {
                if (-not $online -and -not (Test-InternetConnection)) { Write-Log 'Paivitykset ohitettu: ei verkkoa' 'Varoitus'; break }
                while ($state.Kierros -lt [int]$config.Paivitykset.MaksimiKierrokset) {
                    $state.Kierros++
                    Set-Status $state ("Windows Update, kierros {0}/{1}" -f $state.Kierros, $config.Paivitykset.MaksimiKierrokset)
                    $r = Invoke-UpdateRound
                    $state.Paivityksia += $r.Count
                    Write-Log ("Kierros {0}: {1} paivitysta asennettu" -f $state.Kierros, $r.Count)
                    if ($r.Reboot) { Restart-ForStage $state 'paivitykset vaativat uudelleenkaynnistyksen' }
                    if ($r.Count -eq 0) { break }
                }
            }
            'Sovellukset' {
                if ($config.Sovellukset.Firefox -and (Test-InternetConnection)) {
                    Set-Status $state 'Asennetaan Firefox'
                    try { Install-Firefox } catch { Write-Log ('Firefox: ' + $_.Exception.Message) 'Varoitus' }
                }
            }
            'Viimeistely' { Set-Status $state 'Viimeistellaan'; Invoke-StageFinish -State $state }
        }
        # Seuraava vaihe talteen heti, ettei valmista vaihetta ajeta turhaan uudelleen.
        if ($i + 1 -lt $stages.Count) {
            $state.Vaihe = $stages[$i + 1]
            if ($state.Vaihe -eq 'Paivitykset') { $state.Kierros = 0 }
        }
        $state.Virheita = 0
        Save-State $state
    }

    $state.Valmis = $true
    Set-Status $state 'Valmis'
    Unregister-ScheduledTask -TaskName 'iRequire' -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'iRequire-edistys' -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log 'Jalkiasennus valmis' 'Ok'
    Restart-ForStage $state 'asennus valmis'
} catch {
    Write-Log ("VIRHE vaiheessa {0}: {1}" -f $state.Vaihe, $_.Exception.Message) 'Virhe'
    Write-Log ($_.ScriptStackTrace) 'Virhe'
    # Sama vaihe yritetaan kerran uudelleen; toisen virheen jalkeen se
    # ohitetaan, jottei yksi rikkinainen kohta pysayta koko asennusta.
    $state.Virheita++
    $idx = [Array]::IndexOf($stages, [string]$state.Vaihe)
    if ($state.Virheita -ge 2) {
        Write-Log ("Vaihe {0} ohitetaan toistuvan virheen vuoksi" -f $state.Vaihe) 'Varoitus'
        $state.Virheita = 0
        if ($idx -ge 0 -and $idx + 1 -lt $stages.Count) {
            $state.Vaihe = $stages[$idx + 1]
        } else {
            # Viimeinen vaihe: lopetetaan kokonaan, ei uudelleenkaynnistyssilmukkaa.
            $state.Valmis = $true
            Set-Status $state 'Valmis (viimeistely epaonnistui, katso loki)'
            Unregister-ScheduledTask -TaskName 'iRequire' -Confirm:$false -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName 'iRequire-edistys' -Confirm:$false -ErrorAction SilentlyContinue
            return
        }
    }
    Restart-ForStage $state ("virhe vaiheessa {0}, yritetaan uudelleen" -f $state.Vaihe)
} finally {
    try { $mutex.ReleaseMutex() } catch { }
}
