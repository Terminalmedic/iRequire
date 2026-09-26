#requires -Version 5.1
<#
.SYNOPSIS
    iRequiren WinPE-vaihe: tarkistukset -> laskuri -> tyhjennys -> asennus.

.DESCRIPTION
    Kaynnistyy automaattisesti tikulta (winpeshl.ini -> Bootstrap.ps1).
    Ainoa kohta jossa ihminen voi puuttua on laskuri: Esc peruu kaiken.

    Jarjestys on valittu niin, ettei koneen levyihin kosketa ennen kuin
    kaikki mika voidaan tarkistaa etukateen on tarkistettu: tikun eheys,
    asennuskuva, kohdelevy ja virransyotto. Virhetilanteessa kone jaa
    odottamaan eika kaynnisty uudelleen, jottei se jaa silmukkaan.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UsbRoot
)

$ErrorActionPreference = 'Stop'
$UsbRoot = $UsbRoot.TrimEnd('\')
$base = Join-Path $UsbRoot 'iRequire'

. (Join-Path $base 'Lib\Common.ps1')
. (Join-Path $base 'Lib\Media.ps1')
. (Join-Path $base 'WinPE\Disk.ps1')
. (Join-Path $base 'WinPE\Deploy.ps1')

$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportDir = Get-WritableDirectory -Candidates @((Join-Path $base "Reports\$runId"), (Join-Path $env:SystemDrive "iRequire\Reports\$runId"))
Start-Log -Path (Join-Path $reportDir 'winpe.log')
if ($reportDir -notlike "$UsbRoot*") { Write-IRequireLog 'Tikulle ei voi kirjoittaa (kirjoitussuojattu tai ISO): raportit tallennetaan vain asennettavalle koneelle' 'Varoitus' }
$config = Get-IRequireConfig -Path (Join-Path $base 'Config\iRequire.json')
if ($config.Asennus.LokiSarjaporttiin) { Enable-SerialLog; Write-IRequireLog 'WinPE: sarjaporttiloki kaytossa' }
$dryRun = [bool]$config.Tyhjennys.Harjoitus

try { Invoke-Native powercfg.exe @('/s', '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') | Out-Null } catch { }

function Wait-Key {
    <# Odottaa enintaan $Seconds sekuntia. Palauttaa painetun napin tai $null. #>
    param([int]$Seconds, [scriptblock]$OnTick)
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        if ($OnTick) { & $OnTick ([int][Math]::Ceiling(($end - (Get-Date)).TotalSeconds)) }
        $until = (Get-Date).AddMilliseconds(250)
        while ((Get-Date) -lt $until) {
            if ([Console]::KeyAvailable) { return [Console]::ReadKey($true) }
            Start-Sleep -Milliseconds 50
        }
    }
    return $null
}

function Stop-Here {
    <# Pysahdys: ei uudelleenkaynnistysta, koska se voisi kaynnistaa
       saman tikun uudelleen. #>
    param([string]$Reason)
    Write-IRequireLog ('Pysahdyttiin: ' + $Reason) 'Varoitus'
    Write-Host ''
    Write-Host $Reason -ForegroundColor Yellow
    Write-Host 'Enter = sammuta kone   K = komentokehote' -ForegroundColor Yellow
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Enter') { & wpeutil.exe shutdown; exit 0 }
        if ($k.Key -eq 'K') { & cmd.exe }
    }
}

function Get-MachineIdentity {
    try {
        $p = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop
        $b = Get-CimInstance Win32_BIOS -ErrorAction Stop
        return ('{0} {1}, sarjanumero {2}' -f $p.Vendor, $p.Name, $b.SerialNumber).Trim()
    } catch {
        return ''
    }
}

function Wait-ForAcPower {
    <# Tyhjennys voi kestaa tunteja. Jos kannettava on akulla, odotetaan
       laturia. J jatkaa silti. Koneet ilman akkua ohittavat taman. #>
    $bat = $null
    try { $bat = @(Get-CimInstance Win32_Battery -ErrorAction Stop) } catch { return }
    if (-not $bat -or $bat.Count -eq 0) { return }
    if (@($bat | Where-Object { $_.BatteryStatus -ne 1 }).Count -gt 0) { return }   # 1 = purkautuu

    Write-IRequireLog ('Kone on akkukaytossa ({0} %)' -f $bat[0].EstimatedChargeRemaining) 'Varoitus'
    Write-Host ''
    Write-Host '  Kone on akun varassa. Kytke laturi - jatketaan heti kun virta tulee.' -ForegroundColor Yellow
    Write-Host '  J = jatka silti akulla' -ForegroundColor DarkGray
    while ($true) {
        $k = Wait-Key -Seconds 5
        if ($k -and $k.Key -eq 'J') { Write-IRequireLog 'Jatketaan akulla kayttajan valinnasta' 'Varoitus'; return }
        try {
            $bat = @(Get-CimInstance Win32_Battery -ErrorAction Stop)
            if (@($bat | Where-Object { $_.BatteryStatus -ne 1 }).Count -gt 0) { Write-IRequireLog 'Laturi kytketty' 'Ok'; return }
        } catch { return }
    }
}

try {
    Clear-Host
    Write-Host ''
    Write-Host '  iRequire' -ForegroundColor Cyan
    Write-Host '  levyn tyhjennys ja Windowsin asennus' -ForegroundColor DarkGray
    if ($dryRun) { Write-Host '  HARJOITUSTILA - levyihin ei kirjoiteta mitaan' -ForegroundColor Magenta }
    Write-Host ''

    # --- 1. Keskenerainen asennus? Ei tyhjenneta vahingossa uudelleen ---
    $pending = Find-PendingInstall
    if ($pending -and -not $dryRun) {
        Write-IRequireLog "Keskenerainen iRequire-asennus loytyi asemalta $pending" 'Varoitus'
        Write-Host 'Tama kone on jo asennettu talla tikulla ja asennus on viela kesken.' -ForegroundColor Yellow
        Write-Host 'Kone kaynnistetaan kiintolevylta. Irrota tikku.' -ForegroundColor Yellow
        Write-Host 'Paina T 15 sekunnin kuluessa, jos haluat silti tyhjentaa ja asentaa alusta.' -ForegroundColor Yellow
        $k = Wait-Key -Seconds 15
        if (-not $k -or $k.Key -ne 'T') {
            Set-InternalBootFirst
            & wpeutil.exe reboot
            exit 0
        }
        Write-IRequireLog 'Kayttaja valitsi uuden asennuksen keskeneraisen paalle' 'Varoitus'
    }

    # --- 2. Tikun eheys: rikkinainen kopio huomataan ennen tyhjennysta ---
    if ($config.Tyhjennys.TarkistaMedia) {
        Write-Host '  Tarkistetaan tikun eheys...' -ForegroundColor Gray
        $problems = Test-MediaManifest -MediaRoot $UsbRoot
        if ($problems.Count -gt 0) {
            $problems | ForEach-Object { Write-IRequireLog $_ 'Virhe' }
            Stop-Here ('Tikun tiedostot ovat vioittuneet ({0} ongelmaa, ks. loki). Levyihin ei koskettu. Kirjoita tikku uudelleen New-iRequireUsb.ps1:lla.' -f $problems.Count)
        }
        Write-IRequireLog 'Tikun eheys tarkistettu' 'Ok'
    } else {
        Write-IRequireLog 'Tikun eheystarkistus ohitettu asetuksista' 'Varoitus'
    }
    $image = Get-InstallImage -UsbRoot $UsbRoot
    Write-IRequireLog ('Asennuskuva: ' + $image.File)

    # --- 3. Levyt ---
    $usbDisk = Get-UsbBootDiskNumber -UsbRoot $UsbRoot
    $inventory = Get-DiskInventory -ExcludeNumber $usbDisk
    $disks = $inventory.Internal
    if ($disks.Count -eq 0) {
        Stop-Here 'Sisaisia levyja ei loytynyt. Todennakoisin syy: tallennusohjaimen ajuri puuttuu (Intel RST/VMD). Lisaa ajuri kansioon Build\Drivers\WinPE ja rakenna uudelleen, tai vaihda BIOSista SATA-tilaksi AHCI.'
    }

    $target = Select-TargetDisk -Disks $disks -MinimumGb ([int]$config.Tyhjennys.MinimikokoGt)
    if (-not $target) { Stop-Here ("Yksikaan levy ei ole vahintaan {0} Gt." -f $config.Tyhjennys.MinimikokoGt) }

    $firmware = Get-FirmwareType
    if ($firmware -eq 'BIOS' -and $target.Size -gt 2TB) {
        Write-IRequireLog 'BIOS-tilassa MBR-osiointi kayttaa vain 2 Tt levysta. Vaihda BIOSista UEFI-tila jos mahdollista.' 'Varoitus'
    }

    $toWipe = if ($config.Tyhjennys.KaikkiSisaisetLevyt) { $disks } else { @($target) }
    $machine = Get-MachineIdentity
    if ($machine) { Write-Host "  Kone: $machine" }
    Write-Host ("  Kaynnistystila: {0}" -f $firmware) -ForegroundColor DarkGray
    Write-Host ''

    foreach ($d in $toWipe) {
        $role = if ($d.Number -eq $target.Number) { '  <- Windows asennetaan tahan' } else { '' }
        Write-Host ('  LEVY {0}: {1}' -f $d.Number, $d.Model) -ForegroundColor White -NoNewline
        Write-Host $role -ForegroundColor Cyan
        Write-Host ('    {0}, {1} / {2}, sarjanumero {3}' -f (Format-Size $d.Size), $d.Bus, $d.Kind, $d.Serial) -ForegroundColor Gray
        foreach ($ln in (Get-DiskContentSummary -Number $d.Number)) { Write-Host ('    ' + $ln) -ForegroundColor DarkGray }
        Write-Host ''
        Write-IRequireLog ('Tyhjennettava levy {0}: {1} {2} {3} {4}' -f $d.Number, $d.Model, $d.Serial, $d.Kind, (Format-Size $d.Size))
    }
    foreach ($d in $inventory.Skipped) {
        Write-Host ('  Ei kosketa: levy {0} {1} ({2}, {3})' -f $d.Number, $d.Model, (Format-Size $d.Size), $d.Reason) -ForegroundColor DarkGreen
        Write-IRequireLog ('Ei kosketa: levy {0} {1} ({2})' -f $d.Number, $d.Model, $d.Reason)
    }
    Write-Host ''

    # --- 4. Laskuri ---
    if ($dryRun) {
        Write-Host '  HARJOITUS: naissa levyissa tiedot tuhottaisiin. Nyt ei tuhota.' -ForegroundColor Magenta
    } else {
        Write-Host '  KAIKKI YLLA LUETELTUJEN LEVYJEN TIEDOT TUHOTAAN PYSYVASTI.' -ForegroundColor Red
    }
    $seconds = [Math]::Max(5, [int]$config.Tyhjennys.LaskuriSekuntia)
    $top = [Console]::CursorTop
    $key = Wait-Key -Seconds $seconds -OnTick {
        param($left)
        [Console]::SetCursorPosition(0, $top)
        Write-Host ('  Alkaa {0,3} s kuluttua. Esc peruu.   ' -f $left) -ForegroundColor Yellow -NoNewline
    }
    Write-Host ''
    if ($key -and $key.Key -eq 'Escape') {
        Write-IRequireLog 'Kayttaja perui laskurin aikana' 'Varoitus'
        Stop-Here 'Peruttu. Levyihin ei koskettu.'
    }

    if (-not $dryRun -and $config.Tyhjennys.OdotaVerkkovirtaa) { Wait-ForAcPower }

    # --- 5. Harjoitus: kaikki lukutestit, ei kirjoituksia ---
    if ($dryRun) {
        [void](Initialize-Native)
        foreach ($d in $toWipe) {
            $samples = Read-DiskSamples -Number $d.Number -Offsets (Get-SampleOffsets -Size $d.Size -Count 16)
            $errs = @($samples.ToArray() | Where-Object { $_.Error }).Count
            $lvl = if ($errs -eq 0) { 'Ok' } else { 'Virhe' }
            Write-IRequireLog ('HARJOITUS levy {0}: suora luku {1}/16 onnistui, menetelma olisi {2}' -f $d.Number, (16 - $errs),
                $(if (Test-FlashKind $d.Kind) { 'laitteen oma tyhjennys, varalla nollat + TRIM' } elseif ($d.Kind -eq 'HDD') { 'nollat' } else { 'nollat + TRIM' })) $lvl
        }
        $letters = Get-FreeDriveLetters -Count 2
        Write-IRequireLog ('HARJOITUS: asennus levylle {0} ({1}), asemakirjaimet {2}' -f $target.Number, $firmware, ($letters -join ', ')) 'Ok'
        Stop-Here "Harjoitus valmis. Mitaan ei muutettu. Loki: $reportDir"
    }

    # --- 6. Tyhjennys ---
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($d in $toWipe) {
        $records.Add((Invoke-DiskWipe -Disk $d -SampleCount ([int]$config.Tyhjennys.Naytteita) -FullVerify:([bool]$config.Tyhjennys.TaysiVarmistus)))
    }
    $cert = Write-WipeCertificate -Records $records.ToArray() -Directory $reportDir -Machine $machine
    Write-IRequireLog "Tyhjennystodistus: $cert" 'Ok'

    $failed = @($records.ToArray() | Where-Object { $_.Varmistus -ne 'HYVAKSYTTY' })
    if ($failed.Count -gt 0) {
        $msgs = $failed | ForEach-Object { 'levy {0}: {1}' -f $_.Levy, $_.Huomio }
        Stop-Here ('Tyhjennyksen varmistus epaonnistui. Asennusta ei aloitettu.' + [Environment]::NewLine + ($msgs -join [Environment]::NewLine))
    }

    # --- 7. Asennus ---
    Write-IRequireLog "Laiteohjelmisto: $firmware, kohdelevy $($target.Number)"
    $parts = New-WindowsPartitions -Number $target.Number -Firmware $firmware -WorkDir $env:TEMP
    Install-WindowsImage -UsbRoot $UsbRoot -Target $parts.Windows
    Add-MachineDrivers -UsbRoot $UsbRoot -Target $parts.Windows
    Copy-Payload -UsbRoot $UsbRoot -Target $parts.Windows -Config $config -ReportsDir $reportDir
    Set-BootFiles -Windows $parts.Windows -System $parts.System -Firmware $firmware
    Test-Deployment -Windows $parts.Windows -System $parts.System -Firmware $firmware

    Write-IRequireLog 'WinPE-vaihe valmis, kaynnistetaan uudelleen' 'Ok'
    Copy-Item -LiteralPath $script:LogFile -Destination (Join-Path $parts.Windows 'iRequire\Logs') -Force -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '  Valmis. Kone kaynnistyy uudelleen ja asennus jatkuu itsestaan.' -ForegroundColor Green
    Write-Host '  Tikun voi irrottaa nyt.' -ForegroundColor Green
    Start-Sleep -Seconds 5
    & wpeutil.exe reboot
} catch {
    Write-IRequireLog ('VIRHE: ' + $_.Exception.Message) 'Virhe'
    Write-IRequireLog ($_.ScriptStackTrace) 'Virhe'
    Stop-Here "Asennus pysahtyi virheeseen: $($_.Exception.Message)`nLoki: $reportDir"
}
