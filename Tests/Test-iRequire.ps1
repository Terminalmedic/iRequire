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
. (Join-Path $root 'WinPE\Disk.ps1')
. (Join-Path $root 'WinPE\Deploy.ps1')

Test-Case 'Kaikki .ps1-tiedostot jasentyvat' {
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1)) {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors) | Out-Null
        Assert-True (-not $errors -or $errors.Count -eq 0) ("{0}: {1}" -f $f.Name, ($errors | Select-Object -First 1))
    }
}

Test-Case 'Skriptit ovat ASCII-muotoisia (WinPE-konsoli ja PS 5.1 ilman BOMia)' {
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -Include *.ps1, *.cmd, *.ini, *.txt)) {
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
    Assert-True ((Select-TargetDisk -Disks $disks -MinimumGb 4).Number -eq 2) 'NVMe ei voittanut'
    Assert-True ($null -eq (Select-TargetDisk -Disks $disks -MinimumGb 5000)) 'Liian pieni kelpasi'
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host ("{0} tarkistusta epaonnistui" -f $failures.Count) -ForegroundColor Red
    exit 1
}
Write-Host 'Kaikki tarkistukset lapi.' -ForegroundColor Green
