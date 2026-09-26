# iRequire - ohjeet koodin muokkaajalle

Tikku joka tyhjentaa koneen levyt ja asentaa viritetyn Windows 11 IoT Enterprise LTSC -pelikoneen ilman kayttajaa. Katso README.md kokonaiskuvaan.

## Ehdottomat saannot

- **Skriptit ovat ASCII-muotoisia.** Ei aakkosia (a/o kirjoitetaan ilman pisteita) .ps1/.cmd/.ini/.txt-tiedostoissa: WinPE:n konsoli ja PowerShell 5.1 ilman BOMia rikkovat ne. README.md saa sisaltaa aakkoset. Testi valvoo.
- **PowerShell 5.1.** Koodi ajetaan WinPE:ssa ja Windowsissa, joissa on vain Windows PowerShell 5.1. Ei PS7-syntaksia (`??`, `?.`, ternary, `-Parallel`).
- **WinPE:ssa ei ole C#-kaantajaa.** `Add-Type` ei toimi WinPE-koodissa (WinPE/). Win32-kutsut Reflection.Emitilla (ks. `Initialize-Native` WinPE/Disk.ps1). Asennetussa Windowsissa ajettava koodi (Lib/Display.ps1) saa kayttaa Add-Typea.
- **Levyihin ei kosketa ennen kuin kaikki on tarkistettu.** Uudet tarkistukset WinPE-vaiheeseen kuuluvat ennen laskuria. Kaikki mika voi epaonnistua, pysayttaa (`Stop-Here`) eika kaynnista uudelleen.
- **Tietoturvaa ei heikenneta suorituskyvyn vuoksi.** Defender, palomuuri, UAC, SmartScreen, VBS/HVCI, Secure Boot, paivitykset ja haavoittuvien ajurien estolista pysyvat paalla. Testi 'Tietoturva: suojaus ei heikkene' valvoo.
- **Viritykset vain mitatulla hyodylla.** README:n taulukko "Ammattilaisoptimoijien saadot" kertoo mita on hylatty ja miksi. Plaseboja ei lisata.
- **Uudet asetukset** lisataan seka `Config/iRequire.json`:iin (kuvauksen kanssa, `_Avain`) etta `Get-IRequireConfig`-oletuksiin (Lib/Common.ps1). Testi huomaa tuntemattomat avaimet.

## Rakenne

- `WinPE/` tikulla: Start-iRequire (paaohjelma), Disk (tyhjennys), Deploy (asennus), Bootstrap (boot.wim:ssa)
- `PostInstall/` asennetussa Windowsissa: Invoke-PostInstall (SYSTEM, tilakone), Show-Progress (kayttaja)
- `Lib/` yhteiset: Common, Media (eheys), Stages (tilakone), Tuning, Readiness, Display
- `Policies/` LGPO-tekstimuoto (4 rivia/tietue) + Debloat.json
- `Build/` rakennus (vaatii Windows ADK + WinPE)

Puhdas paatoslogiikka erotetaan Windows-kutsuista (`Get-*Choice`, `Select-*`, `Get-GamingFindings`, `Test-WipeResult`, `Invoke-StageMachine`), jotta sen voi testata kaikkialla.

## Testaus

```powershell
.\Tests\Test-iRequire.ps1      # ~50 tarkistusta, toimii myos pwsh:lla Linuxissa
```

- CI (`.github/workflows/ci.yml`): Test-iRequire.ps1 + PSScriptAnalyzer Windows PowerShell 5.1:lla, mukana vain lukevat Windows-integraatiotestit.
- Rakennus (`build.yml`): koko Build-iRequire.ps1 oikealla ISOlla, Test-BuildOutput.ps1 tarkistaa median, sitten paasta paahan -testi QEMU/KVM:ssa (`Tests/e2e/run-e2e.sh`).
- Uusi toiminto = uusi testi. Varmista etta testi kaatuu kun koodi rikotaan (mutaatio), ei vain etta se menee lapi.
