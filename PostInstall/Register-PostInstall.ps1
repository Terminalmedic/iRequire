#requires -Version 5.1
<#
.SYNOPSIS
    Rekisteroi jalkiasennuksen ajastetuiksi tehtaviksi ja kaynnistaa sen.

.DESCRIPTION
    - "iRequire"          SYSTEM, kaynnistyksessa: Invoke-PostInstall.ps1
    - "iRequire-edistys"  kirjautuneelle kayttajalle: Show-Progress.ps1
    Molemmat poistavat itsensa kun jalkiasennus on valmis.
#>
$ErrorActionPreference = 'Stop'
$base = Join-Path $env:SystemDrive 'iRequire'

# SYSTEM ajaa C:\iRequire-kansion skripteja. Suoraan C:n juureen luotu
# kansio perii oletuksena "Authenticated Users: Modify" -oikeuden, jolloin
# tavallinen (UAC:n rajoittama) prosessi voisi muokata skripteja ja saada
# SYSTEM-oikeudet. Siksi: SYSTEM ja jarjestelmanvalvojat taysin, kayttajat
# vain lukea. Kayttajan istunto kirjoittaa vain Kayttaja-kansioon (dataa).
& icacls.exe $base /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
& icacls.exe (Join-Path $base '*') /reset /T /C /Q | Out-Null
$userDir = Join-Path $base 'Kayttaja'
New-Item -ItemType Directory -Path $userDir -Force | Out-Null
& icacls.exe $userDir /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
# Asetuksissa on kayttajan ja WLANin salasana selvakielisena. Vain
# SYSTEM ja jarjestelmanvalvojat saavat lukea niita; tiedosto poistetaan
# kokonaan kun jalkiasennus valmistuu.
& icacls.exe (Join-Path $base 'Config') /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$action = New-ScheduledTaskAction -Execute $ps `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $base 'PostInstall\Invoke-PostInstall.ps1'))
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 12) -StartWhenAvailable
Register-ScheduledTask -TaskName 'iRequire' -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Force | Out-Null

$showAction = New-ScheduledTaskAction -Execute $ps `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $base 'PostInstall\Show-Progress.ps1'))
$showTrigger = New-ScheduledTaskTrigger -AtLogOn
$users = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
Register-ScheduledTask -TaskName 'iRequire-edistys' -Action $showAction -Trigger $showTrigger -Principal $users `
    -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries) -Force | Out-Null

Start-ScheduledTask -TaskName 'iRequire'
Write-Output ('{0} jalkiasennus rekisteroity ja kaynnistetty' -f (Get-Date -Format s))
