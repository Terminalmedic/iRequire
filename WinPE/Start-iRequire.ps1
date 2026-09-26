#requires -Version 5.1
<#
.SYNOPSIS
    iRequiren WinPE-vaihe: laskuri -> levyjen tyhjennys -> Windowsin asennus.

.DESCRIPTION
    Kaynnistyy automaattisesti tikulta (winpeshl.ini -> Bootstrap.ps1).
    Ainoa kohta jossa ihminen voi puuttua on laskuri: Esc peruu kaiken.
    Virhetilanteessa kone jaa odottamaan eika kaynnisty uudelleen, jottei
    se jaa silmukkaan.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UsbRoot
)

$ErrorActionPreference = 'Stop'
$UsbRoot = $UsbRoot.TrimEnd('\')
$base = Join-Path $UsbRoot 'iRequire'

. (Join-Path $base 'Lib\Common.ps1')
. (Join-Path $base 'WinPE\Disk.ps1')
. (Join-Path $base 'WinPE\Deploy.ps1')

$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportDir = Join-Path $base "Reports\$runId"
Start-Log -Path (Join-Path $reportDir 'winpe.log')
$config = Get-IRequireConfig -Path (Join-Path $base 'Config\iRequire.json')

try { & powercfg.exe /s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>&1 | Out-Null } catch { }

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
    Write-Host ''
    Write-Host $Reason -ForegroundColor Yellow
    Write-Host 'Enter = sammuta kone   K = komentokehote' -ForegroundColor Yellow
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Enter') { & wpeutil.exe shutdown; exit 0 }
        if ($k.Key -eq 'K') { & cmd.exe; }
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

try {
    Clear-Host
    Write-Host ''
    Write-Host '  iRequire' -ForegroundColor Cyan
    Write-Host '  levyn tyhjennys ja Windowsin asennus' -ForegroundColor DarkGray
    Write-Host ''

    # --- 1. Keskenerainen asennus? Ei tyhjenneta vahingossa uudelleen ---
    $pending = Find-PendingInstall
    if ($pending) {
        Write-Log "Keskenerainen iRequire-asennus loytyi asemalta $pending" 'Varoitus'
        Write-Host ''
        Write-Host 'Tama kone on jo asennettu talla tikulla ja asennus on viela kesken.' -ForegroundColor Yellow
        Write-Host 'Kone kaynnistetaan kiintolevylta. Irrota tikku.' -ForegroundColor Yellow
        Write-Host 'Paina T 15 sekunnin kuluessa, jos haluat silti tyhjentaa ja asentaa alusta.' -ForegroundColor Yellow
        $k = Wait-Key -Seconds 15
        if (-not $k -or $k.Key -ne 'T') {
            Set-InternalBootFirst
            & wpeutil.exe reboot
            exit 0
        }
        Write-Log 'Kayttaja valitsi uuden asennuksen keskeneraisen paalle' 'Varoitus'
    }

    # --- 2. Levyt ja laskuri ---
    $usbDisk = Get-UsbBootDiskNumber -UsbRoot $UsbRoot
    $disks = Get-InternalDisks -ExcludeNumber $usbDisk
    if ($disks.Count -eq 0) { Stop-Here 'Sisaisia levyja ei loytynyt. Puuttuuko tallennusohjaimen ajuri (esim. Intel RST/VMD)?' }

    $target = Select-TargetDisk -Disks $disks -MinimumGb ([int]$config.Tyhjennys.MinimikokoGt)
    if (-not $target) { Stop-Here ("Yksikaan levy ei ole vahintaan {0} Gt." -f $config.Tyhjennys.MinimikokoGt) }

    $toWipe = if ($config.Tyhjennys.KaikkiSisaisetLevyt) { $disks.ToArray() } else { @($target) }
    $machine = Get-MachineIdentity
    if ($machine) { Write-Host "  Kone: $machine" }
    Write-Host ''

    foreach ($d in $toWipe) {
        $role = if ($d.Number -eq $target.Number) { '  <- Windows asennetaan tahan' } else { '' }
        Write-Host ('  LEVY {0}: {1}' -f $d.Number, $d.Model) -ForegroundColor White -NoNewline
        Write-Host $role -ForegroundColor Cyan
        Write-Host ('    {0}, {1} / {2}, sarjanumero {3}' -f (Format-Size $d.Size), $d.Bus, $d.Kind, $d.Serial) -ForegroundColor Gray
        foreach ($ln in (Get-DiskContentSummary -Number $d.Number)) { Write-Host ('    ' + $ln) -ForegroundColor DarkGray }
        Write-Host ''
    }

    Write-Host '  KAIKKI YLLA LUETELTUJEN LEVYJEN TIEDOT TUHOTAAN PYSYVASTI.' -ForegroundColor Red
    $seconds = [int]$config.Tyhjennys.LaskuriSekuntia
    $top = [Console]::CursorTop
    $key = Wait-Key -Seconds $seconds -OnTick {
        param($left)
        [Console]::SetCursorPosition(0, $top)
        Write-Host ('  Tyhjennys alkaa {0,3} s kuluttua. Esc peruu.   ' -f $left) -ForegroundColor Yellow -NoNewline
    }
    Write-Host ''
    if ($key -and $key.Key -eq 'Escape') {
        Write-Log 'Kayttaja perui laskurin aikana' 'Varoitus'
        Stop-Here 'Peruttu. Levyihin ei koskettu.'
    }

    # --- 3. Tyhjennys ---
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($d in $toWipe) {
        $records.Add((Invoke-DiskWipe -Disk $d -SampleCount ([int]$config.Tyhjennys.Naytteita)))
    }
    $cert = Write-WipeCertificate -Records $records.ToArray() -Directory $reportDir -Machine $machine
    Write-Log "Tyhjennystodistus: $cert" 'Ok'

    $failed = @($records.ToArray() | Where-Object { $_.Varmistus -ne 'HYVAKSYTTY' })
    if ($failed.Count -gt 0) {
        Stop-Here ('Tyhjennyksen varmistus epaonnistui levyilla: ' + (($failed | ForEach-Object { $_.Levy }) -join ', ') + '. Asennusta ei aloitettu.')
    }

    # --- 4. Asennus ---
    $firmware = Get-FirmwareType
    Write-Log "Laiteohjelmisto: $firmware, kohdelevy $($target.Number)"
    $parts = New-WindowsPartitions -Number $target.Number -Firmware $firmware -WorkDir $env:TEMP
    Install-WindowsImage -UsbRoot $UsbRoot -Target $parts.Windows
    Add-MachineDrivers -UsbRoot $UsbRoot -Target $parts.Windows
    Copy-Payload -UsbRoot $UsbRoot -Target $parts.Windows -Config $config -ReportsDir $reportDir
    Set-BootFiles -Windows $parts.Windows -System $parts.System -Firmware $firmware

    Write-Log 'WinPE-vaihe valmis, kaynnistetaan uudelleen' 'Ok'
    Copy-Item -LiteralPath $script:LogFile -Destination (Join-Path $parts.Windows 'iRequire\Logs') -Force -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '  Valmis. Kone kaynnistyy uudelleen ja asennus jatkuu itsestaan.' -ForegroundColor Green
    Write-Host '  Tikun voi irrottaa nyt.' -ForegroundColor Green
    Start-Sleep -Seconds 5
    & wpeutil.exe reboot
} catch {
    Write-Log ('VIRHE: ' + $_.Exception.Message) 'Virhe'
    Write-Log ($_.ScriptStackTrace) 'Virhe'
    Stop-Here 'Asennus pysahtyi virheeseen. Loki on tikulla kansiossa iRequire\Reports.'
}
