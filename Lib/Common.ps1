# ==============================================================
#  Lib\Common.ps1 - iRequiren yhteiset apufunktiot
#
#  Ladataan seka WinPE:ssa etta asennetussa Windowsissa, joten tassa
#  saa kayttaa vain PowerShell 5.1:n perusominaisuuksia: WinPE:ssa ei
#  ole moduuleja eika .NET-kaantajaa.
# ==============================================================

$script:LogFile = $null

function Start-Log {
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:LogFile = $Path
    Write-Log ("==== {0} aloitettu ====" -f (Split-Path -Leaf $Path))
}

function Write-Log {
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
}

function Get-IRequireConfig {
    <# Lukee asetukset. Puuttuvat kentat taydennetaan oletuksilla, jotta
       vanhemmalla asetustiedostolla varustettu tikku toimii edelleen. #>
    param([Parameter(Mandatory)][string]$Path)

    $defaults = @{
        Kayttaja    = @{ Nimi = 'user'; Salasana = '' }
        Kone        = @{ Nimi = '*' }
        Alue        = @{ Kayttoliittyma = 'en-US'; Alue = 'fi-FI'; Nappaimisto = '040b:0000040b'; Aikavyohyke = 'FLE Standard Time' }
        Tyhjennys   = @{ LaskuriSekuntia = 15; Naytteita = 256; KaikkiSisaisetLevyt = $true; MinimikokoGt = 40 }
        Asennus     = @{ Tuoteavain = ''; AutomaattikirjautuminenPysyva = $false }
        Wlan        = @{ Ssid = ''; Salasana = '' }
        Paivitykset = @{ MaksimiKierrokset = 6; Ajurit = $true; VerkonOdotusMinuuttia = 10 }
        Sovellukset = @{ Firefox = $false }
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

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} Tt' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N1} Gt' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} Mt' -f ($Bytes / 1MB)) }
    return ('{0:N0} t' -f $Bytes)
}
