#requires -Version 5.1
<#
.SYNOPSIS
    Nayttaa kirjautuneelle kayttajalle, missa jalkiasennus on menossa.

.DESCRIPTION
    Nayttaa tilan, asettaa naytot suurimmalle taajuudelle ja lopuksi
    asentaa valitut kayttajakohtaiset sovellukset (Discord, Spotify),
    joita SYSTEM ei voi asentaa kayttajalle. Kirjoittaa vain Kayttaja-
    kansioon. Ikkunan voi sulkea milloin tahansa, jalkiasennus jatkuu.
#>
$base = Join-Path $env:SystemDrive 'iRequire'
$stateFile = Join-Path $base 'Logs\tila.json'
$logFile = Join-Path $base 'Logs\postinstall.log'
# Kayttajan istunto kirjoittaa vain Kayttaja-kansioon: muu C:\iRequire on
# kayttajille vain luku, koska SYSTEM ajaa sielta skripteja.
$userDir = Join-Path $base 'Kayttaja'
$marker = Join-Path $userDir 'naytto-valmis.txt'
$Host.UI.RawUI.WindowTitle = 'iRequire - viimeistellaan asennusta'

# Jo tehty: ei ikkunaa, ei muutoksia. Kayttaja saa valita taajuutensa itse.
if (Test-Path -LiteralPath $marker) { exit 0 }

. (Join-Path $base 'Lib\Common.ps1')
. (Join-Path $base 'Lib\Display.ps1')

function Install-UserApps {
    <# Discord, Spotify ym. asentuvat vain kayttajalle, joten ne asennetaan
       taalla (kayttajan istunto, ei jarjestelmanvalvojan oikeuksia). #>
    $sel = $null
    try { $sel = Get-Content -LiteralPath (Join-Path $userDir 'kayttajasovellukset.json') -Raw -ErrorAction Stop | ConvertFrom-Json } catch { return }
    Start-Log -Path (Join-Path $userDir 'kayttaja.log')
    foreach ($a in (Get-UserApps -Selection $sel)) {
        $parts = $a.Check -split '\\', 2
        $installed = Join-Path ([Environment]::GetEnvironmentVariable($parts[0])) $parts[1]
        if (Test-Path -LiteralPath $installed) { continue }
        Write-Host ('  Asennetaan {0}...' -f $a.Name) -ForegroundColor Gray
        try {
            Install-SignedInstaller -Url $a.Url -Publisher $a.Publisher -Arguments $a.Arguments -Name $a.Name
        } catch { Write-IRequireLog $_.Exception.Message 'Varoitus' }
    }
}

function Invoke-DisplayTuning {
    <# Naytot suurimmalle taajuudelle. Ajetaan jokaisella kirjautumisella
       asennuksen aikana, koska naytonohjaimen ajuri tulee vasta paivityksista. #>
    try {
        $rows = Set-MaxRefreshRate
        $lines = @($rows | ForEach-Object { '{0}: {1}, {2} Hz -> {3} Hz ({4})' -f $_.Naytto, $_.Tarkkuus, $_.EnnenHz, $_.JalkeenHz, $_.Tulos })
        $lines | ForEach-Object { Add-Content -LiteralPath (Join-Path $userDir 'naytto.log') -Value ((Get-Date -Format s) + ' ' + $_) -ErrorAction SilentlyContinue }
        return $lines
    } catch {
        Add-Content -LiteralPath (Join-Path $userDir 'naytto.log') -Value ((Get-Date -Format s) + ' virhe: ' + $_.Exception.Message) -ErrorAction SilentlyContinue
        return @()
    }
}

[void](Invoke-DisplayTuning)

while ($true) {
    $state = $null
    try { $state = Get-Content -LiteralPath $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { }

    Clear-Host
    Write-Host ''
    Write-Host '  iRequire viimeistelee asennusta' -ForegroundColor Cyan
    Write-Host '  Konetta voi kayttaa, mutta se kaynnistyy itsestaan uudelleen paivitysten valissa.' -ForegroundColor DarkGray
    Write-Host ''
    if ($state) {
        Write-Host ('  Vaihe: {0}' -f $state.Vaihe) -ForegroundColor White
        Write-Host ('  {0}' -f $state.Viesti) -ForegroundColor Gray
        if ($state.Valmis) {
            # Viimeinen kerta: ajurit ovat nyt paikallaan.
            $lines = Invoke-DisplayTuning
            Install-UserApps
            Write-Host ''
            foreach ($l in $lines) { Write-Host ('  Naytto ' + $l) -ForegroundColor Gray }
            Set-Content -LiteralPath $marker -Value ((Get-Date -Format s) + [Environment]::NewLine + ($lines -join [Environment]::NewLine)) -ErrorAction SilentlyContinue
            Write-Host ''
            Write-Host '  Valmis. Yhteenveto: C:\iRequire\Reports\yhteenveto.txt' -ForegroundColor Green
            Write-Host '  Tama ikkuna sulkeutuu hetken kuluttua.' -ForegroundColor Green
            Start-Sleep -Seconds 30
            exit 0
        }
    } else {
        Write-Host '  Odotetaan jalkiasennuksen kaynnistymista...' -ForegroundColor Gray
    }
    Write-Host ''
    if (Test-Path -LiteralPath $logFile) {
        Get-Content -LiteralPath $logFile -Tail 15 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor DarkGray }
    }
    Start-Sleep -Seconds 3
}
