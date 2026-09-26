# ==============================================================
#  Lib\Stages.ps1 - jalkiasennuksen tilakone
#
#  Erillaan varsinaisista vaiheista, jotta sen voi testata: virhe
#  tassa tarkoittaisi pahimmillaan loputonta uudelleenkaynnistysta.
#
#  Saannot:
#   - Tila tallennetaan jokaisen vaiheen jalkeen.
#   - Vaihe voi pyytaa uudelleenkaynnistysta palauttamalla olion,
#     jolla on Reboot = $true ja Reason. Vaihe ajetaan silloin
#     uudelleen kaynnistyksen jalkeen (esim. seuraava paivityskierros).
#   - Virheen jalkeen vaihe yritetaan uudelleen. $MaxErrors virheen
#     jalkeen se ohitetaan. Jos viimeinen vaihe ohitetaan, kone ei
#     kaynnisty enaa uudelleen - silmukka on mahdoton.
#   - Tuntematon vaihe tilatiedostossa (vioittunut) aloittaa alusta.
# ==============================================================

function New-StageState {
    param([Parameter(Mandatory)][string[]]$Stages, $Existing)
    $s = if ($Existing) { $Existing } else { [pscustomobject]@{} }
    $defaults = [ordered]@{ Vaihe = $Stages[0]; Kierros = 0; Valmis = $false; Viesti = ''; Paivityksia = 0; Virheita = 0 }
    foreach ($k in $defaults.Keys) {
        if ($s.PSObject.Properties.Name -notcontains $k) { $s | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] }
    }
    return $s
}

function New-RebootRequest {
    param([Parameter(Mandatory)][string]$Reason)
    return [pscustomobject]@{ Reboot = $true; Reason = $Reason }
}

function Invoke-StageMachine {
    <# Palauttaa olion: Result = Done | Reboot | Abandoned, Reason. #>
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string[]]$Stages,
        [Parameter(Mandatory)][hashtable]$Handlers,
        [Parameter(Mandatory)][scriptblock]$Save,
        [int]$MaxErrors = 2
    )
    if ($State.Valmis) { return [pscustomobject]@{ Result = 'Done'; Reason = 'jo valmis' } }

    $start = [Array]::IndexOf($Stages, [string]$State.Vaihe)
    if ($start -lt 0) {
        Write-IRequireLog ("Tuntematon vaihe '{0}' tilatiedostossa, aloitetaan alusta" -f $State.Vaihe) 'Varoitus'
        $start = 0
        $State.Kierros = 0
    }

    for ($i = $start; $i -lt $Stages.Count; $i++) {
        $name = $Stages[$i]
        $State.Vaihe = $name
        & $Save $State
        try {
            $out = @(& $Handlers[$name] $State)
        } catch {
            Write-IRequireLog ("VIRHE vaiheessa {0}: {1}" -f $name, $_.Exception.Message) 'Virhe'
            Write-IRequireLog ($_.ScriptStackTrace) 'Virhe'
            $State.Virheita++
            if ($State.Virheita -lt $MaxErrors) {
                & $Save $State
                return [pscustomobject]@{ Result = 'Reboot'; Reason = "virhe vaiheessa $name, yritetaan uudelleen" }
            }
            Write-IRequireLog ("Vaihe {0} ohitetaan {1} virheen jalkeen" -f $name, $State.Virheita) 'Varoitus'
            $State.Virheita = 0
            if ($i + 1 -ge $Stages.Count) {
                $State.Valmis = $true
                $State.Viesti = "Valmis, mutta vaihe $name epaonnistui (katso loki)"
                & $Save $State
                return [pscustomobject]@{ Result = 'Abandoned'; Reason = "vaihe $name epaonnistui" }
            }
            $State.Vaihe = $Stages[$i + 1]
            $State.Kierros = 0
            & $Save $State
            return [pscustomobject]@{ Result = 'Reboot'; Reason = "vaihe $name ohitettu virheen vuoksi" }
        }

        $reboot = @($out | Where-Object { $_ -and $_.PSObject.Properties.Name -contains 'Reboot' -and $_.Reboot }) | Select-Object -First 1
        if ($reboot) {
            $State.Virheita = 0
            & $Save $State
            return [pscustomobject]@{ Result = 'Reboot'; Reason = [string]$reboot.Reason }
        }

        $State.Virheita = 0
        $State.Kierros = 0
        if ($i + 1 -lt $Stages.Count) { $State.Vaihe = $Stages[$i + 1] }
        & $Save $State
    }

    $State.Valmis = $true
    $State.Viesti = 'Valmis'
    & $Save $State
    return [pscustomobject]@{ Result = 'Done'; Reason = 'kaikki vaiheet tehty' }
}
