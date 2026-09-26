#requires -Version 5.1
<#
.SYNOPSIS
    iRequiren tarkistukset, jotka voi ajaa milla tahansa koneella.

.DESCRIPTION
    Levyja, WinPE:ta tai asennusta ei voi testata ilman oikeaa konetta,
    joten tassa tarkistetaan kaikki mika on tarkistettavissa ilman niita:
    jasennys, asetustiedostot, kaytantotiedostot, vastaustiedoston
    muodostus ja tyhjennyksen varmistuslogiikka.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        Write-Host "  OK    $Name" -ForegroundColor Green
    } catch {
        $failures.Add("$Name - $($_.Exception.Message)")
        Write-Host "  VIRHE $Name - $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

Write-Host ''
Write-Host '=== iRequire-tarkistukset ===' -ForegroundColor Cyan

. (Join-Path $root 'Lib\Common.ps1')
. (Join-Path $root 'Lib\Media.ps1')
. (Join-Path $root 'Lib\Stages.ps1')
. (Join-Path $root 'Lib\Tuning.ps1')
. (Join-Path $root 'Lib\Readiness.ps1')
. (Join-Path $root 'Lib\Display.ps1')
. (Join-Path $root 'WinPE\Disk.ps1')
. (Join-Path $root 'WinPE\Deploy.ps1')

function Write-IRequireLog { param([string]$Message, [string]$Level) }   # hiljaa testeissa

Test-Case 'Kaikki .ps1-tiedostot jasentyvat' {
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1)) {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors) | Out-Null
        Assert-True (-not $errors -or $errors.Count -eq 0) ("{0}: {1}" -f $f.Name, ($errors | Select-Object -First 1))
    }
}

Test-Case 'Ulkoinen ohjelma: stderr ei kaada, paluukoodi talteen (Invoke-Native)' {
    # PowerShell 5.1 + Stop: '& ohjelma 2>&1' kaatuu ensimmaiseen stderr-riviin.
    # Nain kavi LGPO.exe:lle oikeassa asennuksessa (paasta paahan -testi).
    if ($env:OS -eq 'Windows_NT') { $exe = 'cmd.exe'; $argv = @('/c', 'echo tulos& echo virhe 1>&2& exit /b 3') }
    else { $exe = 'sh'; $argv = @('-c', 'echo tulos; echo virhe >&2; exit 3') }
    $ErrorActionPreference = 'Stop'
    $r = Invoke-Native $exe $argv
    Assert-True ($r.ExitCode -eq 3) "paluukoodi $($r.ExitCode), odotettiin 3"
    $text = ($r.Output -join '|')
    Assert-True ($text -match 'tulos' -and $text -match 'virhe') "tuloste: $text"
    Assert-True ($ErrorActionPreference -eq 'Stop') 'ErrorActionPreference ei palautunut'
    $r = Invoke-Native $exe $(if ($env:OS -eq 'Windows_NT') { @('/c', 'exit /b 0') } else { @('-c', 'exit 0') })
    Assert-True ($r.ExitCode -eq 0) "onnistunut ajo: $($r.ExitCode)"
    # Tyhja stderr-rivi (LGPO tulostaa niita) ei saa nakya lokissa virhetyyppina.
    $r = Invoke-Native $exe $(if ($env:OS -eq 'Windows_NT') { @('/c', 'echo.1>&2& echo virhe 1>&2') } else { @('-c', 'echo >&2; echo virhe >&2') })
    Assert-True (-not (($r.Output -join '|') -match 'Exception')) ('tuloste: ' + ($r.Output -join '|'))
    Assert-True (($r.Output -join '|') -match 'virhe') ('tuloste: ' + ($r.Output -join '|'))
}

Test-Case 'Jalkiasennus: salasanat poistetaan vasta kun tilakone on paassa' {
    # Viimeistely kaatui kerran (kirjoitussuojattu tikku) ja uusintakierros
    # ajettiin oletusasetuksilla, koska asetustiedosto oli jo poistettu.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'PostInstall\Invoke-PostInstall.ps1'), [ref]$null, [ref]$null)
    $fns = @{}
    foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $fns[$f.Name] = $f.Extent.Text }
    Assert-True ($fns.ContainsKey('Remove-Secrets') -and $fns['Remove-Secrets'] -match 'iRequire\.json') 'Remove-Secrets puuttuu'
    foreach ($n in $fns.Keys) {
        if ($n -ne 'Remove-Secrets') { Assert-True ($fns[$n] -notmatch 'iRequire\.json') "$n poistaa asetustiedoston" }
    }
    $text = $ast.Extent.Text
    $machine = $text.IndexOf('$result = Invoke-StageMachine')
    $call = $text.LastIndexOf('Remove-Secrets')
    Assert-True ($machine -gt 0 -and $call -gt $machine) 'Remove-Secrets kutsutaan ennen tilakoneen loppua'
    $finish = $fns['Invoke-StageFinish']
    Assert-True ($finish -match 'catch') 'tikulle kopiointi ei ole virhesuojattu'
}

Test-Case 'Ulkoisia ohjelmia ei ajeta suoraan 2>&1:lla (vain Invoke-Native)' {
    $bad = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1 | Where-Object { $_.Name -ne 'Test-iRequire.ps1' })) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        $merges = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.MergingRedirectionAst] }, $true)
        foreach ($m in $merges) {
            $p = $m.Parent
            while ($p -and -not ($p -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $p = $p.Parent }
            if ($p -and $p.Name -eq 'Invoke-Native') { continue }
            $bad.Add(('{0}:{1}' -f $f.Name, $m.Extent.StartLineNumber))
        }
    }
    Assert-True ($bad.Count -eq 0) ('suora 2>&1: ' + ($bad -join ', '))
}

Test-Case 'Jokainen kutsuttu funktio on olemassa (kirjoitusvirheet)' {
    # Windows-cmdletit joita ei ole kaikilla alustoilla (esim. Linuxin pwsh).
    $windowsOnly = @(
        'Add-VMDvdDrive','Add-VMHardDiskDrive','Add-WindowsDriver','Add-WindowsPackage','Clear-Disk',
        'Connect-VMNetworkAdapter','Disable-ScheduledTask','Disable-WindowsOptionalFeature','Dismount-DiskImage',
        'Dismount-VHD','Dismount-WindowsImage','Enable-VMTPM','Export-WindowsImage','Format-Volume',
        'Get-AppxPackage','Get-AppxProvisionedPackage','Get-AuthenticodeSignature','Get-CimInstance','Get-Disk',
        'Get-Partition','Get-PhysicalDisk','Get-PnpDevice','Get-ScheduledTask','Get-Service','Get-VM',
        'Get-VMSwitch','Get-Volume','Get-WindowsCapability','Get-WindowsImage','Get-WindowsOptionalFeature',
        'Initialize-Disk','Mount-DiskImage','Mount-VHD','Mount-WindowsImage','New-Partition',
        'New-ScheduledTaskAction','New-ScheduledTaskPrincipal','New-ScheduledTaskSettingsSet',
        'New-ScheduledTaskTrigger','New-VHD','New-VM','Register-ScheduledTask','Remove-AppxPackage',
        'Remove-AppxProvisionedPackage','Remove-WindowsCapability','Set-Disk','Set-Service','Set-VMFirmware',
        'Set-VMKeyProtector','Set-VMMemory','Set-VMProcessor','Split-WindowsImage','Start-ScheduledTask',
        'Start-VM','Stop-Service','Unregister-ScheduledTask','Update-MpSignature','Update-Disk',
        'Enable-WindowsOptionalFeature','Get-Tpm','Get-BitLockerVolume','Add-BitLockerKeyProtector',
        'Remove-BitLockerKeyProtector','Enable-BitLocker','Get-MpComputerStatus','Get-MpPreference','Get-NetFirewallProfile',
        'Confirm-SecureBootUEFI','Set-CimInstance','Get-WindowsPackage','Update-HostStorageCache',
        'Get-SecureBootUEFI','Get-PnpDeviceProperty',
        'Invoke-ScriptAnalyzer')   # Tests\Invoke-Checks.ps1, vain jos moduuli on asennettu
    $defined = @{}
    $calls = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1)) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        # Testien omat korvikefunktiot eivat saa peittaa tuotantokoodin kirjoitusvirheita.
        if ($f.Name -ne 'Test-iRequire.ps1') {
            foreach ($d in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $defined[$d.Name] = $true }
        }
        if ($f.Name -eq 'Test-iRequire.ps1') { continue }
        foreach ($c in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $n = $c.GetCommandName()
            if ($n -and $n -match '^[A-Za-z]+-[A-Za-z0-9]+$') { $calls[$n] = $f.Name }
        }
    }
    $unknown = @($calls.Keys | Where-Object {
        -not $defined[$_] -and $windowsOnly -notcontains $_ -and -not (Get-Command $_ -ErrorAction SilentlyContinue)
    } | ForEach-Object { "$_ ($($calls[$_]))" })
    Assert-True ($unknown.Count -eq 0) ('Tuntemattomia: ' + ($unknown -join ', '))
}

Test-Case 'Skriptit ovat ASCII-muotoisia (WinPE-konsoli ja PS 5.1 ilman BOMia)' {
    # -Include kayttaytyy eri tavoin PS 5.1:ssa ja 7:ssa, joten suodatetaan itse.
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.cmd', '.ini', '.txt') })
    Assert-True ($files.Count -gt 15) "Tarkistettiin vain $($files.Count) tiedostoa"
    foreach ($f in $files) {
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        $start = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
        for ($i = $start; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -gt 127) { throw "$($f.Name): ei-ASCII-tavu kohdassa $i" }
        }
    }
}

Test-Case 'Asetukset latautuvat ja oletukset taydentyvat' {
    $cfg = Get-IRequireConfig -Path (Join-Path $root 'Config\iRequire.json')
    Assert-True ($cfg.Tyhjennys.LaskuriSekuntia -ge 5) 'Laskurin on oltava vahintaan 5 s'
    Assert-True ($cfg.Kayttaja.Nimi -ne '') 'Kayttajanimi puuttuu'
    $empty = Get-IRequireConfig -Path (Join-Path $root 'ei-ole-olemassa.json')
    Assert-True ($empty.Paivitykset.MaksimiKierrokset -eq 6) 'Oletusarvot eivat taydentyneet'
}

Test-Case 'Poistolista on kelvollinen eika sisalla tarpeellisia' {
    $d = Get-Content -LiteralPath (Join-Path $root 'Policies\Debloat.json') -Raw | ConvertFrom-Json
    foreach ($k in @('Appx', 'Kyvyt', 'Ominaisuudet', 'Palvelut', 'Ajastukset')) {
        Assert-True ($d.PSObject.Properties.Name -contains $k) "Debloat.json: $k puuttuu"
    }
    # Naiden poistaminen rikkoisi jotain mita kayttaja tarvitsee.
    $protected = @('Microsoft.ZuneMusic', 'Microsoft.WindowsCalculator', 'Microsoft.VCLibs.140.00',
                   'Microsoft.UI.Xaml.2.8', 'Microsoft.DesktopAppInstaller', 'Microsoft.SecHealthUI',
                   'Microsoft.HEVCVideoExtension', 'Microsoft.WindowsNotepad')
    foreach ($p in $protected) {
        foreach ($pattern in $d.Appx) { Assert-True (-not ($p -like $pattern)) "$p osuu poistokuvioon $pattern" }
    }
    foreach ($s in @('wuauserv', 'WinDefend', 'Audiosrv', 'bthserv', 'WlanSvc', 'BITS', 'WSearch')) {
        Assert-True ($d.Palvelut -notcontains $s) "Palvelua $s ei saa poistaa kaytosta"
    }
}

Test-Case 'Kaytantotiedostot jasentyvat' {
    $n = 0
    foreach ($f in @('machine.txt', 'user.txt', 'defaultuser.txt')) {
        $entries = Read-PolicyFile -Path (Join-Path $root "Policies\$f")
        Assert-True ($entries.Count -gt 0) "$f on tyhja"
        if ($f -eq 'machine.txt') { Assert-True (@($entries | Where-Object Scope -ne 'Computer').Count -eq 0) 'machine.txt: vain Computer-tietueita' }
        if ($f -ne 'machine.txt') { Assert-True (@($entries | Where-Object Scope -ne 'User').Count -eq 0) "${f}: vain User-tietueita" }
        $n += $entries.Count
    }
    Assert-True ($n -gt 50) "Liian vahan kaytantoja ($n)"
}

Test-Case 'Kaytantojasennin hylkaa rikkinaisen tietueen' {
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $tmp -Value @('Computer', 'SOFTWARE\X', 'Arvo', '')
        $threw = $false
        try { Read-PolicyFile -Path $tmp | Out-Null } catch { $threw = $true }
        Assert-True $threw 'Kolmirivinen tietue meni lapi'
    } finally { Remove-Item -LiteralPath $tmp -Force }
}

Test-Case 'Vastaustiedosto muodostuu kelvolliseksi XML:ksi' {
    $cfg = Get-IRequireConfig -Path (Join-Path $root 'Config\iRequire.json')
    $cfg.Kayttaja.Salasana = 'a<b&"c'
    $xml = [xml](New-UnattendXml -TemplatePath (Join-Path $root 'Unattend\unattend.template.xml') -Config $cfg)
    Assert-True ($xml.OuterXml -notmatch '\{\{') 'Tayttamaton kentta jai XML:aan'
    Assert-True ($xml.OuterXml -notmatch '<ProductKey>') 'Tyhja tuoteavain jai XML:aan'
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
    $pw = $xml.SelectSingleNode('//u:LocalAccount/u:Password/u:Value', $ns).InnerText
    Assert-True ($pw -eq 'a<b&"c') 'Salasanan erikoismerkit eivat sailyneet'

    $cfg.Asennus.Tuoteavain = 'KBN8V-HFGQ4-MGXVD-347P6-PDQGT'
    $xml2 = New-UnattendXml -TemplatePath (Join-Path $root 'Unattend\unattend.template.xml') -Config $cfg
    Assert-True ($xml2 -match '<ProductKey>KBN8V-HFGQ4-MGXVD-347P6-PDQGT</ProductKey>') 'Tuoteavain puuttuu'
}

Test-Case 'Naytekohdat: alku, loppu, tasaus ja maara' {
    $size = [int64]500GB
    $o = Get-SampleOffsets -Size $size -Count 256
    Assert-True ($o.Count -eq 256) "Naytteita $($o.Count)"
    Assert-True ($o[0] -eq 0) 'Alku puuttuu'
    Assert-True (($o | Measure-Object -Maximum).Maximum + 65536 -le $size) 'Nayte levyn lopun yli'
    Assert-True (@($o | Where-Object { $_ % 4096 -ne 0 }).Count -eq 0) 'Tasaamaton nayte'
    $small = Get-SampleOffsets -Size ([int64]1MB) -Count 256
    Assert-True ($small.Count -le 241) 'Pienella levylla liikaa naytteita'
}

Test-Case 'Varmistus: ylikirjoitus vaatii nollat, laitetyhjennys muutoksen' {
    $mk = { param($h, $z) [pscustomobject]@{ Offset = 0; Hash = $h; Zero = $z } }
    $before = @((& $mk 'A' $false), (& $mk 'Z' $true))
    Assert-True (Test-WipeResult -Before $before -After @((& $mk 'Z' $true), (& $mk 'Z' $true)) -Method Overwrite).Ok 'Nollattu hylattiin'
    Assert-True (-not (Test-WipeResult -Before $before -After @((& $mk 'R' $false), (& $mk 'Z' $true)) -Method Overwrite).Ok) 'Ei-nolla hyvaksyttiin'
    Assert-True (Test-WipeResult -Before $before -After @((& $mk 'R' $false), (& $mk 'R2' $false)) -Method Firmware).Ok 'Muuttunut hylattiin'
    Assert-True (-not (Test-WipeResult -Before $before -After @((& $mk 'A' $false), (& $mk 'Z' $true)) -Method Firmware).Ok) 'Ennallaan hyvaksyttiin'
}

Test-Case 'Kohdelevyn valinta: NVMe ennen SSD:ta ja HDD:ta, liian pieni ohitetaan' {
    $disks = @(
        [pscustomobject]@{ Number = 0; Kind = 'HDD'; Size = [int64]2TB },
        [pscustomobject]@{ Number = 1; Kind = 'SSD'; Size = [int64]500GB },
        [pscustomobject]@{ Number = 2; Kind = 'NVMe'; Size = [int64]16GB }
    )
    Assert-True ((Select-TargetDisk -Disks $disks -MinimumGb 40).Number -eq 1) 'Vaara levy'
    $withEmmc = $disks + @([pscustomobject]@{ Number = 3; Kind = 'eMMC'; Size = [int64]64GB })
    Assert-True ((Select-TargetDisk -Disks $withEmmc -MinimumGb 40).Number -eq 1) 'eMMC ohitti SSD:n'
    $hddEmmc = @($disks[0], $withEmmc[3])
    Assert-True ((Select-TargetDisk -Disks $hddEmmc -MinimumGb 40).Number -eq 3) 'HDD ohitti eMMC:n'
    Assert-True ((Select-TargetDisk -Disks $disks -MinimumGb 4).Number -eq 2) 'NVMe ei voittanut'
    Assert-True ($null -eq (Select-TargetDisk -Disks $disks -MinimumGb 5000)) 'Liian pieni kelpasi'
}

Test-Case 'Asetustiedostossa ei ole tuntemattomia avaimia (kirjoitusvirheet)' {
    $p = @(Test-IRequireConfig -Path (Join-Path $root 'Config\iRequire.json'))
    Assert-True ($p.Count -eq 0) ('toimitettu asetustiedosto: ' + ($p -join '; '))
}

Test-Case 'Turvallisuus: virheellinen asetustiedosto pysayttaa ennen tyhjennysta' {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('irq-cfg-' + [guid]::NewGuid().ToString('N') + '.json')
    $check = { param($text) Set-Content -LiteralPath $tmp -Value $text -Encoding UTF8; @(Test-IRequireConfig -Path $tmp) }
    try {
        # Kirjoitusvirhe harjoitustilan avaimessa: ilman tarkistusta oletus (false) = oikea tyhjennys.
        $p = @(& $check '{ "Tyhjennys": { "Harjoitsu": true } }')
        Assert-True ($p.Count -eq 1 -and $p[0] -match "Tyhjennys\.Harjoitsu") ('kirjoitusvirhe: ' + ($p -join '; '))
        $p = @(& $check '{ "Tyhjennys": { "KaikkiSisaisetLevyt": "false" } }')
        Assert-True ($p.Count -eq 1 -and $p[0] -match 'true tai false') ('merkkijono totuusarvona: ' + ($p -join '; '))
        $p = @(& $check '{ "Tyhjennys": { "Harjoitus": true, } ')
        Assert-True ($p.Count -eq 1 -and $p[0] -match 'JSON') ('rikkinainen JSON: ' + ($p -join '; '))
        $p = @(& $check '{ "Tyhjenys": { "Harjoitus": true } }')
        Assert-True ($p.Count -eq 1 -and $p[0] -match "osio 'Tyhjenys'") ('tuntematon osio: ' + ($p -join '; '))
        $p = @(& $check '{ "Tyhjennys": { "LaskuriSekuntia": "15" } }')
        Assert-True ($p.Count -eq 1 -and $p[0] -match 'kokonaisluku') ('luku tekstina: ' + ($p -join '; '))
        $p = @(& $check '{ "_kuvaus": "x", "Tyhjennys": { "_Harjoitus": "selite", "Harjoitus": true, "LaskuriSekuntia": 30 }, "Suorituskyky": { "HorrostilaPois": false } }')
        Assert-True ($p.Count -eq 0) ('kelvollinen hylattiin: ' + ($p -join '; '))
        # Start-iRequire pysahtyy ongelmiin ennen yhtakaan levyoperaatiota.
        $src = Get-Content -LiteralPath (Join-Path $root 'WinPE\Start-iRequire.ps1') -Raw
        $stop = $src.IndexOf('if ($configProblems.Count -gt 0)')
        Assert-True ($stop -gt 0 -and $stop -lt $src.IndexOf('Find-PendingInstall') -and $stop -lt $src.IndexOf('Get-DiskInventory')) 'asetusten tarkistus ei ole ennen levyoperaatioita'
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

Test-Case 'Levyjen luokittelu: ulkoiset rauhaan, eMMC mukaan, muistikortit rauhaan' {
    $c = { param($bus, $media, $drive) Get-DiskClass -BusType $bus -MediaType $media -DriveMediaType $drive -Size ([int64]100GB) }
    Assert-True (-not (& $c 'USB' 'SSD' 'External hard disk media').Include) 'USB-levy mukana'
    Assert-True (-not (& $c 'SATA' 'HDD' 'External hard disk media').Include) 'Ulkoinen SATA mukana'
    Assert-True (-not (& $c 'SD' '' 'Removable Media').Include) 'Muistikortti mukana'
    Assert-True (-not (& $c 'SD' '' '').Include) 'Tuntematon SD mukana'
    Assert-True (-not (& $c 'Virtual' '' 'Fixed hard disk media').Include) 'Virtuaalilevy mukana'
    Assert-True (-not (& $c 'iSCSI' '' 'Fixed hard disk media').Include) 'Verkkolevy mukana'
    $e = & $c 'MMC' '' 'Fixed hard disk media'
    Assert-True ($e.Include -and $e.Kind -eq 'eMMC') 'eMMC puuttuu'
    Assert-True ((& $c 'NVMe' 'SSD' 'Fixed hard disk media').Kind -eq 'NVMe') 'NVMe'
    Assert-True ((& $c 'SATA' 'SSD' 'Fixed hard disk media').Kind -eq 'SSD') 'SSD'
    Assert-True ((& $c 'SATA' 'HDD' 'Fixed hard disk media').Kind -eq 'HDD') 'HDD'
    Assert-True ((& $c 'SAS' '' 'Fixed hard disk media').Kind -eq 'Tuntematon') 'Tuntematon'
    Assert-True ((& $c 'RAID' 'Unspecified' '').Include) 'RAID puuttuu'
    Assert-True (-not (Get-DiskClass -BusType 'SATA' -MediaType 'HDD' -DriveMediaType '' -Size 0).Include) 'Tyhja lukija mukana'
    Assert-True (Test-FlashKind 'eMMC') 'eMMC ei flash'
    Assert-True (-not (Test-FlashKind 'HDD')) 'HDD flash'
}

Test-Case 'Varmistus: lukuvirhe hylkaa aina' {
    $mk = { param($h, $z, $e) [pscustomobject]@{ Offset = 0; Hash = $h; Zero = $z; Error = $e } }
    $before = @((& $mk 'A' $false $false))
    $r = Test-WipeResult -Before $before -After @((& $mk '' $false $true)) -Method Overwrite
    Assert-True (-not $r.Ok -and $r.Unreadable -eq 1) 'Overwrite hyvaksyi lukuvirheen'
    $r = Test-WipeResult -Before $before -After @((& $mk '' $false $true)) -Method Firmware
    Assert-True (-not $r.Ok) 'Firmware hyvaksyi lukuvirheen'
    # Ennen lukukelvoton, jalkeen luettava ja muuttunut: kelpaa
    $r = Test-WipeResult -Before @((& $mk '' $false $true)) -After @((& $mk 'B' $false $false)) -Method Firmware
    Assert-True $r.Ok 'Firmware hylkasi luettavaksi muuttuneen'
}

Test-Case 'Median eheys: ehja kelpaa, muutos ja puuttuminen huomataan, asetukset saa muokata' {
    $m = Join-Path ([System.IO.Path]::GetTempPath()) ('irq-media-' + [guid]::NewGuid().ToString('N'))
    try {
        foreach ($d in @('sources', 'iRequire\WinPE', 'iRequire\Config')) { New-Item -ItemType Directory -Path (Join-Path $m $d) -Force | Out-Null }
        [System.IO.File]::WriteAllBytes((Join-Path $m 'sources\install.swm'), (New-Object byte[] (5MB + 7)))
        Set-Content -LiteralPath (Join-Path $m 'iRequire\WinPE\a.ps1') -Value 'x'
        Set-Content -LiteralPath (Join-Path $m 'iRequire\Config\iRequire.json') -Value '{}'
        $n = New-MediaManifest -MediaRoot $m
        Assert-True ($n -eq 2) "Manifestissa $n tiedostoa, odotettiin 2"
        Assert-True ((Test-MediaManifest -MediaRoot $m).Count -eq 0) 'Ehja media hylattiin'

        Set-Content -LiteralPath (Join-Path $m 'iRequire\Config\iRequire.json') -Value '{"muokattu":1}'
        Assert-True ((Test-MediaManifest -MediaRoot $m).Count -eq 0) 'Asetusten muokkaus hylattiin'

        $f = Join-Path $m 'sources\install.swm'
        $bytes = [System.IO.File]::ReadAllBytes($f); $bytes[4MB] = 1; [System.IO.File]::WriteAllBytes($f, $bytes)
        $p = Test-MediaManifest -MediaRoot $m
        Assert-True ($p.Count -eq 1 -and $p[0] -like 'vioittunut*') 'Vioittunut kuva meni lapi'

        Remove-Item -LiteralPath (Join-Path $m 'iRequire\WinPE\a.ps1')
        Assert-True (@(Test-MediaManifest -MediaRoot $m | Where-Object { $_ -like 'puuttuu*' }).Count -eq 1) 'Puuttuva tiedosto meni lapi'

        Remove-Item -LiteralPath (Join-Path $m 'iRequire\manifest.json')
        Assert-True ((Test-MediaManifest -MediaRoot $m).Count -eq 1) 'Puuttuva manifesti meni lapi'
    } finally { Remove-Item -LiteralPath $m -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-Case 'Raporttikansio: kirjoitussuojatun ohi seuraavaan' {
    $ok = Join-Path ([System.IO.Path]::GetTempPath()) ('irq-rep-' + [guid]::NewGuid().ToString('N'))
    $blocker = Join-Path ([System.IO.Path]::GetTempPath()) ('irq-file-' + [guid]::NewGuid().ToString('N'))
    try {
        Set-Content -LiteralPath $blocker -Value 'tiedosto, ei kansio'
        $got = Get-WritableDirectory -Candidates @((Join-Path $blocker 'ali'), $ok)
        Assert-True ($got -eq $ok) "Valittiin $got"
        $threw = $false
        try { Get-WritableDirectory -Candidates @((Join-Path $blocker 'ali')) | Out-Null } catch { $threw = $true }
        Assert-True $threw 'Kirjoituskelvoton kelpasi'
    } finally {
        Remove-Item -LiteralPath $ok -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $blocker -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'Asennus: Copy-Payload + lopputarkistus oikealla tikun rakenteella' {
    # Loytyi paasta paahan -testissa: Copy-Item kopioi ensimmaisen kansion
    # kohteen NIMELLA kun kohdetta ei viela ollut (W:\iRequire\Invoke-...ps1).
    $t = Join-Path ([System.IO.Path]::GetTempPath()) ('irq-cp-' + [guid]::NewGuid().ToString('N'))
    $usb = Join-Path $t 'usb'; $w = Join-Path $t 'W'; $sy = Join-Path $t 'S'; $rep = Join-Path $t 'rep'
    try {
        foreach ($sub in @('PostInstall', 'Policies', 'Lib', 'Config', 'Tools', 'Unattend')) {
            Copy-Item -LiteralPath (Join-Path $root $sub) -Destination (Join-Path $usb "iRequire\$sub") -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path (Join-Path $usb "iRequire\$sub") -Force | Out-Null
        }
        New-Item -ItemType Directory -Path $rep -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $rep 'tyhjennystodistus-x.txt') -Value 'x'
        foreach ($f in @("$w\Windows\System32\config\SYSTEM", "$w\Windows\System32\winload.efi", "$sy\EFI\Microsoft\Boot\bootmgfw.efi", "$sy\EFI\Microsoft\Boot\BCD")) {
            New-Item -ItemType File -Path $f -Force | Out-Null
        }
        $cfg = Get-IRequireConfig -Path (Join-Path $root 'Config\iRequire.json')
        Copy-Payload -UsbRoot $usb -Target $w -Config $cfg -ReportsDir $rep
        Assert-True (Test-Path -LiteralPath "$w\iRequire\PostInstall\Invoke-PostInstall.ps1") 'PostInstall ei ole omassa kansiossaan'
        Assert-True (Test-Path -LiteralPath "$w\iRequire\Reports\tyhjennystodistus-x.txt") 'Todistus ei kopioitunut'
        Assert-True (Test-Path -LiteralPath "$w\iRequire\ASENNUS-KESKEN.tag") 'Merkki puuttuu'
        Test-Deployment -Windows $w -System $sy -Firmware UEFI
    } finally {
        Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'Asennuksen lopputarkistus huomaa puuttuvan tiedoston' {
    $w = Join-Path ([System.IO.Path]::GetTempPath()) ('irq-w-' + [guid]::NewGuid().ToString('N'))
    $sy = Join-Path ([System.IO.Path]::GetTempPath()) ('irq-s-' + [guid]::NewGuid().ToString('N'))
    try {
        $files = @("$w\Windows\System32\config\SYSTEM", "$w\Windows\System32\winload.efi", "$w\Windows\Panther\unattend.xml",
                   "$w\Windows\Setup\Scripts\SetupComplete.cmd", "$w\iRequire\PostInstall\Invoke-PostInstall.ps1",
                   "$w\iRequire\Lib\Common.ps1", "$w\iRequire\Lib\Stages.ps1", "$w\iRequire\Lib\Tuning.ps1", "$w\iRequire\Lib\Readiness.ps1", "$w\iRequire\Lib\Display.ps1", "$w\iRequire\Config\iRequire.json", "$w\iRequire\Policies\Debloat.json",
                   "$sy\EFI\Microsoft\Boot\bootmgfw.efi", "$sy\EFI\Microsoft\Boot\BCD")
        foreach ($f in $files) { New-Item -ItemType File -Path $f -Force | Out-Null }
        Test-Deployment -Windows $w -System $sy -Firmware UEFI
        Remove-Item -LiteralPath "$sy\EFI\Microsoft\Boot\BCD"
        $threw = $false
        try { Test-Deployment -Windows $w -System $sy -Firmware UEFI } catch { $threw = $true }
        Assert-True $threw 'Puuttuva BCD meni lapi'
    } finally {
        Remove-Item -LiteralPath $w, $sy -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --------------------------------------------------------------
#  Windows-integraatio: ajetaan vain oikealla Windowsilla (CI). Kaikki
#  on vain lukevaa - mitaan levya, nayttoa tai asetusta ei muuteta,
#  paitsi testin oma rekisteriavain joka poistetaan.
# --------------------------------------------------------------
if ($env:OS -eq 'Windows_NT') {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    Test-Case 'Windows: LSA-salaisuuden poisto (kaantyy ja toimii, olematon nimi)' {
        # Vain olematon, satunnainen nimi: koneen omiin salaisuuksiin ei kosketa.
        $name = 'iRequireTesti_' + [guid]::NewGuid().ToString('N')
        $r = Clear-AutoLogonSecret -Name $name
        if ($isAdmin) { Assert-True ($r -eq 1) "olematon salaisuus: $r (odotettiin 1)" }
        else { Assert-True ($r -eq 1 -or $r -eq 5) "ilman jarjestelmanvalvojaa: $r" }
    }

    Test-Case 'Windows: levyjen luokittelu oikealla raudalla' {
        $inv = Get-DiskInventory
        $all = @($inv.Internal) + @($inv.Skipped)
        Assert-True ($all.Count -ge 1) 'Yhtaan levya ei loytynyt'
        foreach ($d in $all) { Write-Host ("          levy {0}: {1} {2} {3} {4}" -f $d.Number, $d.Bus, $d.Kind, $d.Reason, (Format-Size $d.Size)) -ForegroundColor DarkGray }
    }

    if ($isAdmin) {
        Test-Case 'Windows: suora levyn luku Win32-kutsuilla (Reflection.Emit)' {
            $d = @(Get-Disk | Sort-Object Number)[0]
            $samples = Read-DiskSamples -Number $d.Number -Offsets (Get-SampleOffsets -Size $d.Size -Count 16)
            $errs = @($samples.ToArray() | Where-Object { $_.Error }).Count
            Assert-True ($errs -eq 0) "$errs/16 naytetta epaonnistui"
            Assert-True (@($samples.ToArray() | Where-Object { -not $_.Zero }).Count -gt 0) 'Kaynnistyslevylta luettiin pelkkia nollia'
        }

        Test-Case 'Windows: ajastinasetusten tunnistus oikeasta bcdeditista' {
            $text = (& bcdedit.exe /enum '{current}') -join "`n"
            Assert-True ($text -match 'identifier') 'bcdedit ei palauttanut tulostetta'
            [void](Get-TimerOverrides -BcdText $text)
        }
    }

    Test-Case 'Windows: pelikunto- ja tietoturvatarkistukset ajautuvat' {
        $in = Get-GamingInputs
        $f = Get-GamingFindings -Memory $in.Memory -Gpus $in.Gpus -HasBattery $in.HasBattery -SystemDiskKind $in.SystemDiskKind
        foreach ($x in $f.ToArray()) { Write-Host ("          [{0}] {1}" -f $x.Taso, $x.Teksti) -ForegroundColor DarkGray }
        $sec = Get-SecuritySummary
        Assert-True ($sec.Count -gt 0) 'Tietoturvayhteenveto tyhja'
        foreach ($l in $sec) { Write-Host ("          $l") -ForegroundColor DarkGray }
    }

    Test-Case 'Windows: nayttotilojen luku (ei muutoksia)' {
        $rows = Set-MaxRefreshRate -DryRun
        foreach ($r in $rows) { Write-Host ("          {0} {1} {2} Hz: {3}" -f $r.Naytto, $r.Tarkkuus, $r.EnnenHz, $r.Tulos) -ForegroundColor DarkGray }
        foreach ($r in $rows) { Assert-True ($r.EnnenHz -eq $r.JalkeenHz) 'DryRun muutti taajuutta' }
    }

    Test-Case 'Windows: kaytantotietueen kirjoitus ja poisto rekisteriin' {
        $root = 'HKCU:\Software\iRequireTesti'
        try {
            Set-PolicyEntry -Entry ([pscustomobject]@{ Scope = 'User'; Key = 'A\B'; Name = 'Luku'; Type = 'DWORD'; Value = '7' }) -Root $root
            Set-PolicyEntry -Entry ([pscustomobject]@{ Scope = 'User'; Key = 'A\B'; Name = 'Teksti'; Type = 'SZ'; Value = 'SwapEffectUpgradeEnable=1;' }) -Root $root
            $v = Get-ItemProperty -LiteralPath "$root\A\B"
            Assert-True ($v.Luku -eq 7 -and $v.Teksti -eq 'SwapEffectUpgradeEnable=1;') 'Arvot eivat tallentuneet'
            Set-PolicyEntry -Entry ([pscustomobject]@{ Scope = 'User'; Key = 'A\B'; Name = 'Luku'; Type = 'DELETE'; Value = '' }) -Root $root
            Assert-True ($null -eq (Get-ItemProperty -LiteralPath "$root\A\B").Luku) 'DELETE ei poistanut'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --------------------------------------------------------------
#  Tyhjennysketju tiedostolla: levyn kahva korvataan testitiedostolla,
#  jolloin ylikirjoitus, varmistus ja varamenetelmat ajetaan oikeasti.
# --------------------------------------------------------------
Add-Type -TypeDefinition @"
using System;
using System.IO;
public class IRequireFaultyStream : Stream {
    private readonly Stream inner; private readonly long badStart; private readonly long badEnd;
    public IRequireFaultyStream(Stream s, long start, long end) { inner = s; badStart = start; badEnd = end; }
    public override bool CanRead { get { return inner.CanRead; } }
    public override bool CanSeek { get { return true; } }
    public override bool CanWrite { get { return inner.CanWrite; } }
    public override long Length { get { return inner.Length; } }
    public override long Position { get { return inner.Position; } set { inner.Position = value; } }
    public override void Flush() { inner.Flush(); }
    public override int Read(byte[] b, int o, int c) { return inner.Read(b, o, c); }
    public override long Seek(long o, SeekOrigin r) { return inner.Seek(o, r); }
    public override void SetLength(long v) { inner.SetLength(v); }
    public override void Write(byte[] b, int o, int c) {
        long p = inner.Position;
        if (p < badEnd && p + c > badStart) throw new IOException("simuloitu viallinen sektori");
        inner.Write(b, o, c);
    }
    protected override void Dispose(bool d) { if (d) inner.Dispose(); base.Dispose(d); }
}
"@

$script:TestDisk = Join-Path ([System.IO.Path]::GetTempPath()) ('irq-disk-' + [guid]::NewGuid().ToString('N') + '.img')
$script:TestBad = $null
$script:FirmwareMode = 'unsupported'

function Open-RawDisk {
    param([int]$Number, [switch]$Write)
    $access = if ($Write) { [System.IO.FileAccess]::ReadWrite } else { [System.IO.FileAccess]::Read }
    $fs = [System.IO.File]::Open($script:TestDisk, [System.IO.FileMode]::Open, $access, [System.IO.FileShare]::ReadWrite)
    if ($script:TestBad) { return New-Object IRequireFaultyStream($fs, $script:TestBad[0], $script:TestBad[1]) }
    return $fs
}
function Clear-DiskLayout { param([int]$Number) }
function Update-Disk { param([int]$Number) }
function Invoke-FullDiskTrim { param([int]$Number) return $true }
function Invoke-FirmwareErase {
    param([int]$Number, [string]$Kind)
    switch ($script:FirmwareMode) {
        'unsupported' { return [pscustomobject]@{ Ok = $false; Error = 'Win32-virhe 1' } }
        'noop'        { return [pscustomobject]@{ Ok = $true; Error = '' } }
        'crypto' {
            # Kryptografinen tyhjennys: vanha data muuttuu satunnaiseksi.
            $bytes = New-Object byte[] (Get-Item -LiteralPath $script:TestDisk).Length
            (New-Object System.Random).NextBytes($bytes)
            [System.IO.File]::WriteAllBytes($script:TestDisk, $bytes)
            return [pscustomobject]@{ Ok = $true; Error = '' }
        }
    }
}
function New-TestDisk {
    $bytes = New-Object byte[] (24MB + 4096)
    (New-Object System.Random).NextBytes($bytes)
    [System.IO.File]::WriteAllBytes($script:TestDisk, $bytes)
    return [pscustomobject]@{ Number = 0; Model = 'Testilevy'; Serial = 'T1'; Size = [int64]$bytes.Length; Bus = 'SATA'; Kind = 'HDD' }
}
function Test-FileAllZero {
    $bytes = [System.IO.File]::ReadAllBytes($script:TestDisk)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -eq [BitConverter]::ToString($sha.ComputeHash((New-Object byte[] $bytes.Length))))
}

try {
    Test-Case 'Tyhjennys HDD: koko levy nollille, varmistus hyvaksyy' {
        $d = New-TestDisk
        $r = Invoke-DiskWipe -Disk $d -SampleCount 64 -FullVerify
        Assert-True ($r.Varmistus -eq 'HYVAKSYTTY') "Varmistus: $($r.Varmistus) $($r.Huomio)"
        Assert-True ($r.TaysiVarmistus -eq 'OK') "Takaisinluku: $($r.TaysiVarmistus)"
        Assert-True ($r.NaytteitaJoissaDataa -gt 60) 'Ennen-naytteissa ei nahty dataa'
        Assert-True (Test-FileAllZero) 'Levylle jai dataa'
    }

    Test-Case 'Tyhjennys NVMe: kryptografinen tyhjennys hyvaksytaan ilman ylikirjoitusta' {
        $d = New-TestDisk; $d.Kind = 'NVMe'
        $script:FirmwareMode = 'crypto'
        $r = Invoke-DiskWipe -Disk $d -SampleCount 64
        Assert-True ($r.Varmistus -eq 'HYVAKSYTTY') "Varmistus: $($r.Varmistus)"
        Assert-True ($r.Menetelma -like '*kryptografinen*') "Menetelma: $($r.Menetelma)"
    }

    Test-Case 'Tyhjennys SSD: laite valehtelee onnistuneensa -> ylikirjoitus varalla' {
        $d = New-TestDisk; $d.Kind = 'SSD'
        $script:FirmwareMode = 'noop'
        $r = Invoke-DiskWipe -Disk $d -SampleCount 64
        Assert-True ($r.Varmistus -eq 'HYVAKSYTTY') "Varmistus: $($r.Varmistus)"
        Assert-True ($r.Menetelma -like 'Ylikirjoitus*TRIM') "Menetelma: $($r.Menetelma)"
        Assert-True (Test-FileAllZero) 'Levylle jai dataa'
    }

    Test-Case 'Tyhjennys: valehteleva laite TYHJALLA levylla ei mene lapi (kanarialinnut)' {
        # Lahes tyhja levy: satunnaisnaytteet eivat osu dataan, joten ilman
        # kanarialintuja no-op-tyhjennys hyvaksyttaisiin. Salaisuus keskella.
        $size = 24MB + 4096
        $bytes = New-Object byte[] $size
        $secret = [Text.Encoding]::ASCII.GetBytes('SALAISUUS-KESKELLA')
        [Array]::Copy($secret, 0, $bytes, 12MB + 123, $secret.Length)
        [System.IO.File]::WriteAllBytes($script:TestDisk, $bytes)
        $d = [pscustomobject]@{ Number = 0; Model = 'Tyhja'; Serial = 'T2'; Size = [int64]$size; Bus = 'NVMe'; Kind = 'NVMe' }
        $script:FirmwareMode = 'noop'
        $r = Invoke-DiskWipe -Disk $d -SampleCount 8
        Assert-True ($r.Menetelma -like 'Ylikirjoitus*') "Valehteleva laite hyvaksyttiin: $($r.Menetelma)"
        Assert-True (Test-FileAllZero) 'Levylle jai dataa'
    }

    Test-Case 'Tyhjennys SSD: komentoa ei tueta -> ylikirjoitus' {
        $d = New-TestDisk; $d.Kind = 'SSD'
        $script:FirmwareMode = 'unsupported'
        $r = Invoke-DiskWipe -Disk $d -SampleCount 64
        Assert-True ($r.Varmistus -eq 'HYVAKSYTTY') "Varmistus: $($r.Varmistus)"
        Assert-True (@($r.Yritykset | Where-Object { $_ -like '*ei tuettu*' }).Count -eq 1) 'Yritys puuttuu todistuksesta'
    }

    Test-Case 'Tyhjennys: viallinen alue hylkaa levyn, muu levy silti nollataan' {
        $d = New-TestDisk
        $script:TestBad = @([int64]10MB, [int64](10MB + 100))
        try {
            $r = Invoke-DiskWipe -Disk $d -SampleCount 64
        } finally { $script:TestBad = $null }
        Assert-True ($r.Varmistus -eq 'HYLATTY') "Viallinen levy hyvaksyttiin"
        Assert-True ($r.Huomio -like '*ei voitu kirjoittaa*') "Hylkayksen syy vaara: $($r.Huomio)"
        Assert-True ($r.ViallisetAlueet.Count -eq 1) "Viallisia alueita $($r.ViallisetAlueet.Count), odotettiin 1 (64 KiB)"
        $bytes = [System.IO.File]::ReadAllBytes($script:TestDisk)
        Assert-True ($bytes[0] -eq 0 -and $bytes[20MB] -eq 0) 'Viallisen alueen ulkopuoli jai nollaamatta'
    }

    Test-Case 'Todistus kirjoittuu tekstina ja JSONina' {
        $d = New-TestDisk
        $r = Invoke-DiskWipe -Disk $d -SampleCount 16
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('irq-cert-' + [guid]::NewGuid().ToString('N'))
        try {
            $txt = Write-WipeCertificate -Records @($r) -Directory $dir -Machine 'Testikone'
            Assert-True ((Get-Content -LiteralPath $txt -Raw) -match 'HYVAKSYTTY') 'Tulos puuttuu tekstista'
            $json = Get-Content -LiteralPath ($txt -replace '\.txt$', '.json') -Raw | ConvertFrom-Json
            Assert-True ($json.Levyt[0].Sarjanumero -eq 'T1') 'Sarjanumero puuttuu JSONista'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
} finally {
    Remove-Item -LiteralPath $script:TestDisk -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------
#  Jalkiasennuksen tilakone: simuloidaan uudelleenkaynnistyksia
#  ajamalla konetta silmukassa kunnes se ilmoittaa valmiiksi.
# --------------------------------------------------------------
function Invoke-SimulatedBoots {
    <# Ajaa tilakonetta kuin kone kaynnistyisi uudelleen joka kerta kun se
       pyytaa. Palauttaa kaynnistysten maaran ja lopputuloksen. #>
    param([string[]]$Stages, [hashtable]$Handlers, [int]$MaxBoots = 50, $State)
    $saved = if ($State) { $State | ConvertTo-Json | ConvertFrom-Json } else { $null }
    for ($boot = 1; $boot -le $MaxBoots; $boot++) {
        # Tila luetaan "levylta" joka kaynnistyksella kuten oikeasti.
        $st = New-StageState -Stages $Stages -Existing $(if ($saved) { $saved | ConvertTo-Json | ConvertFrom-Json } else { $null })
        $r = Invoke-StageMachine -State $st -Stages $Stages -Handlers $Handlers -Save { param($x) $script:SavedState = $x | ConvertTo-Json | ConvertFrom-Json }
        $saved = $script:SavedState
        if ($r.Result -ne 'Reboot') { return [pscustomobject]@{ Boots = $boot; Result = $r.Result; State = $saved } }
    }
    return [pscustomobject]@{ Boots = $MaxBoots; Result = 'SILMUKKA'; State = $saved }
}

$simStages = @('A', 'Paivitykset', 'B')

Test-Case 'Jalkiasennus: jokaisella vaiheella on kasittelija ja paivitykset ennen viimeistelya' {
    $text = Get-Content -LiteralPath (Join-Path $root 'PostInstall\Invoke-PostInstall.ps1') -Raw
    $m = [regex]::Match($text, '\$stages = @\(([^)]*)\)')
    Assert-True $m.Success 'Vaihelistaa ei loytynyt'
    $names = @([regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    foreach ($n in $names) {
        Assert-True ($text -match ("(?m)^\s*'" + [regex]::Escape($n) + "'\s*=\s*\{")) "Vaiheelta $n puuttuu kasittelija"
    }
    Assert-True ($names[-1] -eq 'Viimeistely') 'Viimeistely ei ole viimeinen'
    Assert-True ([Array]::IndexOf($names, 'Verkko') -lt [Array]::IndexOf($names, 'Paivitykset')) 'Verkko paivitysten jalkeen'
}

Test-Case 'Viritys: virrankaytto koneen tyypin mukaan' {
    Assert-True ((Get-PowerPlanChoice -Setting 'auto' -HasBattery $false) -eq 'Ultimate') 'Poytakone'
    Assert-True ((Get-PowerPlanChoice -Setting 'auto' -HasBattery $true) -eq 'Balanced') 'Kannettava'
    Assert-True ((Get-PowerPlanChoice -Setting 'HIGH' -HasBattery $true) -eq 'High') 'Pakotettu high'
    Assert-True ((Get-PowerPlanChoice -Setting 'ultimate' -HasBattery $true) -eq 'Ultimate') 'Pakotettu ultimate'
    Assert-True ((Get-PowerPlanChoice -Setting 'hassu' -HasBattery $false) -eq 'Ultimate') 'Tuntematon -> auto'
}

Test-Case 'Viritys: horrostila pois vain poytakoneelta ellei pakoteta' {
    Assert-True (Get-HibernateChoice -Setting 'auto' -HasBattery $false) 'Poytakone'
    Assert-True (-not (Get-HibernateChoice -Setting 'auto' -HasBattery $true)) 'Kannettava'
    Assert-True (Get-HibernateChoice -Setting $true -HasBattery $true) 'Pakotettu pois'
    Assert-True (-not (Get-HibernateChoice -Setting $false -HasBattery $false)) 'Pakotettu paalle'
    Assert-True (Get-HibernateChoice -Setting 'true' -HasBattery $true) 'Merkkijono true'
}

Test-Case 'Viritys: aktiiviset tunnit enintaan 18 h' {
    Assert-True (Test-ActiveHours -Start 8 -End 2) '8-02 = 18 h'
    Assert-True (Test-ActiveHours -Start 9 -End 17) '9-17'
    Assert-True (-not (Test-ActiveHours -Start 8 -End 3)) '8-03 = 19 h'
    Assert-True (-not (Test-ActiveHours -Start 5 -End 5)) 'sama tunti'
    Assert-True (-not (Test-ActiveHours -Start 24 -End 2)) 'yli 23'
    $cfg = Get-IRequireConfig -Path (Join-Path $root 'Config\iRequire.json')
    Assert-True (Test-ActiveHours -Start $cfg.Suorituskyky.AktiivisetTunnitAlku -End $cfg.Suorituskyky.AktiivisetTunnitLoppu) 'Oletusasetus ei kelpaa'
}

Test-Case 'Tietoturva: vastaustiedosto estaa automaattisen laitesalauksen' {
    $cfg = Get-IRequireConfig -Path (Join-Path $root 'Config\iRequire.json')
    $xml = New-UnattendXml -TemplatePath (Join-Path $root 'Unattend\unattend.template.xml') -Config $cfg
    Assert-True ($xml -match 'PreventDeviceEncryption /t REG_DWORD /d 1') 'PreventDeviceEncryption puuttuu'
}

Test-Case 'Tietoturva: suojaus ei heikkene (Defender, palomuuri, UAC, SmartScreen, VBS)' {
    $all = @()
    foreach ($f in @('machine.txt', 'user.txt', 'defaultuser.txt')) { $all += (Read-PolicyFile -Path (Join-Path $root "Policies\$f")).ToArray() }
    $forbidden = @(
        @{ Name = 'DisableAntiSpyware' }, @{ Name = 'DisableRealtimeMonitoring' }, @{ Name = 'EnableLUA'; Value = '0' },
        @{ Name = 'EnableSmartScreen'; Value = '0' }, @{ Name = 'EnableFirewall'; Value = '0' },
        @{ Name = 'EnableVirtualizationBasedSecurity'; Value = '0' }, @{ Name = 'HypervisorEnforcedCodeIntegrity'; Value = '0' },
        @{ Name = 'NoAutoUpdate'; Value = '1' }, @{ Name = 'DisableWindowsUpdateAccess'; Value = '1' }
    )
    foreach ($f in $forbidden) {
        $hit = @($all | Where-Object { $_.Name -eq $f.Name -and (-not $f.Value -or $_.Value -eq $f.Value) })
        Assert-True ($hit.Count -eq 0) ("Kielletty asetus: {0}" -f $f.Name)
    }
    $blocklist = @($all | Where-Object { $_.Name -eq 'VulnerableDriverBlocklistEnable' })
    Assert-True ($blocklist.Count -eq 1 -and $blocklist[0].Value -eq '1') 'Haavoittuvien ajurien estolista ei ole pakotettu paalle'
    $asr = @($all | Where-Object { $_.Key -like '*Exploit Guard\ASR\Rules' })
    Assert-True ($asr.Count -ge 3 -and @($asr | Where-Object { $_.Value -ne '1' }).Count -eq 0) 'ASR-saannot eivat ole estotilassa (1)'
    foreach ($r in $asr) { Assert-True ($r.Name -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') "ASR-tunniste vaaraa muotoa: $($r.Name)" }
    $d = Get-Content -LiteralPath (Join-Path $root 'Policies\Debloat.json') -Raw | ConvertFrom-Json
    foreach ($svc in @('WinDefend', 'mpssvc', 'SecurityHealthService', 'wscsvc', 'Sense', 'WdNisSvc')) {
        Assert-True ($d.Palvelut -notcontains $svc) "Tietoturvapalvelu $svc poistolistalla"
    }
}

Test-Case 'Sovellukset: kayttajakohtaiset (Discord, Spotify) ja asennusohjelman odotus' {
    $none = Get-UserApps -Selection ([pscustomobject]@{ Discord = $false; Spotify = $false })
    Assert-True ($none.Count -eq 0) 'valitsematta asennettaisiin'
    $both = Get-UserApps -Selection ([pscustomobject]@{ Discord = $true; Spotify = $true })
    Assert-True ($both.Count -eq 2) "valittuja $($both.Count)"
    foreach ($a in $both) {
        Assert-True ($a.Url -match '^https://') "$($a.Name): ei HTTPS"
        Assert-True ($a.Publisher.Length -gt 3) "$($a.Name): julkaisija puuttuu"
        $parts = $a.Check -split '\\', 2
        Assert-True (@('LOCALAPPDATA', 'APPDATA') -contains $parts[0] -and $parts[1] -like '*.exe') "$($a.Name): tarkistuspolku $($a.Check)"
    }
    # Muokattu valintatiedosto (Kayttaja-kansio on kayttajan kirjoitettavissa)
    # ei voi tuoda omia osoitteita: vain luettelon nimet kelpaavat.
    $evil = Get-UserApps -Selection ([pscustomobject]@{ Discord = $true; Paha = $true; Url = 'http://x' })
    Assert-True ($evil.Count -eq 1 -and $evil[0].Name -eq 'Discord') 'tuntematon valinta kelpasi'
    Assert-True ($null -eq (Get-UserApps -Selection ([pscustomobject]@{ Discord = 'true' }))[0]) 'merkkijono true kelpasi totuusarvona'
    # Start-Process -Wait odottaisi myos lapsiprosesseja (Discord kaynnistyy asennuksen jalkeen).
    $fn = (Get-Command Install-SignedInstaller).ScriptBlock.Ast
    $sp = @($fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-Process' }, $true))
    Assert-True ($sp.Count -eq 1) "Start-Process-kutsuja $($sp.Count)"
    $waitParam = @($sp[0].CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Wait' })
    Assert-True ($waitParam.Count -eq 0) 'Install-SignedInstaller kayttaa Start-Process -Waitia'
    Assert-True ($fn.Extent.Text -match 'WaitForExit\(') 'ei aikarajallista odotusta'
}

Test-Case 'Rakennus: Windows-version valinta eri ISOista' {
    $pat = @('*IoT Enterprise LTSC*', '*Enterprise LTSC*', '*Pro', '*Enterprise*')
    $img = { param([string[]]$n) $i = 0; $n | ForEach-Object { $i++; [pscustomobject]@{ ImageIndex = $i; ImageName = $_ } } }
    $consumer = & $img @('Windows 11 Home', 'Windows 11 Home N', 'Windows 11 Education', 'Windows 11 Pro', 'Windows 11 Pro N', 'Windows 11 Pro Education', 'Windows 11 Pro for Workstations')
    Assert-True ((Select-ImageEdition -Images $consumer -Patterns $pat).ImageName -eq 'Windows 11 Pro') 'kuluttaja-ISO: Pro'
    $iot = & $img @('Windows 11 IoT Enterprise LTSC Evaluation')
    Assert-True ((Select-ImageEdition -Images $iot -Patterns $pat).ImageName -like '*IoT*') 'IoT LTSC'
    $ent = & $img @('Windows 11 Enterprise Evaluation')
    Assert-True ((Select-ImageEdition -Images $ent -Patterns $pat).ImageName -eq 'Windows 11 Enterprise Evaluation') 'Enterprise Evaluation'
    $both = & $img @('Windows 11 Enterprise', 'Windows 11 IoT Enterprise LTSC')
    Assert-True ((Select-ImageEdition -Images $both -Patterns $pat).ImageName -like '*IoT*') 'jarjestys: IoT LTSC ennen tavallista Enterprisea'
    Assert-True ($null -eq (Select-ImageEdition -Images (& $img @('Windows 11 Home')) -Patterns $pat)) 'Home ei kelpaa oletuksilla (ei gpeditia)'
}

Test-Case 'Secure Boot 2023: kaynnistystiedostot vaihdetaan kuten Microsoftin skriptissa' {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('irq-ca2023-' + [guid]::NewGuid().ToString('N'))
    try {
        $bootRoot = Join-Path $tmp 'mount'; $media = Join-Path $tmp 'media'
        $b = Join-Path $bootRoot 'Windows\Boot'
        New-Item -ItemType Directory -Path (Join-Path $b 'EFI_EX'), (Join-Path $b 'FONTS_EX'), (Join-Path $b 'DVD_EX\EFI\en-US'), (Join-Path $media 'efi\boot') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $b 'EFI_EX\bootmgfw_EX.efi') -Value 'uusi-2023'
        Set-Content -LiteralPath (Join-Path $b 'EFI_EX\bootmgr_EX.efi') -Value 'bootmgr-2023'
        Set-Content -LiteralPath (Join-Path $b 'FONTS_EX\segmono_boot_EX.ttf') -Value 'fontti'
        Set-Content -LiteralPath (Join-Path $b 'DVD_EX\EFI\en-US\efisys_EX.bin') -Value 'efisys'
        Set-Content -LiteralPath (Join-Path $media 'efi\boot\bootx64.efi') -Value 'vanha-2011'

        $img = Copy-Ca2023BootFiles -BootRoot $bootRoot -MediaRoot $media
        Assert-True ((Get-Content -LiteralPath (Join-Path $media 'efi\boot\bootx64.efi')) -eq 'uusi-2023') 'bootx64.efi ei vaihtunut'
        Assert-True ((Get-Content -LiteralPath (Join-Path $media 'bootmgr.efi')) -eq 'bootmgr-2023') 'bootmgr.efi puuttuu'
        Assert-True (Test-Path -LiteralPath (Join-Path $media 'efi\microsoft\boot\fonts\segmono_boot.ttf')) 'fontti ilman _EX-paatetta puuttuu'
        Assert-True ($img -like '*efisys_ex.bin') "ISO-kuva: $img"
        # ISO: 2023-mediaan ei koskaan 2011-kuvaa, vaikka ADK:ssa olisi 2011 noprompt.
        $adk = Join-Path $tmp 'adk'; New-Item -ItemType Directory -Path $adk -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $adk 'efisys_noprompt.bin') -Value 'x'
        $sel = Get-IsoEfiBootImage -MediaRoot $media -OscdimgDir $adk
        Assert-True ($sel.Ca2023 -and $sel.Path -like '*efisys_ex.bin' -and -not $sel.NoPrompt) "2023-valinta: $($sel.Path)"
        Set-Content -LiteralPath (Join-Path $adk 'efisys_noprompt_ex.bin') -Value 'x'
        $sel = Get-IsoEfiBootImage -MediaRoot $media -OscdimgDir $adk
        Assert-True ($sel.NoPrompt -and $sel.Path -like '*noprompt_ex.bin') "2023 noprompt ADK:sta: $($sel.Path)"
        # 2011-media: noprompt ADK:sta
        $m2 = Join-Path $tmp 'media2011'; New-Item -ItemType Directory -Path (Join-Path $m2 'efi\microsoft\boot') -Force | Out-Null
        $sel = Get-IsoEfiBootImage -MediaRoot $m2 -OscdimgDir $adk
        Assert-True (-not $sel.Ca2023 -and $sel.Path -like '*efisys_noprompt.bin') "2011-valinta: $($sel.Path)"
        # Puuttuvat _EX-tiedostot: selva virhe, ei puolivalmista mediaa.
        Remove-Item -LiteralPath (Join-Path $b 'FONTS_EX') -Recurse -Force
        $threw = $false; try { Copy-Ca2023BootFiles -BootRoot $bootRoot -MediaRoot $media | Out-Null } catch { $threw = $true }
        Assert-True $threw 'puuttuva FONTS_EX ei kaatanut'
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-Case 'Esitarkistus: Secure Boot -varmenteen valinta (KB5025885)' {
    $a = Get-SecureBootCaAdvice -SecureBoot 'On' -Db2023 $true -Pca2011Revoked $true
    Assert-True ($a.Ca -eq '2023' -and $a.Varma) "mitatoity: $($a.Ca)"
    $a = Get-SecureBootCaAdvice -SecureBoot 'On' -Db2023 $false -Pca2011Revoked $false
    Assert-True ($a.Ca -eq '2011' -and $a.Varma) "ei 2023-varmennetta: $($a.Ca)"
    $a = Get-SecureBootCaAdvice -SecureBoot 'On' -Db2023 $true -Pca2011Revoked $false
    Assert-True ($a.Ca -eq 'Kumpi tahansa' -and $a.Varma) "molemmat: $($a.Ca)"
    $a = Get-SecureBootCaAdvice -SecureBoot 'Off'
    Assert-True ($a.Ca -eq 'Kumpi tahansa' -and $a.Varma) "SB pois: $($a.Ca)"
    $a = Get-SecureBootCaAdvice -SecureBoot 'On'
    Assert-True ($a.Ca -eq '2011' -and -not $a.Varma) "tuntematon: $($a.Ca)"
    $a = Get-SecureBootCaAdvice
    Assert-True (-not $a.Varma) 'tuntematon SB-tila ei saa olla varma'
    # Mitatointi voittaa aina: 2011-tikku ei kaynnisty, vaikka DB-tietoa ei olisi.
    $a = Get-SecureBootCaAdvice -SecureBoot 'On' -Pca2011Revoked $true
    Assert-True ($a.Ca -eq '2023') "mitatoity, DB tuntematon: $($a.Ca)"
}

Test-Case 'Esitarkistus: vain valmistajan levyohjainajurit viedaan tikulle' {
    Assert-True (Test-ThirdPartyStorageDriver -InfPath 'oem12.inf' -Class 'SCSIAdapter') 'VMD (oem, SCSIAdapter)'
    Assert-True (Test-ThirdPartyStorageDriver -InfPath 'oem3.inf' -Class 'HDC') 'RST (oem, HDC)'
    Assert-True (-not (Test-ThirdPartyStorageDriver -InfPath 'stornvme.inf' -Class 'SCSIAdapter')) 'Windowsin NVMe-ajuri'
    Assert-True (-not (Test-ThirdPartyStorageDriver -InfPath 'oem7.inf' -Class 'Display')) 'naytonohjain'
    Assert-True (-not (Test-ThirdPartyStorageDriver -InfPath '' -Class 'HDC')) 'tuntematon inf'
}

Test-Case 'Turvallisuus: kayttaja ei voi muokata SYSTEMin ajamia skripteja' {
    # Suoraan C:n juureen luotu kansio perii "Authenticated Users: Modify".
    # Rekisteroinnin pitaa lukita C:\iRequire ennen ajastettujen tehtavien luontia.
    $reg = Get-Content -LiteralPath (Join-Path $root 'PostInstall\Register-PostInstall.ps1') -Raw
    $lock = $reg.IndexOf('& icacls.exe $base /inheritance:r')
    $task = $reg.IndexOf('Register-ScheduledTask')
    Assert-True ($lock -gt 0 -and $lock -lt $task) 'C:\iRequire-kansiota ei lukita ennen tehtavien rekisterointia'
    Assert-True ($reg -match "icacls\.exe \`$base /inheritance:r /grant:r '\*S-1-5-18:\(OI\)\(CI\)F' '\*S-1-5-32-544:\(OI\)\(CI\)F' '\*S-1-5-32-545:\(OI\)\(CI\)RX'") 'kayttajille muu kuin lukuoikeus'
    # Kayttajan istunnossa ajettava skripti kirjoittaa vain Kayttaja-kansioon.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'PostInstall\Show-Progress.ps1'), [ref]$null, [ref]$null)
    $writes = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
        @('Add-Content', 'Set-Content', 'Out-File', 'New-Item', 'Copy-Item', 'Move-Item', 'Remove-Item') -contains $n.GetCommandName() }, $true)
    Assert-True (@($writes).Count -gt 0) 'kirjoituksia ei loytynyt (testi rikki?)'
    foreach ($w in $writes) {
        Assert-True ($w.Extent.Text -match '\$userDir|\$marker') ("Show-Progress kirjoittaa muualle: {0}" -f $w.Extent.Text)
    }
    Assert-True ((Get-Content -LiteralPath (Join-Path $root 'PostInstall\Show-Progress.ps1') -Raw) -match "\`$marker = Join-Path \`$userDir") 'merkki ei ole Kayttaja-kansiossa'
}

Test-Case 'Tyhjennyksen kestoarvio laskurin ruudulle' {
    $tb = 1000000000000
    $hdd = Get-WipeEstimate -SizeBytes (2 * $tb) -Kind 'HDD'
    Assert-True ($hdd.Min -eq $hdd.Max -and $hdd.Max -gt 4 * 3600 -and $hdd.Max -lt 6 * 3600) "2 Tt HDD: $($hdd.Max) s"
    Assert-True ((Format-WipeEstimate $hdd) -match '^noin \d\.\d h$') ("HDD: " + (Format-WipeEstimate $hdd))
    $full = Get-WipeEstimate -SizeBytes (2 * $tb) -Kind 'HDD' -FullVerify
    Assert-True ([math]::Abs($full.Max - 2 * $hdd.Max) -le 1) 'taysi varmistus ei kaksinkertaista'
    $nvme = Get-WipeEstimate -SizeBytes $tb -Kind 'NVMe'
    Assert-True ($nvme.Min -le 120 -and $nvme.Max -gt 600) "NVMe: $($nvme.Min)-$($nvme.Max)"
    Assert-True ((Format-WipeEstimate $nvme) -match '^alle 2 min - \d+ min$') ("NVMe: " + (Format-WipeEstimate $nvme))
    Assert-True ((Format-Duration 30) -eq 'alle 2 min' -and (Format-Duration 600) -eq '10 min' -and (Format-Duration 5400) -eq '1.5 h') 'Format-Duration'
}

Test-Case 'Turvallisuus: odottamaton kaatuminen WinPE:ssa ei kaynnista tikkua alusta' {
    # winpeshl kaynnistaa WinPE:n uudelleen kun Bootstrap paattyy. Kaatumisen
    # jalkeen se kaynnistaisi saman tikun uudelleen -> pysahdyttava.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WinPE\Bootstrap.ps1'), [ref]$null, [ref]$null)
    $run = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.Extent.Text -match 'Start-iRequire\.ps1' }, $true))
    Assert-True ($run.Count -eq 1) 'Start-iRequiren kaynnistys puuttuu'
    $guard = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and
        $n.Clauses[0].Item1.Extent.Text -match 'LASTEXITCODE\s+-ne\s+0' -and $n.Clauses[0].Item2.Extent.Text -match 'wpeutil\.exe shutdown' }, $true))
    Assert-True ($guard.Count -eq 1 -and $guard[0].Extent.StartOffset -gt $run[0].Extent.EndOffset) 'kaatumisen jalkeen ei pysahdyta (WinPE kaynnistyisi uudelleen)'
    Assert-True ($guard[0].Clauses[0].Item2.Extent.Text -notmatch 'wpeutil\.exe reboot') 'kaatumisen jalkeen uudelleenkaynnistys'
}

Test-Case 'Tikun paivitys: skriptit uusiksi, asetukset ja LGPO sailyvat, manifesti ehja' {
    $usb = Join-Path ([System.IO.Path]::GetTempPath()) ('irq-usb-' + [guid]::NewGuid().ToString('N'))
    try {
        $ir = Join-Path $usb 'iRequire'
        foreach ($d in @('WinPE', 'Config', 'Tools', 'Drivers\vmd')) { New-Item -ItemType Directory -Path (Join-Path $ir $d) -Force | Out-Null }
        New-Item -ItemType Directory -Path (Join-Path $usb 'sources') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $ir 'iRequire.tag') -Value 'iRequire vanha'
        [System.IO.File]::WriteAllBytes((Join-Path $usb 'sources\install.swm'), [byte[]](1..200 | ForEach-Object { $_ % 256 }))
        Set-Content -LiteralPath (Join-Path $ir 'WinPE\Poistettu.ps1') -Value 'vanha'
        Set-Content -LiteralPath (Join-Path $ir 'Tools\LGPO.exe') -Value 'lgpo'
        Set-Content -LiteralPath (Join-Path $ir 'Drivers\vmd\iaStorVD.inf') -Value '[Version]'
        Set-Content -LiteralPath (Join-Path $ir 'Config\iRequire.json') -Value '{ "Kayttaja": { "Nimi": "pelaaja" } }'
        [void](New-MediaManifest -MediaRoot $usb)
        $old = Read-MediaManifest -MediaRoot $usb
        Assert-True ($old.ContainsKey('sources\install.swm')) 'vanha manifesti ei luettu'

        Copy-RepoPayload -RepoRoot $root -Destination $ir -KeepConfig
        [void](New-MediaManifest -MediaRoot $usb -Reuse $old)
        Assert-True ((Get-Content -LiteralPath (Join-Path $ir 'Config\iRequire.json') -Raw) -match 'pelaaja') 'kayttajan asetukset havisivat'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $ir 'WinPE\Poistettu.ps1'))) 'poistettu skripti jai tikulle'
        Assert-True (Test-Path -LiteralPath (Join-Path $ir 'WinPE\Start-iRequire.ps1')) 'uusi skripti puuttuu'
        Assert-True (Test-Path -LiteralPath (Join-Path $ir 'Tools\LGPO.exe')) 'LGPO.exe havisi'
        Assert-True (Test-Path -LiteralPath (Join-Path $ir 'Tools\Test-TargetMachine.ps1')) 'esitarkistus puuttuu'
        Assert-True (Test-Path -LiteralPath (Join-Path $ir 'Drivers\vmd\iaStorVD.inf')) 'tikun ajurit havisivat'
        $p = Test-MediaManifest -MediaRoot $usb
        Assert-True ($p.Count -eq 0) ('paivitetty tikku ei ehja: ' + ($p -join '; '))

        # Config-kansio ilman asetustiedostoa: tiedosto tulee kansioon, ei Config\Config-kansioon.
        Remove-Item -LiteralPath (Join-Path $ir 'Config\iRequire.json') -Force
        Copy-RepoPayload -RepoRoot $root -Destination $ir -KeepConfig
        Assert-True ((Test-Path -LiteralPath (Join-Path $ir 'Config\iRequire.json')) -and -not (Test-Path -LiteralPath (Join-Path $ir 'Config\Config'))) 'Config sisentyi'
        [void](New-MediaManifest -MediaRoot $usb -Reuse (Read-MediaManifest -MediaRoot $usb))

        # Uudelleenkaytetty tiiviste ei peita vioittumista: sama koko, eri sisalto -> WinPE huomaa.
        [System.IO.File]::WriteAllBytes((Join-Path $usb 'sources\install.swm'), [byte[]](1..200 | ForEach-Object { ($_ + 7) % 256 }))
        [void](New-MediaManifest -MediaRoot $usb -Reuse (Read-MediaManifest -MediaRoot $usb))
        $p = Test-MediaManifest -MediaRoot $usb
        Assert-True ($p.Count -ge 1) 'vioittunut asennuskuva meni lapi'
    } finally { Remove-Item -LiteralPath $usb -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-Case 'Asennus: kayttoliittyman kieli valitaan kuvan kielista' {
    Assert-True ((Select-UiLanguage -Wanted 'en-US' -Installed @('en-US')) -eq 'en-US') 'sama kieli'
    Assert-True ((Select-UiLanguage -Wanted 'en-US' -Installed @('fi-FI')) -eq 'fi-FI') 'suomenkielinen ISO'
    Assert-True ((Select-UiLanguage -Wanted 'fi-FI' -Installed @('en-US', 'fi-FI')) -eq 'fi-FI') 'monikielinen kuva'
    Assert-True ((Select-UiLanguage -Wanted 'en-US' -Installed @()) -eq 'en-US') 'tuntematon: pyydetty'
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('irq-lang-' + [guid]::NewGuid().ToString('N'))
    try {
        $s = Join-Path $tmp 'Windows\System32'
        foreach ($d in @('fi-FI', 'en-US', 'Boot', 'zh-CN')) { New-Item -ItemType Directory -Path (Join-Path $s $d) -Force | Out-Null }
        Set-Content -LiteralPath (Join-Path $s 'fi-FI\kernel32.dll.mui') -Value 'x'
        Set-Content -LiteralPath (Join-Path $s 'zh-CN\kernel32.dll.mui') -Value 'x'
        # en-US-kansio ilman kernel32.dll.mui:ta (osittainen kieli) ei ole kayttoliittymakieli.
        $l = Get-OfflineUiLanguages -WindowsRoot $tmp
        Assert-True (($l -join ',') -eq 'fi-FI,zh-CN') ("kielet: " + ($l -join ','))
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-Case 'Turvallisuus: harjoitustila pysahtyy ennen yhtakaan kirjoittavaa kutsua' {
    # Rakennetesti: tuleva muutos ei saa siirtaa levylle kirjoittavaa kutsua
    # harjoitustilan pysahdyksen eteen, eika laskuria/tarkistuksia sen jalkeen.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WinPE\Start-iRequire.ps1'), [ref]$null, [ref]$null)
    $writers = @('Invoke-DiskWipe', 'New-WindowsPartitions', 'Install-WindowsImage', 'Add-MachineDrivers', 'Copy-Payload',
                 'Set-BootFiles', 'Invoke-Diskpart', 'Clear-Disk', 'Initialize-Disk', 'Write-WipeCertificate', 'Write-Canaries')
    $dryIf = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and
        $n.Clauses[0].Item1.Extent.Text -eq '$dryRun' -and $n.Clauses[0].Item2.Extent.Text -match 'Stop-Here\s+"Harjoitus valmis' }, $true))
    Assert-True ($dryIf.Count -eq 1) "harjoitustilan pysahdyslohkoja $($dryIf.Count), odotettiin 1"
    $stop = $dryIf[0].Extent.EndOffset
    $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $calls) {
        $name = $c.GetCommandName()
        if ($writers -contains $name) {
            Assert-True ($c.Extent.StartOffset -gt $stop) ("{0} (rivi {1}) ennen harjoitustilan pysahdysta" -f $name, $c.Extent.StartScriptPosition.LineNumber)
        }
    }
    # Laskuri (Esc) ja tikun eheys ennen pysahdysta: harjoitus nayttaa saman kuin oikea ajo.
    foreach ($must in @('Test-MediaManifest', 'Wait-Key', 'Select-TargetDisk')) {
        $first = @($calls | Where-Object { $_.GetCommandName() -eq $must } | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1)
        Assert-True ($first.Count -eq 1 -and $first[0].Extent.StartOffset -lt $stop) "$must puuttuu ennen harjoitustilan pysahdysta"
    }
}

Test-Case 'WinPE: vain tallennusohjainten ajurit ladataan (Intel VMD tikulta)' {
    $vmd = "; Intel RST VMD`r`n[Version]`r`nSignature=`"`$WINDOWS NT`$`"`r`nClass=SCSIAdapter`r`nClassGuid={4D36E97B-E325-11CE-BFC1-08002BE10318}`r`nProvider=%INTEL%`r`n"
    Assert-True (Test-StorageDriverInf -Text $vmd) 'VMD (SCSIAdapter) ei kelvannut'
    Assert-True (Test-StorageDriverInf -Text "[version]`nClass = HDC ; AHCI") 'HDC ei kelvannut'
    Assert-True (-not (Test-StorageDriverInf -Text "[Version]`nClass=Net`n")) 'verkkoajuri kelpasi'
    Assert-True (-not (Test-StorageDriverInf -Text "[Version]`nClass=Display`n[Strings]`nClass=SCSIAdapter")) 'Strings-osion arvo luettiin luokaksi'
    Assert-True (-not (Test-StorageDriverInf -Text "[Strings]`nClass=SCSIAdapter`n[Version]`nClass=Display")) 'toisen osion Class luettiin ennen Versionia'
    Assert-True (-not (Test-StorageDriverInf -Text '')) 'tyhja kelpasi'
    Assert-True (-not (Test-StorageDriverInf -Text "[Version]`n;Class=SCSIAdapter`nClass=Media")) 'kommentoitu rivi luettiin'
}

Test-Case 'Asennus: bcdboot kokeilee ensin /bootex, varalla tavallinen' {
    $script:bcdCalls = New-Object System.Collections.Generic.List[string]
    $script:bcdFailBootex = $false
    function script:bcdboot.exe { $script:bcdCalls.Add(($args -join ' ')); $global:LASTEXITCODE = $(if ($script:bcdFailBootex -and ($args -contains '/bootex')) { 87 } else { 0 }) }
    function script:Set-InternalBootFirst { }
    try {
        Set-BootFiles -Windows 'W:' -System 'S:' -Firmware 'UEFI'
        Assert-True ($script:bcdCalls.Count -eq 1 -and $script:bcdCalls[0] -match '/f UEFI /bootex$') ('UEFI: ' + ($script:bcdCalls -join ' | '))
        $script:bcdCalls.Clear(); $script:bcdFailBootex = $true
        Set-BootFiles -Windows 'W:' -System 'S:' -Firmware 'UEFI'
        Assert-True ($script:bcdCalls.Count -eq 2 -and $script:bcdCalls[1] -notmatch 'bootex') ('varalla: ' + ($script:bcdCalls -join ' | '))
        $script:bcdCalls.Clear()
        Set-BootFiles -Windows 'W:' -System 'S:' -Firmware 'BIOS'
        Assert-True ($script:bcdCalls.Count -eq 1 -and $script:bcdCalls[0] -notmatch 'bootex' -and $script:bcdCalls[0] -match '/f BIOS') ('BIOS: ' + ($script:bcdCalls -join ' | '))
    } finally {
        Remove-Item -Path Function:\bcdboot.exe -ErrorAction SilentlyContinue
        Remove-Item -Path Function:\Set-InternalBootFirst -ErrorAction SilentlyContinue
        . (Join-Path $root 'WinPE\Deploy.ps1')
    }
}

Test-Case 'Pelikunto: Secure Boot ja TPM (huijauksenestot)' {
    $txt = { param($f) ($f.ToArray() | ForEach-Object { "$($_.Taso): $($_.Teksti)" }) -join "`n" }
    $t = & $txt (Get-GamingFindings -HasBattery $false -SecureBoot 'On' -Tpm 'Ready')
    Assert-True ($t -match 'OK: Secure Boot ja TPM 2.0 paalla') "kunnossa: $t"
    Assert-True ($t -cnotmatch '(?m)^(Toimi|Huomio):') "aiheeton havainto: $t"
    $t = & $txt (Get-GamingFindings -HasBattery $false -SecureBoot 'Off' -Tpm 'None')
    Assert-True ($t -match 'Toimi: Secure Boot on pois') "SB pois: $t"
    Assert-True ($t -match 'Toimi: TPM 2.0 ei ole') "TPM puuttuu: $t"
    Assert-True ($t -notmatch '(?m)^OK: Secure Boot') 'OK vaikka puuttuu'
    $t = & $txt (Get-GamingFindings -HasBattery $false -SecureBoot 'Legacy' -Tpm 'Old')
    Assert-True ($t -match 'Toimi: Secure Boot ei ole kaytettavissa') "Legacy: $t"
    Assert-True ($t -match 'Huomio: TPM on vanhaa 1.2') "TPM 1.2: $t"
    # Tuntematon tila (tietoa ei saatu) ei tuota havaintoa suuntaan eika toiseen.
    $t = & $txt (Get-GamingFindings -HasBattery $false)
    Assert-True ($t -notmatch 'Secure Boot|TPM') "tuntematon tila: $t"
}

Test-Case 'Tietoturva: ASR-saantojen estotilan laskenta' {
    Assert-True ((Get-AsrBlockCount -Ids @('a', 'b', 'c') -Actions @(1, 1, 1)) -eq 3) 'kolme estotilassa'
    Assert-True ((Get-AsrBlockCount -Ids @('a', 'b', 'c') -Actions @(1, 2, 6)) -eq 1) 'valvonta (2) ja varoitus (6) eivat ole estoa'
    Assert-True ((Get-AsrBlockCount -Ids @('a', 'b') -Actions @(1)) -eq 1) 'puuttuva toiminto'
    Assert-True ((Get-AsrBlockCount -Ids $null -Actions $null) -eq 0) 'ei saantoja (null)'
    Assert-True ((Get-AsrBlockCount -Ids 'a' -Actions 1) -eq 1) 'yksi saanto skalaarina'
}

Test-Case 'Naytto: suurin taajuus samalla tarkkuudella, ei lomitettuja' {
    $cur = [pscustomobject]@{ Width = 2560; Height = 1440; Bpp = 32; Hz = 60; Flags = 0 }
    $modes = @(
        [pscustomobject]@{ Width = 2560; Height = 1440; Bpp = 32; Hz = 60; Flags = 0 },
        [pscustomobject]@{ Width = 2560; Height = 1440; Bpp = 32; Hz = 144; Flags = 0 },
        [pscustomobject]@{ Width = 2560; Height = 1440; Bpp = 32; Hz = 165; Flags = 0 },
        [pscustomobject]@{ Width = 2560; Height = 1440; Bpp = 32; Hz = 200; Flags = 2 },
        [pscustomobject]@{ Width = 1920; Height = 1080; Bpp = 32; Hz = 240; Flags = 0 },
        [pscustomobject]@{ Width = 2560; Height = 1440; Bpp = 16; Hz = 180; Flags = 0 }
    )
    $b = Select-BestDisplayMode -Current $cur -Modes $modes
    Assert-True ($b.Hz -eq 165) "Valittiin $($b.Hz) Hz"
    $cur.Hz = 165
    Assert-True ($null -eq (Select-BestDisplayMode -Current $cur -Modes $modes)) 'Jo suurin, silti vaihto'
}

Test-Case 'Naytto: Win32-rakenteet kaantyvat ja ovat oikean kokoisia' {
    Initialize-DisplayApi
    $dm = [IRequireDisplay]::NewDevMode()
    Assert-True ($dm.dmSize -eq 220) "DEVMODEW on 220 tavua, nyt $($dm.dmSize)"
    $dd = [IRequireDisplay]::NewDisplayDevice()
    Assert-True ($dd.cb -eq 840) "DISPLAY_DEVICEW on 840 tavua, nyt $($dd.cb)"
}

Test-Case 'Pelikunto: XMP pois, yksi kampa, naytto emolevyssa, HDD, ajastimet' {
    $mem = @([pscustomobject]@{ Type = 34; Configured = 4800; CapacityGb = 16 })
    $gpus = @(
        [pscustomobject]@{ Name = 'NVIDIA GeForce RTX 4070'; Active = $false; CurrentHz = 0; MaxHz = 0; Basic = $false },
        [pscustomobject]@{ Name = 'Intel(R) UHD Graphics 770'; Active = $true; CurrentHz = 60; MaxHz = 144; Basic = $false }
    )
    $f = Get-GamingFindings -Memory $mem -Gpus $gpus -HasBattery $false -SystemDiskKind 'HDD' -TimerOverrides @('useplatformclock')
    $t = ($f.ToArray() | ForEach-Object { "$($_.Taso): $($_.Teksti)" }) -join "`n"
    Assert-True ($t -match 'Toimi: RAM toimii perusnopeudella DDR5 4800') 'XMP puuttuu'
    Assert-True ($t -match 'Toimi: Vain yksi muistikampa') 'Yksi kampa puuttuu'
    Assert-True ($t -match 'Toimi: Naytto on kytketty emolevyn') 'iGPU-kytkenta puuttuu'
    Assert-True ($t -match 'Huomio: Naytto .* 60 Hz, suurin tuettu 144') 'Taajuus puuttuu'
    Assert-True ($t -match 'Toimi: Windows on kiintolevylla') 'HDD puuttuu'
    Assert-True ($t -match 'useplatformclock') 'Ajastin puuttuu'
}

Test-Case 'Pelikunto: kunnossa oleva kone ei saa aiheettomia varoituksia' {
    $mem = @([pscustomobject]@{ Type = 34; Configured = 6000; CapacityGb = 16 }, [pscustomobject]@{ Type = 34; Configured = 6000; CapacityGb = 16 })
    $gpus = @(
        [pscustomobject]@{ Name = 'AMD Radeon RX 7800 XT'; Active = $true; CurrentHz = 165; MaxHz = 165; Basic = $false },
        [pscustomobject]@{ Name = 'AMD Radeon(TM) Graphics'; Active = $false; CurrentHz = 0; MaxHz = 0; Basic = $false }
    )
    $f = Get-GamingFindings -Memory $mem -Gpus $gpus -HasBattery $false -SystemDiskKind 'SSD'
    $bad = @($f.ToArray() | Where-Object { $_.Taso -ne 'OK' })
    Assert-True ($bad.Count -eq 0) ('Aiheettomia: ' + (($bad | ForEach-Object { $_.Teksti }) -join ' | '))
    Assert-True (Test-DiscreteGpuName 'AMD Radeon RX 7800 XT') 'RX erillisnaytonohjaimeksi'
    Assert-True (-not (Test-DiscreteGpuName 'AMD Radeon(TM) Graphics')) 'Integroitu Radeon ei ole erillinen'
    Assert-True (Test-DiscreteGpuName 'Intel(R) Arc(TM) A770 Graphics') 'Arc erillisnaytonohjaimeksi'
    foreach ($igpu in @('AMD Radeon 780M Graphics', 'AMD Radeon(TM) Vega 8 Graphics', 'Intel(R) UHD Graphics 770', 'Intel(R) Iris(R) Xe Graphics', 'Intel(R) Arc(TM) Graphics')) {
        Assert-True (-not (Test-DiscreteGpuName $igpu)) "$igpu tulkittiin erilliseksi"
    }
    foreach ($dgpu in @('NVIDIA GeForce GTX 1060 6GB', 'AMD Radeon RX 6600', 'AMD Radeon R9 290', 'NVIDIA RTX A2000')) {
        Assert-True (Test-DiscreteGpuName $dgpu) "$dgpu ei tunnistettu erilliseksi"
    }
}

Test-Case 'Pelikunto: WMI:n erikoisarvot (0/1 Hz) eivat ole taajuuksia' {
    # Loytyi oikealla Windowsilla: Hyper-V-naytto ilmoitti 1 Hz / 64 Hz.
    $gpus = @([pscustomobject]@{ Name = 'Microsoft Hyper-V Video'; Active = $true; CurrentHz = 1; MaxHz = 64; Basic = $false })
    $f = Get-GamingFindings -Gpus $gpus -HasBattery $false
    Assert-True (@($f.ToArray() | Where-Object { $_.Teksti -match 'Hz' }).Count -eq 0) 'Erikoisarvosta tehtiin taajuushavainto'
}

Test-Case 'Pelikunto: kannettavan Optimus-kytkenta ei ole virhe' {
    $gpus = @(
        [pscustomobject]@{ Name = 'NVIDIA GeForce RTX 4060 Laptop GPU'; Active = $false; CurrentHz = 0; MaxHz = 0; Basic = $false },
        [pscustomobject]@{ Name = 'Intel(R) Iris(R) Xe Graphics'; Active = $true; CurrentHz = 144; MaxHz = 144; Basic = $false }
    )
    $f = Get-GamingFindings -Gpus $gpus -HasBattery $true
    Assert-True (@($f.ToArray() | Where-Object { $_.Teksti -match 'emolevyn' }).Count -eq 0) 'Kannettavalle aiheeton varoitus'
}

Test-Case 'Ajastimet: pakotetut asetukset tunnistetaan bcdeditin tulosteesta' {
    $bcd = "identifier              {current}`ndevice                  partition=C:`nuseplatformclock        Yes`ndisabledynamictick      Yes`nnx                      OptIn"
    $found = Get-TimerOverrides -BcdText $bcd
    Assert-True (($found -join ',') -eq 'useplatformclock,disabledynamictick') "Loytyi: $($found -join ',')"
    Assert-True ((Get-TimerOverrides -BcdText "identifier {current}`nnx OptIn").Count -eq 0) 'Oletuksessa loytyi jotain'
}

Test-Case 'Tilakone: kaikki vaiheet kerran, yksi kaynnistys' {
    $script:Calls = New-Object System.Collections.Generic.List[string]
    $h = @{ 'A' = { $script:Calls.Add('A') }; 'Paivitykset' = { $script:Calls.Add('P') }; 'B' = { $script:Calls.Add('B') } }
    $r = Invoke-SimulatedBoots -Stages $simStages -Handlers $h
    Assert-True ($r.Result -eq 'Done' -and $r.Boots -eq 1) "$($r.Result) $($r.Boots)"
    Assert-True (($script:Calls -join '') -eq 'APB') "Jarjestys $($script:Calls -join '')"
    Assert-True (@(@($r.State.Ohitetut) | Where-Object { $_ }).Count -eq 0) 'onnistuneessa ajossa ohitettuja'
}

Test-Case 'Tilakone: paivityskierrokset jatkuvat kaynnistysten yli, valmis vaihe ei toistu' {
    $script:Calls = New-Object System.Collections.Generic.List[string]
    $h = @{
        'A' = { $script:Calls.Add('A') }
        'Paivitykset' = { param($s)
            $s.Kierros++
            $script:Calls.Add("P$($s.Kierros)")
            if ($s.Kierros -lt 3) { New-RebootRequest 'paivitys' } }
        'B' = { $script:Calls.Add('B') }
    }
    $r = Invoke-SimulatedBoots -Stages $simStages -Handlers $h
    Assert-True ($r.Result -eq 'Done' -and $r.Boots -eq 3) "$($r.Result) $($r.Boots)"
    Assert-True (($script:Calls -join ',') -eq 'A,P1,P2,P3,B') "Jarjestys $($script:Calls -join ',')"
}

Test-Case 'Tilakone: aina uudelleenkaynnistysta pyytava vaihe ei jaa silmukkaan kun kierroksia rajoitetaan' {
    $h = @{
        'A' = { }
        'Paivitykset' = { param($s) if ($s.Kierros -ge 4) { return }; $s.Kierros++; New-RebootRequest 'aina' }
        'B' = { }
    }
    $r = Invoke-SimulatedBoots -Stages $simStages -Handlers $h
    Assert-True ($r.Result -eq 'Done') $r.Result
}

Test-Case 'Tilakone: virhe yritetaan kerran uudelleen ja ohitetaan sitten' {
    $script:Calls = New-Object System.Collections.Generic.List[string]
    $h = @{ 'A' = { $script:Calls.Add('A'); throw 'rikki' }; 'Paivitykset' = { $script:Calls.Add('P') }; 'B' = { $script:Calls.Add('B') } }
    $r = Invoke-SimulatedBoots -Stages $simStages -Handlers $h
    Assert-True ($r.Result -eq 'Done') $r.Result
    Assert-True (($script:Calls -join '') -eq 'AAPB') "Jarjestys $($script:Calls -join '')"
    # Ohitus kirjataan (ja sailyy tilatiedoston JSON-kierroksen yli) yhteenvetoa varten.
    $sk = @(@($r.State.Ohitetut) | Where-Object { $_ })
    Assert-True ($sk.Count -eq 1 -and $sk[0] -eq 'A: rikki') ("Ohitetut: " + ($sk -join ' | '))
}

Test-Case 'Tilakone: jatkuvasti kaatuva viimeinen vaihe paattyy ilman silmukkaa' {
    $h = @{ 'A' = { }; 'Paivitykset' = { }; 'B' = { throw 'aina rikki' } }
    $r = Invoke-SimulatedBoots -Stages $simStages -Handlers $h
    Assert-True ($r.Result -eq 'Abandoned' -and $r.Boots -le 3) "$($r.Result) $($r.Boots)"
    Assert-True ($r.State.Valmis) 'Tila ei merkitty valmiiksi'
}

Test-Case 'Tilakone: jokainen vaihe kaatuu -> silti paattyy' {
    $h = @{ 'A' = { throw 'x' }; 'Paivitykset' = { throw 'y' }; 'B' = { throw 'z' } }
    $r = Invoke-SimulatedBoots -Stages $simStages -Handlers $h
    Assert-True ($r.Result -ne 'SILMUKKA') 'Jai silmukkaan'
    Assert-True ($r.Boots -le 7) "Kaynnistyksia $($r.Boots)"
    $sk = @(@($r.State.Ohitetut) | Where-Object { $_ })
    Assert-True ($sk.Count -eq 3) ("kaikki kolme ohitettua kirjattu: " + ($sk -join ' | '))
}

Test-Case 'Tilakone: vioittunut vaihe tilatiedostossa aloittaa alusta' {
    $script:Calls = New-Object System.Collections.Generic.List[string]
    $h = @{ 'A' = { $script:Calls.Add('A') }; 'Paivitykset' = { $script:Calls.Add('P') }; 'B' = { $script:Calls.Add('B') } }
    $bad = [pscustomobject]@{ Vaihe = 'EiOlemassa'; Kierros = 99; Valmis = $false }
    [void](Invoke-SimulatedBoots -Stages $simStages -Handlers $h -State $bad)
    Assert-True (($script:Calls -join '') -eq 'APB') "Jarjestys $($script:Calls -join '') (viimeinen vaihe ajettiin ensin?)"
}

Test-Case 'Tilakone: vaiheen muu tuloste ei tulkitu uudelleenkaynnistyspyynnoksi' {
    $h = @{ 'A' = { $true; 'teksti'; 42; [pscustomobject]@{ Reboot = $false } }; 'Paivitykset' = { }; 'B' = { } }
    $r = Invoke-SimulatedBoots -Stages $simStages -Handlers $h
    Assert-True ($r.Result -eq 'Done' -and $r.Boots -eq 1) "$($r.Result) $($r.Boots)"
}

Test-Case 'Tilakone: valmis tila ei aja mitaan' {
    $script:Calls = New-Object System.Collections.Generic.List[string]
    $h = @{ 'A' = { $script:Calls.Add('A') }; 'Paivitykset' = { }; 'B' = { } }
    [void](Invoke-SimulatedBoots -Stages $simStages -Handlers $h -State ([pscustomobject]@{ Vaihe = 'A'; Valmis = $true }))
    Assert-True ($script:Calls.Count -eq 0) 'Valmis tila ajoi vaiheita'
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host ("{0} tarkistusta epaonnistui" -f $failures.Count) -ForegroundColor Red
    exit 1
}
Write-Host 'Kaikki tarkistukset lapi.' -ForegroundColor Green
