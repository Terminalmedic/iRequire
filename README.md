# iRequire

Tikku, joka tyhjentää koneen levyt palautuskelvottomiksi, asentaa Windows 11:n (oletuksena IoT Enterprise LTSC 2024) ja viimeistelee sen ilman käyttäjää: päivitykset, ajurit, telemetria pois ja turhat sovellukset poistettu.

Käyttäjä tekee vain kaksi asiaa: käynnistää koneen tikulta ja halutessaan painaa Esc laskurin aikana, jos kone on väärä.

```
Tikku (WinPE)
 ├─ 1. Tikun eheys: jokaisen tiedoston SHA-256 (rikkinäinen kopio → pysähdys, levyihin ei kosketa)
 ├─ 2. Laskuri: levyt, sarjanumerot, osiot, löydetyt Windows-asennukset ja käyttäjät.
 │     Ulkoiset USB-levyt ja muistikortit näytetään "ei kosketa" -listalla. Esc peruu.
 ├─ 3. Akku: kannettava odottaa laturia ennen tuntien tyhjennystä
 ├─ 4. Tyhjennys: flash-levyt laitteen omalla tyhjennyksellä, HDD nollilla, varmistus lukemalla
 │     → tyhjennystodistus (.txt + .json)
 ├─ 5. Asennus: kuva puretaan DISMilla nopeimmalle levylle, ei kysymyksiä
 └─ 6. Lopputarkistus: käynnistystiedostot, vastaustiedosto ja jälkiasennus paikallaan → uudelleenkäynnistys
Windows
 ├─ 7. Ryhmäkäytännöt (LGPO → näkyvät gpeditissä), telemetriapalvelut ja -ajastukset pois
 ├─ 8. Turhat sovellukset ja ominaisuudet pois
 ├─ 9. Windows Update + ajurit, kierroksittain uudelleenkäynnistysten yli
 ├─ 10. Visual C++ -kirjastot (pelit), halutessa Firefox. Allekirjoitukset tarkistetaan.
 └─ 11. Yhteenveto: puuttuvat ajurit, näytönohjainsuositus, salasanat pois koneelta
```

## Ensimmäinen kerta: näin varmistat että se toimii

Levyn tyhjennys on peruuttamaton, joten ennen oikeaa konetta käy nämä vaiheet läpi järjestyksessä:

1. **Testit:** `.\Tests\Test-iRequire.ps1`. Kaikkien 30+ tarkistuksen pitää mennä läpi.
2. **Virtuaalikone:** `.\Build\New-iRequireIso.ps1` ja sitten `.\Tests\New-TestVm.ps1 -IsoPath .\Out\iRequire.iso`. Hyper-V-kone saa kaksi levyä täynnä testidataa. Anna ketjun ajaa loppuun ja tarkista `C:\iRequire\Reports`.
3. **Harjoitus oikealla koneella:** aseta tikulla `iRequire\Config\iRequire.json` → `"Harjoitus": true`. Tikku tekee kaiken muun (eheys, levyjen tunnistus, suora luku, kohdelevyn valinta), mutta ei kirjoita levyille mitään. Tulos on lokissa `iRequire\Reports`.
4. **Oikea ajo:** `"Harjoitus": false`.

## Mitä tarvitaan

- Windows 10/11 -kone rakentamista varten (järjestelmänvalvojana)
- [Windows ADK ja WinPE-lisäosa](https://learn.microsoft.com/windows-hardware/get-started/adk-install), sama versio kuin ISO (LTSC 2024 = 24H2 / 26100)
- Windows 11 -ISO (ks. [Versio ja lisenssi](#versio-ja-lisenssi))
- USB-tikku, vähintään 8 Gt

## Rakentaminen

```powershell
# 1. (valinnainen) Uusimmat päivitykset kuvaan: lataa kumulatiivinen päivitys
#    Microsoft Update Catalogista Build\Updates-kansioon (.msu). 24H2:ssa myös
#    sen vaatima checkpoint-päivitys. Nimijärjestys = asennusjärjestys.
# 2. (valinnainen) Ajurit kaikille koneille: Build\Drivers (.inf-kansiot)
#    WinPE:n tarvitsemat (esim. Intel RST/VMD): Build\Drivers\WinPE

.\Build\Build-iRequire.ps1 -IsoPath D:\ISO\windows.iso

# 3a. Tikulle
Get-Disk | Where-Object BusType -eq USB
.\Build\New-iRequireUsb.ps1 -DiskNumber 3

# 3b. tai ISOksi (virtuaalikoneet, Ventoy)
.\Build\New-iRequireIso.ps1
```

Tikun sisältö on tavallisia tiedostoja. Asetukset (`iRequire\Config\iRequire.json`) ja konekohtaiset ajurit (`iRequire\Drivers`) voi muokata suoraan tikulle ilman uudelleenrakennusta. Muita tiedostoja ei voi muokata, koska eheystarkistus hylkää muuttuneen tiedoston.

## Asetukset

`Config\iRequire.json`:

| Kohta | Mitä |
|---|---|
| `Kayttaja` | Paikallinen tili. Tyhjä salasana = suoraan työpöydälle. |
| `Alue` | Alue, näppäimistö ja aikavyöhyke (oletus Suomi). |
| `Tyhjennys.LaskuriSekuntia` | Esc-ikkunan pituus (oletus 15 s, vähintään 5). |
| `Tyhjennys.KaikkiSisaisetLevyt` | `true` = kaikki sisäiset levyt, `false` = vain asennuslevy. |
| `Tyhjennys.Harjoitus` | `true` = mitään ei kirjoiteta, vain tarkistetaan. |
| `Tyhjennys.TaysiVarmistus` | `true` = koko levy luetaan takaisin (kiintolevyllä kaksinkertainen aika). |
| `Tyhjennys.OdotaVerkkovirtaa` | Akulla oleva kannettava odottaa laturia. |
| `Wlan` | Jos koneessa ei ole kaapelia, päivitykset tarvitsevat tämän. |
| `Paivitykset` | Kierrosmäärä, ajurit, verkon odotusaika. |
| `Sovellukset` | Visual C++ (oletus päällä), Firefox (oletus pois). |

Poistettavat sovellukset, palvelut ja ajastukset ovat tiedostossa `Policies\Debloat.json`, ryhmäkäytännöt tiedostoissa `Policies\machine.txt` ja `Policies\user.txt` (LGPO:n tekstimuoto), ja uuden käyttäjän oletusasetukset tiedostossa `Policies\defaultuser.txt`.

## Mitä jätetään rauhaan

Windows Update, Defender, ääni, Bluetooth, WLAN, haku, Edge (seuranta pois käytännöillä), laskin, Notepad, Paint, Kuvat, Media Player, koodekit, Terminal ja winget. Mikrofonia ja kameraa ei estetä, joten puhelut toimivat. `Tests\Test-iRequire.ps1` tarkistaa, ettei poistolistaan eksy näitä.

Xbox ja Microsoft Store poistetaan. Xbox-ohjainten langaton sovitin (`XboxGipSvc`) lakkaa toimimasta. Jos tarvitset sitä, poista rivi `Debloat.json`-tiedostosta.

## Tyhjennys: mitä se oikeasti takaa

| Levy | Menetelmä | Taso |
|---|---|---|
| NVMe | Laitteen kryptografinen tyhjennys (`IOCTL_STORAGE_REINITIALIZE_MEDIA`) | NIST 800-88 Purge, jos laite tukee |
| SATA SSD, eMMC | Laitteen oma tyhjennys, jos ajuri tukee. Muuten nollat + TRIM koko levylle | Clear (paras mahdollinen ilman valmistajan työkalua) |
| HDD | Nollat koko levylle, yksi kierros | NIST 800-88 Clear, riittää kiintolevylle |
| Tuntematon (VM, RAID) | Nollat + TRIM | Clear |

**Varmistus.** Ennen tyhjennystä luetaan 256 satunnaista kohtaa (alku ja loppu aina mukana), ja tyhjennyksen jälkeen samat kohdat uudelleen. Laitteen omalle tyhjennykselle ei riitä, että se ilmoittaa onnistuneensa: jokaisen aiemmin dataa sisältäneen kohdan on oltava muuttunut. Muuten levy ylikirjoitetaan varalta.

**Hylkäys.** Levy hylätään, jos jokin kohta ei ole nollaa, sitä ei voi lukea tai jokin alue ei ota kirjoitusta vastaan (viallinen sektori). Hylätty levy estää asennuksen, ja todistukseen kirjataan syy ja ohje.

**Rajoitukset.**
- SATA SSD:n varaalueisiin ylikirjoitus ei yllä.
- Kiintolevyn HPA/DCO-piilotettuja alueita ei voi tyhjentää Windowsista.
- Viallisia sektoreita ei voi tyhjentää.

Jos levyllä on ollut jotain todella arkaluontoista eikä laitteen oma tyhjennys toiminut, käytä valmistajan työkalua tai tuhoa levy fyysisesti.

## Turvamekanismit

- **Laskuri** näyttää levyn mallin, sarjanumeron, osiot ja käytetyn tilan, löydetyt Windows-asennukset (versio ja koneen nimi) sekä käyttäjätilien nimet. Esc peruu, eikä levyihin kosketa.
- **Ulkoiset levyt** (USB, FireWire, muistikortit, verkkolevyt) ja tikku itse jätetään aina rauhaan, ja ne listataan ruudulla erikseen.
- **Tikun eheys** tarkistetaan ennen tyhjennystä. Vioittunut kopio pysäyttää ajon ennen kuin mitään on menetetty.
- **Uudelleentyhjennyksen esto:** jos kone käynnistyy asennuksen jälkeen vahingossa taas tikulta, tikku tunnistaa keskeneräisen asennuksen ja käynnistää kiintolevyltä.
- **Virheessä pysähdytään:** WinPE ei käynnisty uudelleen silmukkaan. Jälkiasennuksen tilakone yrittää vaihetta kahdesti, ohittaa sen sitten eikä voi jäädä uudelleenkäynnistyssilmukkaan (testattu simuloiduilla käynnistyksillä).
- **Salasanat:** `Windows\Panther\unattend.xml` poistetaan heti, asetustiedosto lukitaan vain järjestelmänvalvojille ja poistetaan lopuksi, ja automaattinen kirjautuminen poistetaan.
- **Kirjoitussuojattu tikku tai ISO:** raportit tallennetaan asennettavalle koneelle.

## Vianetsintä

| Oire | Syy ja korjaus |
|---|---|
| "Sisäisiä levyjä ei löytynyt" | Intel RST/VMD-ohjaimen ajuri puuttuu WinPE:stä. Lisää se kansioon `Build\Drivers\WinPE` ja rakenna uudelleen, tai vaihda BIOSista SATA-tilaksi AHCI. |
| Sisäinen levy näkyy listalla "Ei kosketa (irrotettava levy)" | SATA-portin hot-plug on päällä, joten Windows pitää levyä irrotettavana. iRequire ei tyhjennä irrotettavia levyjä, koska se voisi olla esimerkiksi varmuuskopiolevy. Kytke hot-plug pois BIOSista kyseiseltä portilta. |
| "Tikun tiedostot ovat vioittuneet" | Kirjoita tikku uudelleen, tai kokeile toista tikkua. |
| Levy hylätään, eikä sitä voi lukea eikä kirjoittaa | Laitteistosalattu, lukittu levy (Opal/eDrive). Palauta se valmistajan PSID-toiminnolla. |
| Secure Boot -virhe tikulta käynnistettäessä | Laiteohjelmisto on hylännyt vanhan varmenteen. Rakenna media uudemmasta ISOsta, tai kytke Secure Boot pois asennuksen ajaksi. |
| Ei verkkoa asennuksen jälkeen | WLAN-ajuri puuttuu. `yhteenveto.txt` listaa laitteen. Lisää ajuri tikun kansioon `iRequire\Drivers` tai käytä kaapelia. |

## Versio ja lisenssi

- **IoT Enterprise LTSC 2024** on oletus: gpedit, ei Storea, tuki vuoteen 2034 ja löysemmät laitteistovaatimukset (TPM 2.0 ei ole pakollinen). Telemetrian saa tasolle 0.
- `-Edition`-parametrilla voi valita muun version, esim. `-Edition '*Pro'`. Pro-versiossa telemetrian minimi on taso 1. Pro-kuvasta poistetaan lisäksi OneDriven ja uuden Outlookin automaattiasennus.
- iRequire ei aktivoi Windowsia. Aktivoimaton Windows toimii, mutta näyttää vesileiman eikä salli taustakuvan vaihtoa asetuksista.
- **Evaluation-ISO** (Microsoftin Evaluation Centeristä) vanhenee 90 päivässä. Sen jälkeen kone sammuu tunnin välein. Sitä ei voi aktivoida eikä muuttaa täysversioksi.

## Testaus

```powershell
.\Tests\Test-iRequire.ps1
```

Testit ajetaan jokaisella commitilla CI:ssä oikealla Windowsilla. Ne kattavat:

- **Tyhjennys päästä päähän:** levy korvataan testitiedostolla, jolle ajetaan HDD-ylikirjoitus, NVMe:n kryptografinen tyhjennys, "valehteleva" SSD, tukematon komento ja simuloitu viallinen sektori.
- **Tilakone:** simuloidut uudelleenkäynnistykset, virheet ja vioittunut tila.
- **Tikun eheys:** vioittunut, puuttuva ja muokattu tiedosto.
- **Levyjen luokittelu:** eMMC, muistikortit ja ulkoiset levyt.
- **Vastaustiedosto:** muodostus ja salasanan erikoismerkit.
- **Kirjoitusvirheet:** kutsu määrittelemättömään funktioon.
- **Asetukset:** tuntemattomat asetusavaimet.
- **Poistolista:** suojatut sovellukset ja palvelut eivät ole listalla.

Testit eivät voi ajaa WinPE:tä eivätkä koskea oikeisiin levyihin. Siksi [ensimmäinen kerta](#ensimmäinen-kerta-näin-varmistat-että-se-toimii) tehdään virtuaalikoneessa ja harjoitustilassa.

## Rakenne

```
Build/        ISOn muokkaus, tikun kirjoitus, ISO-levykuva
WinPE/        Tikulla ajettava vaihe: eheys, laskuri, tyhjennys, asennus
Unattend/     Vastaustiedoston pohja (OOBE ohitetaan)
PostInstall/  Asennetussa Windowsissa ajettava vaihe
Policies/     Ryhmäkäytännöt, oletuskäyttäjän asetukset, poistolista
Lib/          Yhteiset funktiot: loki, asetukset, eheys, tilakone
Config/       Asetukset
Tests/        Tarkistukset ja Hyper-V-testikone
```
