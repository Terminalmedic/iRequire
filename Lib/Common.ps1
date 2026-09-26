# ==============================================================
#  Lib\Common.ps1 - iRequiren yhteiset apufunktiot
#
#  Ladataan seka WinPE:ssa etta asennetussa Windowsissa, joten tassa
#  saa kayttaa vain PowerShell 5.1:n perusominaisuuksia: WinPE:ssa ei
#  ole moduuleja eika .NET-kaantajaa.
# ==============================================================

$script:LogFile = $null
$script:SerialPort = $null

function Enable-SerialLog {
    <# Lokirivit myos sarjaporttiin COM1 (Asennus.LokiSarjaporttiin).
       Automaattinen testi lukee ne virtuaalikoneen ulkopuolelta reaaliajassa. #>
    try {
        $p = New-Object System.IO.Ports.SerialPort 'COM1', 115200
        $p.Open()
        $script:SerialPort = $p
    } catch {
        $script:SerialPort = $null
    }
}

function Start-Log {
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:LogFile = $Path
    Write-IRequireLog ("==== {0} aloitettu ====" -f (Split-Path -Leaf $Path))
}

function Write-IRequireLog {
    <# Kirjoittaa seka konsoliin etta lokiin. Lokin kirjoitusvirhe ei saa
       koskaan kaataa ajoa: tikku voi olla irrotettu kesken kaiken. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info','Ok','Varoitus','Virhe')][string]$Level = 'Info'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpper(), $Message
    $color = switch ($Level) { 'Ok' { 'Green' } 'Varoitus' { 'Yellow' } 'Virhe' { 'Red' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
    if ($script:SerialPort) {
        try { $script:SerialPort.WriteLine($line) } catch { }
    }
}

function Get-WritableDirectory {
    <# Ensimmainen ehdokkaista johon voi oikeasti kirjoittaa. Tikku voi olla
       kirjoitussuojattu tai media ISO, jolloin raportit menevat muualle. #>
    param([Parameter(Mandatory)][string[]]$Candidates)
    foreach ($c in $Candidates) {
        try {
            New-Item -ItemType Directory -Path $c -Force -ErrorAction Stop | Out-Null
            $probe = Join-Path $c '.kirjoitustesti'
            Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            return $c
        } catch { }
    }
    throw ('Mihinkaan ei voi kirjoittaa: ' + ($Candidates -join ', '))
}

function Get-IRequireConfig {
    <# Lukee asetukset. Puuttuvat kentat taydennetaan oletuksilla, jotta
       vanhemmalla asetustiedostolla varustettu tikku toimii edelleen. #>
    param([Parameter(Mandatory)][string]$Path)

    $defaults = @{
        Kayttaja    = @{ Nimi = 'user'; Salasana = '' }
        Kone        = @{ Nimi = '*' }
        Alue        = @{ Kayttoliittyma = 'en-US'; Alue = 'fi-FI'; Nappaimisto = '040b:0000040b'; Aikavyohyke = 'FLE Standard Time' }
        Tyhjennys   = @{ LaskuriSekuntia = 15; Naytteita = 256; KaikkiSisaisetLevyt = $true; MinimikokoGt = 40
                         TaysiVarmistus = $false; Harjoitus = $false; TarkistaMedia = $true; OdotaVerkkovirtaa = $true }
        Asennus     = @{ Tuoteavain = ''; AutomaattikirjautuminenPysyva = $false; LopuksiSammutus = $false; LokiSarjaporttiin = $false }
        Wlan        = @{ Ssid = ''; Salasana = '' }
        Paivitykset = @{ MaksimiKierrokset = 6; Ajurit = $true; VerkonOdotusMinuuttia = 10 }
        Sovellukset = @{ Firefox = $false; VCRedist = $true; DirectX = $true }
        Suorituskyky = @{ Virrankaytto = 'auto'; GpuAjoitus = $true; IkkunoidutPelit = $true; HorrostilaPois = 'auto'
                          AktiivisetTunnitAlku = 8; AktiivisetTunnitLoppu = 2 }
        Tietoturva  = @{ BitLocker = $false }
    }

    $json = $null
    if (Test-Path -LiteralPath $Path) {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    $cfg = @{}
    foreach ($section in $defaults.Keys) {
        $cfg[$section] = @{}
        foreach ($k in $defaults[$section].Keys) {
            $v = $defaults[$section][$k]
            if ($json -and $json.PSObject.Properties.Name -contains $section) {
                $s = $json.$section
                if ($s.PSObject.Properties.Name -contains $k) { $v = $s.$k }
            }
            $cfg[$section][$k] = $v
        }
    }
    return $cfg
}

# ==============================================================
#  Kaytantotiedostot (LGPO:n tekstimuoto)
#
#  Muoto on sama jota Microsoftin LGPO.exe /t lukee, joten samat
#  tiedostot kelpaavat seka LGPO:lle etta omalle varakirjoittajalle:
#
#      Computer | User
#      Avaimen polku (ilman HKLM/HKCU-etuliitetta)
#      Arvon nimi
#      DWORD:n | SZ:teksti | EXSZ:teksti | DELETE
#
#  Tietueet erotetaan tyhjalla rivilla, ';' aloittaa kommentin.
# ==============================================================

function Read-PolicyFile {
    param([Parameter(Mandatory)][string]$Path)

    $entries = New-Object System.Collections.Generic.List[object]
    $buffer = New-Object System.Collections.Generic.List[string]
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8) + @('')
    $lineNo = 0

    foreach ($raw in $lines) {
        $lineNo++
        $ln = $raw.Trim()
        if ($ln.StartsWith(';')) { continue }
        if ($ln -ne '') { $buffer.Add($ln); continue }
        if ($buffer.Count -eq 0) { continue }

        if ($buffer.Count -ne 4) {
            throw ("{0}: rivia {1} edeltava tietue on {2} rivin mittainen, pitaa olla 4" -f $Path, $lineNo, $buffer.Count)
        }
        $scope = $buffer[0]
        if ($scope -notin @('Computer', 'User')) {
            throw ("{0}: tuntematon alue '{1}' ennen rivia {2}" -f $Path, $scope, $lineNo)
        }
        $action = $buffer[3]
        if ($action -notmatch '^(DWORD:\d+|SZ:.*|EXSZ:.*|DELETE)$') {
            throw ("{0}: tuntematon arvo '{1}' ennen rivia {2}" -f $Path, $action, $lineNo)
        }
        $type, $value = $action -split ':', 2
        $entries.Add([pscustomobject]@{
            Scope = $scope
            Key   = $buffer[1]
            Name  = $buffer[2]
            Type  = $type
            Value = $value
        })
        $buffer.Clear()
    }
    return ,$entries
}

function Set-PolicyEntry {
    <# Kirjoittaa yhden kaytantotietueen annetun juuren alle, esim.
       'HKLM:\' tai ladattu oletuskayttajan hive 'Registry::HKEY_USERS\X'. #>
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$Root
    )
    $keyPath = Join-Path $Root $Entry.Key
    if ($Entry.Type -eq 'DELETE') {
        if (Test-Path -LiteralPath $keyPath) {
            Remove-ItemProperty -LiteralPath $keyPath -Name $Entry.Name -ErrorAction SilentlyContinue
        }
        return
    }
    if (-not (Test-Path -LiteralPath $keyPath)) { New-Item -Path $keyPath -Force | Out-Null }
    switch ($Entry.Type) {
        'DWORD' { New-ItemProperty -LiteralPath $keyPath -Name $Entry.Name -PropertyType DWord -Value ([uint32]$Entry.Value) -Force | Out-Null }
        'SZ'    { New-ItemProperty -LiteralPath $keyPath -Name $Entry.Name -PropertyType String -Value $Entry.Value -Force | Out-Null }
        'EXSZ'  { New-ItemProperty -LiteralPath $keyPath -Name $Entry.Name -PropertyType ExpandString -Value $Entry.Value -Force | Out-Null }
    }
}

function Invoke-ForEachUserHive {
    <# Ajaa $Action jokaisen kayttajan rekisterille (HKU-juuri parametrina):
       kirjautuneet, kirjautumattomat (NTUSER.DAT ladataan hetkeksi) ja
       Default-profiili, jotta myos tulevat kayttajat saavat asetuksen. #>
    param([Parameter(Mandatory)][scriptblock]$Action)

    $targets = New-Object System.Collections.Generic.List[object]
    $profiles = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    foreach ($p in @(Get-ChildItem -LiteralPath $profiles -ErrorAction SilentlyContinue)) {
        if ($p.PSChildName -notmatch '^S-1-5-21-[\d-]+$') { continue }
        $dir = (Get-ItemProperty -LiteralPath $p.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
        $hive = if ($dir) { Join-Path $dir 'NTUSER.DAT' } else { '' }
        $targets.Add([pscustomobject]@{ Sid = $p.PSChildName; Hive = $hive })
    }
    $targets.Add([pscustomobject]@{ Sid = 'iRequireDefaultUser'; Hive = (Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT') })

    foreach ($t in $targets.ToArray()) {
        $root = 'Registry::HKEY_USERS\' + $t.Sid
        $loaded = $false
        if (-not (Test-Path -LiteralPath $root)) {
            if (-not $t.Hive -or -not (Test-Path -LiteralPath $t.Hive)) { continue }
            $r = Invoke-Native reg.exe @('load', ('HKU\' + $t.Sid), $t.Hive)
            if ($r.ExitCode -ne 0) { Write-IRequireLog ("Kayttajan {0} rekisteria ei voitu ladata" -f $t.Sid) 'Varoitus'; continue }
            $loaded = $true
        }
        try {
            & $Action $root
        } finally {
            if ($loaded) {
                [GC]::Collect()
                [GC]::WaitForPendingFinalizers()
                $r = Invoke-Native reg.exe @('unload', ('HKU\' + $t.Sid))
                if ($r.ExitCode -ne 0) { Write-IRequireLog ("Kayttajan {0} rekisteria ei voitu irrottaa: {1}" -f $t.Sid, ($r.Output -join ' ')) 'Varoitus' }
            }
        }
    }
}

function Invoke-Native {
    <# Ajaa ulkoisen ohjelman ja palauttaa tulosteen (stdout + stderr) ja
       paluukoodin. Suora '& ohjelma 2>&1' on PowerShell 5.1:ssa vaarallinen:
       kun ErrorActionPreference on Stop, jokainen stderr-rivi muuttuu
       kaatavaksi virheeksi (NativeCommandError), vaikka ohjelma onnistuisi.
       Esim. LGPO.exe kirjoittaa esittelytekstinsa stderriin. #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # stderr-rivi tulee ErrorRecordina, jonka TargetObject on itse rivi
        # (tyhja rivi nakyisi muuten tekstina 'RemoteException').
        $out = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                if ($_.TargetObject -is [string]) { $_.TargetObject } else { $_.Exception.Message }
            } else { "$_" }
        })
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $eap
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $out }
}

function Test-InternetConnection {
    <# Sama osoite jota Windowsin oma verkkotilan tunnistus (NCSI) kayttaa. #>
    try {
        $req = [System.Net.WebRequest]::Create('http://www.msftconnecttest.com/connecttest.txt')
        $req.Timeout = 5000
        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $text = $reader.ReadToEnd()
        $resp.Close()
        return ($text -eq 'Microsoft Connect Test')
    } catch {
        return $false
    }
}

function Wait-Internet {
    param([int]$Minutes = 10)
    $deadline = (Get-Date).AddMinutes($Minutes)
    do {
        if (Test-InternetConnection) { return $true }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} Tt' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N1} Gt' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} Mt' -f ($Bytes / 1MB)) }
    return ('{0:N0} t' -f $Bytes)
}
