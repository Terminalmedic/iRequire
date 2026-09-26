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
        'Start-VM','Stop-Service','Unregister-ScheduledTask','Update-MpSignature','Update-Disk')
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
    $json = Get-Content -LiteralPath (Join-Path $root 'Config\iRequire.json') -Raw | ConvertFrom-Json
    $defaults = Get-IRequireConfig -Path (Join-Path $root 'ei-ole-olemassa.json')
    foreach ($section in $json.PSObject.Properties) {
        if ($section.Name.StartsWith('_')) { continue }
        Assert-True ($defaults.ContainsKey($section.Name)) "Tuntematon osio: $($section.Name)"
        foreach ($k in $section.Value.PSObject.Properties) {
            if ($k.Name.StartsWith('_')) { continue }
            Assert-True ($defaults[$section.Name].ContainsKey($k.Name)) "Tuntematon avain: $($section.Name).$($k.Name)"
        }
    }
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

Test-Case 'Asennuksen lopputarkistus huomaa puuttuvan tiedoston' {
    $w = Join-Path ([System.IO.Path]::GetTempPath()) ('irq-w-' + [guid]::NewGuid().ToString('N'))
    $sy = Join-Path ([System.IO.Path]::GetTempPath()) ('irq-s-' + [guid]::NewGuid().ToString('N'))
    try {
        $files = @("$w\Windows\System32\config\SYSTEM", "$w\Windows\System32\winload.efi", "$w\Windows\Panther\unattend.xml",
                   "$w\Windows\Setup\Scripts\SetupComplete.cmd", "$w\iRequire\PostInstall\Invoke-PostInstall.ps1",
                   "$w\iRequire\Lib\Common.ps1", "$w\iRequire\Lib\Stages.ps1", "$w\iRequire\Config\iRequire.json", "$w\iRequire\Policies\Debloat.json",
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

Test-Case 'Tilakone: kaikki vaiheet kerran, yksi kaynnistys' {
    $script:Calls = New-Object System.Collections.Generic.List[string]
    $h = @{ 'A' = { $script:Calls.Add('A') }; 'Paivitykset' = { $script:Calls.Add('P') }; 'B' = { $script:Calls.Add('B') } }
    $r = Invoke-SimulatedBoots -Stages $simStages -Handlers $h
    Assert-True ($r.Result -eq 'Done' -and $r.Boots -eq 1) "$($r.Result) $($r.Boots)"
    Assert-True (($script:Calls -join '') -eq 'APB') "Jarjestys $($script:Calls -join '')"
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
}

Test-Case 'Tilakone: vioittunut vaihe tilatiedostossa aloittaa alusta' {
    $script:Calls = New-Object System.Collections.Generic.List[string]
    $h = @{ 'A' = { $script:Calls.Add('A') }; 'Paivitykset' = { $script:Calls.Add('P') }; 'B' = { $script:Calls.Add('B') } }
    $bad = [pscustomobject]@{ Vaihe = 'EiOlemassa'; Kierros = 99; Valmis = $false }
    $r = Invoke-SimulatedBoots -Stages $simStages -Handlers $h -State $bad
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
    $r = Invoke-SimulatedBoots -Stages $simStages -Handlers $h -State ([pscustomobject]@{ Vaihe = 'A'; Valmis = $true })
    Assert-True ($script:Calls.Count -eq 0) 'Valmis tila ajoi vaiheita'
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host ("{0} tarkistusta epaonnistui" -f $failures.Count) -ForegroundColor Red
    exit 1
}
Write-Host 'Kaikki tarkistukset lapi.' -ForegroundColor Green
