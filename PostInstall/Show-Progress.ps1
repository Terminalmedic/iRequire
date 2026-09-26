#requires -Version 5.1
<#
.SYNOPSIS
    Nayttaa kirjautuneelle kayttajalle, missa jalkiasennus on menossa.

.DESCRIPTION
    Pelkka nayttoikkuna: lukee tilatiedostoa ja lokia, ei muuta mitaan.
    Ikkunan voi sulkea milloin tahansa, jalkiasennus jatkuu taustalla.
#>
$base = Join-Path $env:SystemDrive 'iRequire'
$stateFile = Join-Path $base 'Logs\tila.json'
$logFile = Join-Path $base 'Logs\postinstall.log'
$Host.UI.RawUI.WindowTitle = 'iRequire - viimeistellaan asennusta'

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
            Write-Host ''
            Write-Host '  Valmis. Tama ikkuna sulkeutuu hetken kuluttua.' -ForegroundColor Green
            Start-Sleep -Seconds 20
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
