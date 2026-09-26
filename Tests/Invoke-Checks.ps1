#requires -Version 5.1
<#
.SYNOPSIS
    Kaikki paikalliset tarkistukset yhdella komennolla, samoin saannoin kuin CI.

.DESCRIPTION
    1. Tests\Test-iRequire.ps1
    2. PSScriptAnalyzer (samat poissuljetut saannot kuin CI:ssa)
    3. e2e-skriptin syntaksi (bash -n), jos bash on saatavilla

    CI (.github/workflows/ci.yml) ajaa taman saman skriptin, joten
    paikallinen ajo ja CI eivat voi erota toisistaan.

.PARAMETER RequireAnalyzer
    Epaonnistu, jos PSScriptAnalyzer puuttuu (CI). Muuten vain varoitus.
#>
[CmdletBinding()]
param([switch]$RequireAnalyzer)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failed = New-Object System.Collections.Generic.List[string]
. (Join-Path $root 'Lib\Common.ps1')   # Invoke-Native

# --- 1. Tarkistukset ---
# Nollaus ensin: testit ajavat itse ulkoisia ohjelmia (myos paluukoodilla 3),
# ja onnistunut ajo ei kutsu exit-komentoa.
$global:LASTEXITCODE = 0
& (Join-Path $PSScriptRoot 'Test-iRequire.ps1')
if ($LASTEXITCODE -ne 0) { $failed.Add('Test-iRequire.ps1') }

# --- 2. PSScriptAnalyzer ---
$excluded = @('PSAvoidUsingWriteHost', 'PSUseShouldProcessForStateChangingFunctions', 'PSUseSingularNouns',
              'PSAvoidUsingEmptyCatchBlock', 'PSReviewUnusedParameter')
if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
    Import-Module PSScriptAnalyzer
    Write-Host ''
    Write-Host '=== PSScriptAnalyzer ===' -ForegroundColor Cyan
    $results = @(Invoke-ScriptAnalyzer -Path $root -Recurse -ExcludeRule $excluded)
    if ($results.Count -gt 0) { $results | Format-Table -AutoSize | Out-String -Width 250 | Write-Host }
    $errors = @($results | Where-Object { "$($_.Severity)" -eq 'Error' })
    if ($errors.Count -gt 0) { $failed.Add("PSScriptAnalyzer: $($errors.Count) virhetason loydosta") }
    else { Write-Host ("  OK    ei virhetason loydoksia ({0} muuta)" -f $results.Count) -ForegroundColor Green }
} elseif ($RequireAnalyzer) {
    $failed.Add('PSScriptAnalyzer puuttuu')
} else {
    Write-Host '  VAROITUS PSScriptAnalyzer puuttuu: Install-Module PSScriptAnalyzer -Scope CurrentUser' -ForegroundColor Yellow
}

# --- 3. e2e-skriptin syntaksi ---
$bash = Get-Command bash -ErrorAction SilentlyContinue
if ($bash -and $env:OS -ne 'Windows_NT') {
    $r = Invoke-Native $bash.Source @('-n', (Join-Path $root 'Tests/e2e/run-e2e.sh'))
    if ($r.ExitCode -ne 0) { $failed.Add('run-e2e.sh: ' + ($r.Output -join ' ')) }
    else { Write-Host '  OK    run-e2e.sh jasentyy' -ForegroundColor Green }
}

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host ('EPAONNISTUI: ' + ($failed -join '; ')) -ForegroundColor Red
    exit 1
}
Write-Host 'Kaikki tarkistukset ja analyysi lapi.' -ForegroundColor Green
