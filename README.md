# iRequire

Tikku, joka tyhjentää koneen levyt palautuskelvottomiksi, asentaa Windows 11:n (oletuksena IoT Enterprise LTSC 2024) ja viimeistelee sen ilman käyttäjää: päivitykset, ajurit, telemetria pois ja turhat sovellukset poistettu.

Käyttäjä tekee vain kaksi asiaa: käynnistää koneen tikulta ja halutessaan painaa Esc laskurin aikana, jos kone on väärä.

```
Tikku (WinPE)
 ├─ 1. Laskuri: levyt, sarjanumerot, osiot, löytyneet Windows-asennukset ja käyttäjät. Esc peruu.
 ├─ 2. Tyhjennys: SSD/NVMe laitteen omalla tyhjennyksellä, HDD nollilla. Varmistus lukemalla.
 │     Tyhjennystodistus (.txt + .json) tikulle.
 ├─ 3. Asennus: kuva puretaan DISMilla nopeimmalle levylle, ei kysymyksiä.
 └─ Uudelleenkäynnistys → Windows
     ├─ 4. Ryhmäkäytännöt (LGPO → näkyvät gpeditissä), telemetriapalvelut pois
     ├─ 5. Turhat sovellukset ja ominaisuudet pois
     ├─ 6. Windows Update + ajurit, uudelleenkäynnistykset itsestään
     └─ 7. Yhteenveto: puuttuvat ajurit, päivitykset → koneelle ja tikulle
```

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

# 3. Tikulle
Get-Disk | Where-Object BusType -eq USB
.\Build\New-iRequireUsb.ps1 -DiskNumber 3
```

Tikun sisältö on tavallisia tiedostoja: `iRequire\Config\iRequire.json`, skriptit ja konekohtaiset ajurit (`iRequire\Drivers`) voi muokata suoraan tikulle ilman uudelleenrakennusta.

## Asetukset

`Config\iRequire.json`:

| Kohta | Mitä |
|---|---|
| `Kayttaja` | Paikallinen tili. Tyhjä salasana = suoraan työpöydälle. |
| `Alue` | Alue, näppäimistö ja aikavyöhyke (oletus Suomi). |
| `Tyhjennys.LaskuriSekuntia` | Esc-ikkunan pituus (oletus 15 s). |
| `Tyhjennys.KaikkiSisaisetLevyt` | `true` = kaikki sisäiset levyt, `false` = vain asennuslevy. |
| `Wlan` | Jos koneessa ei ole kaapelia, päivitykset tarvitsevat tämän. |
| `Paivitykset` | Kierrosmäärä, ajurit, verkon odotusaika. |
| `Sovellukset.Firefox` | Firefox suoraan Mozillalta (allekirjoitus tarkistetaan). |

Poistettavat sovellukset, palvelut ja ajastukset ovat tiedostossa `Policies\Debloat.json`, ryhmäkäytännöt tiedostoissa `Policies\machine.txt` ja `Policies\user.txt` (LGPO:n tekstimuoto), ja uuden käyttäjän oletusasetukset tiedostossa `Policies\defaultuser.txt`.

## Mitä jätetään rauhaan

Windows Update, Defender, ääni, Bluetooth, WLAN, haku, Edge (seuranta pois käytännöillä), laskin, Notepad, Paint, Kuvat, Media Player, koodekit, Terminal ja winget. `Tests\Test-iRequire.ps1` tarkistaa, ettei poistolistaan eksy näitä.

Xbox ja Microsoft Store poistetaan. Xbox-ohjainten langaton sovitin (`XboxGipSvc`) lakkaa toimimasta. Jos tarvitset sitä, poista rivi `Debloat.json`-tiedostosta.

## Tyhjennys: mitä se oikeasti takaa

| Levy | Menetelmä | Taso |
|---|---|---|
| NVMe | Laitteen kryptografinen tyhjennys (`IOCTL_STORAGE_REINITIALIZE_MEDIA`) | NIST 800-88 Purge, jos laite tukee |
| SATA SSD | Laitteen oma tyhjennys, jos ajuri tukee. Muuten nollat + TRIM koko levylle | Clear (paras mahdollinen ilman valmistajan työkalua) |
| HDD | Nollat koko levylle, yksi kierros | NIST 800-88 Clear, riittää kiintolevylle |

Jokainen levy varmistetaan: ennen tyhjennystä luetaan 256 satunnaista kohtaa ja tyhjennyksen jälkeen samat kohdat uudelleen. Jos varmistus epäonnistuu, asennus ei ala.

SATA SSD:n varaalueisiin ylikirjoitus ei yllä. Jos levyllä on ollut jotain todella arkaluontoista eikä laitteen oma tyhjennys toiminut, käytä valmistajan työkalua tai tuhoa levy fyysisesti.

## Turvamekanismit

- **Laskuri** näyttää levyn mallin, sarjanumeron, osiot, löydetyt Windows-asennukset (versio ja koneen nimi) sekä käyttäjätilien nimet. Esc peruu, eikä levyihin kosketa.
- **Tikku ja USB-levyt** jätetään aina pois.
- **Uudelleentyhjennyksen esto:** jos kone käynnistyy asennuksen jälkeen vahingossa taas tikulta, tikku tunnistaa keskeneräisen asennuksen ja käynnistää kiintolevyltä. Merkki poistetaan, kun jälkiasennus on valmis.
- **Virheessä pysähdytään:** kone ei käynnisty uudelleen silmukkaan, ja loki jää tikulle (`iRequire\Reports`).
- Selväkielinen salasana poistetaan `Windows\Panther`-kansiosta heti ensimmäisessä vaiheessa.

## Versio ja lisenssi

- **IoT Enterprise LTSC 2024** on oletus: gpedit, ei Storea, tuki vuoteen 2034 ja löysemmät laitteistovaatimukset (TPM 2.0 ei ole pakollinen). Telemetrian saa tasolle 0.
- `-Edition`-parametrilla voi valita muun version, esim. `-Edition '*Pro'`. Pro-versiossa telemetrian minimi on taso 1.
- iRequire ei aktivoi Windowsia. Aktivoimaton Windows toimii, mutta näyttää vesileiman eikä salli taustakuvan vaihtoa asetuksista.
- **Evaluation-ISO** (Microsoftin Evaluation Centeristä) vanhenee 90 päivässä. Sen jälkeen kone sammuu tunnin välein. Sitä ei voi aktivoida eikä muuttaa täysversioksi.

## Testaus

```powershell
.\Tests\Test-iRequire.ps1
```

Testit tarkistavat kaiken, minkä voi tarkistaa ilman oikeaa konetta: jäsennyksen, asetukset, käytäntötiedostot, vastaustiedoston muodostuksen ja tyhjennyksen varmistuslogiikan.

**Aja ensimmäinen kierros virtuaalikoneessa** (Hyper-V tai VirtualBox, virtuaalilevy ja USB-tikku läpivietynä tai ISO), ennen kuin tikkua käytetään oikealla koneella.

## Rakenne

```
Build/        ISOn muokkaus ja tikun kirjoitus (ajetaan rakennuskoneella)
WinPE/        Tikulla ajettava vaihe: laskuri, tyhjennys, asennus
Unattend/     Vastaustiedoston pohja (OOBE ohitetaan)
PostInstall/  Asennetussa Windowsissa ajettava vaihe
Policies/     Ryhmäkäytännöt, oletuskäyttäjän asetukset, poistolista
Lib/          Yhteiset funktiot
Config/       Asetukset
Tests/        Tarkistukset
```
