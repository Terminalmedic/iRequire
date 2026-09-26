#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Esitarkistus kohdekoneella ennen iRequire-ajoa. Ei muuta konetta.

.DESCRIPTION
    Ajetaan koneen nykyisessa Windowsissa jarjestelmanvalvojana, esim.
    suoraan tikulta:  <tikku>:\iRequire\Tools\Test-TargetMachine.ps1

    Kertoo:
      - kumpi Secure Boot -varmenne tikulle (Build-iRequire.ps1 -SecureBootCA)
      - tarvitseeko levyohjain oman ajurin (Intel RST/VMD), ja -ExportDrivers
        vie sen tikulle, jolloin WinPE nakee levyt ja asennettu Windows
        kaynnistyy
      - TPM, Secure Boot ja pelikuntohavainnot (RAM, naytot ...)
      - levyt, jotka tyhjennettaisiin

.PARAMETER ExportDrivers
    Vie kolmannen osapuolen levyohjainajurit (pnputil /export-driver)
    tikun iRequire\Drivers-kansioon, tai repossa Build\Drivers\WinPE:hen
    (menee seka WinPE:hen etta asennukseen).
#>
[CmdletBinding()]
param([switch]$ExportDrivers)

$ErrorActionPreference = 'Stop'
$base = Split-Path -Parent $PSScriptRoot
. (Join-Path $base 'Lib\Common.ps1')
. (Join-Path $base 'Lib\Readiness.ps1')
function Write-IRequireLog { param([string]$Message, [string]$Level) }

$onStick = Test-Path -LiteralPath (Join-Path $base 'iRequire.tag')
$driverDir = if ($onStick) { Join-Path $base 'Drivers' } else { Join-Path $base 'Build\Drivers\WinPE' }

function Show-Line {
    param([ValidateSet('OK', 'HUOMIO', 'TOIMI', 'INFO')][string]$Level, [string]$Text)
    $color = @{ OK = 'Green'; HUOMIO = 'Yellow'; TOIMI = 'Red'; INFO = 'Gray' }[$Level]
    Write-Host ('  [{0,-6}] {1}' -f $Level, $Text) -ForegroundColor $color
}

Write-Host ''
Write-Host '=== iRequire: koneen esitarkistus ===' -ForegroundColor Cyan
Write-Host ''

# --- Secure Boot -varmenne (KB5025885) ---
Write-Host 'Secure Boot' -ForegroundColor Cyan
$inputs = Get-GamingInputs
$db2023 = $null; $revoked = $null
if ($inputs.SecureBoot -eq 'On') {
    try { $db2023 = [System.Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI -Name db).Bytes) -match 'Windows UEFI CA 2023' } catch { }
    try { $revoked = [System.Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI -Name dbx).Bytes) -match 'Microsoft Windows Production PCA 2011' } catch { }
}
Show-Line 'INFO' ("Secure Boot: {0}" -f $(switch ($inputs.SecureBoot) { 'On' { 'paalla' } 'Off' { 'pois' } 'Legacy' { 'ei kaytettavissa (BIOS/CSM)' } default { 'tuntematon' } }))
if ($null -ne $db2023) { Show-Line 'INFO' ("'Windows UEFI CA 2023' laiteohjelmiston DB:ssa: {0}" -f $(if ($db2023) { 'kylla' } else { 'ei' })) }
if ($null -ne $revoked) { Show-Line 'INFO' ("Vanhat (PCA 2011) kaynnistyksenhallinnat mitatoity: {0}" -f $(if ($revoked) { 'kylla' } else { 'ei' })) }
$ca = Get-SecureBootCaAdvice -SecureBoot $inputs.SecureBoot -Db2023 $db2023 -Pca2011Revoked $revoked
$lvl = if ($ca.Varma) { 'OK' } else { 'HUOMIO' }
Show-Line $lvl ("Tikun varmenne: {0}. {1}" -f $ca.Ca, $ca.Syy)
if ($ca.Ca -eq '2023') { Show-Line 'TOIMI' 'Rakenna tikku: .\Build\Build-iRequire.ps1 -IsoPath <iso> -SecureBootCA 2023' }
Write-Host ''

# --- Levyohjaimen ajuri ---
Write-Host 'Levyohjain' -ForegroundColor Cyan
$needed = New-Object System.Collections.Generic.List[object]
foreach ($dev in @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { @('SCSIAdapter', 'HDC') -contains $_.Class })) {
    $inf = ''
    try { $inf = [string](Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction Stop).Data } catch { }
    if (Test-ThirdPartyStorageDriver -InfPath $inf -Class $dev.Class) {
        $needed.Add([pscustomobject]@{ Name = $dev.FriendlyName; Inf = $inf })
        Show-Line 'HUOMIO' ("{0}: valmistajan ajuri ({1}), jota WinPE:ssa ei ole" -f $dev.FriendlyName, $inf)
    } else {
        Show-Line 'OK' ("{0}: Windowsin oma ajuri" -f $dev.FriendlyName)
    }
}
if ($needed.Count -gt 0) {
    if ($ExportDrivers) {
        New-Item -ItemType Directory -Path $driverDir -Force | Out-Null
        foreach ($n in @($needed | Sort-Object Inf -Unique)) {
            $dst = Join-Path $driverDir ([System.IO.Path]::GetFileNameWithoutExtension($n.Inf))
            New-Item -ItemType Directory -Path $dst -Force | Out-Null
            $r = Invoke-Native pnputil.exe @('/export-driver', $n.Inf, $dst)
            if ($r.ExitCode -eq 0) { Show-Line 'OK' "Ajuri viety: $dst" }
            else { Show-Line 'TOIMI' ("Ajurin {0} vienti epaonnistui: {1}" -f $n.Inf, ($r.Output -join ' ')) }
        }
    } else {
        Show-Line 'TOIMI' 'Aja uudelleen valitsimella -ExportDrivers: ajuri viedaan tikulle, jolloin WinPE nakee levyt ja asennettu Windows kaynnistyy.'
    }
}
Write-Host ''

# --- Levyt ---
Write-Host 'Levyt (sisaiset tyhjennetaan, jos KaikkiSisaisetLevyt = true)' -ForegroundColor Cyan
foreach ($d in @(Get-Disk -ErrorAction SilentlyContinue | Sort-Object Number)) {
    $usb = @('USB', 'SD', 'MMC') -contains [string]$d.BusType
    $lvl = if ($usb) { 'INFO' } else { 'HUOMIO' }
    Show-Line $lvl ('Levy {0}: {1}, {2}, {3}{4}' -f $d.Number, $d.FriendlyName, [string]$d.BusType, (Format-Size $d.Size), $(if ($usb) { ' (ulkoinen, ei kosketa)' } else { '' }))
}
Write-Host ''

# --- Pelikunto ---
Write-Host 'Pelikunto ja huijauksenestot' -ForegroundColor Cyan
$findings = Get-GamingFindings -Memory $inputs.Memory -Gpus $inputs.Gpus -HasBattery $inputs.HasBattery `
    -SystemDiskKind $inputs.SystemDiskKind -SecureBoot $inputs.SecureBoot -Tpm $inputs.Tpm
foreach ($level in @('Toimi', 'Huomio', 'OK')) {
    foreach ($x in @($findings.ToArray() | Where-Object { $_.Taso -eq $level })) { Show-Line $level.ToUpper() $x.Teksti }
}
Write-Host ''
Write-Host 'Konetta ei muutettu.' -ForegroundColor DarkGray
