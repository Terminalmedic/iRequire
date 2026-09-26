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
 ├─ 9. Pelikoneen viritys: virrankäyttö, GPU-ajoitus, Game Mode, tietoturva (ks. alla)
 ├─ 10. Windows Update + ajurit, kierroksittain uudelleenkäynnistysten yli
 ├─ 11. Visual C++ ja DirectX-kirjastot, halutessa Firefox. Allekirjoitukset tarkistetaan.
 ├─ 12. Yhteenveto: pelikuntoraportti (XMP, dual channel, näyttökaapeli ...), tietoturvan tila
 └─ 13. Kirjautuessa: näytöt suurimmalle virkistystaajuudelle
```

## Ensimmäinen kerta: näin varmistat että se toimii

Levyn tyhjennys on peruuttamaton, joten ennen oikeaa konetta käy nämä vaiheet läpi järjestyksessä:

0. **Esitarkistus kohdekoneella** (jos siinä on vielä toimiva Windows): aja järjestelmänvalvojana tikulta `iRequire\Tools\Test-TargetMachine.ps1`. Se ei muuta konetta, ja kertoo:
   - kumpi Secure Boot -varmenne tikulle tarvitaan (ks. alla)
   - tarvitseeko levyohjain valmistajan ajurin (Intel RST/VMD). `-ExportDrivers` vie sen suoraan tikulle.
   - TPM, Secure Boot, RAM, näytöt ja levyt, jotka tyhjennettäisiin
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

### Secure Boot -varmenne: 2011 vai 2023

Microsoft vaihtaa Secure Bootin varmenteita (vanhat vanhenevat 2026) ja mitätöi vanhoja käynnistyksenhallintoja BlackLotus-haavoittuvuuden vuoksi ([KB5025885](https://support.microsoft.com/topic/41a975df-beb2-40c1-99a3-b3ff139f832d)). Tikku voidaan rakentaa kummalla tahansa:

| | `-SecureBootCA 2011` (oletus) | `-SecureBootCA 2023` |
|---|---|---|
| Useimmat koneet | käynnistyy | käynnistyy, jos laiteohjelmisto on päivitetty luottamaan 2023-varmenteeseen |
| Kone, jossa vanhat on mitätöity | **ei käynnisty** ("Secure Boot violation") | käynnistyy |

Jos tikku ei käynnisty ja näyttää Secure Boot -virheen, rakenna se uudelleen parametrilla `-SecureBootCA 2023`. Asennettu Windows saa aina uusimman käynnistyksenhallinnan, johon kone luottaa (`bcdboot /bootex`), joten tämä valinta koskee vain tikkua.

Tikun sisältö on tavallisia tiedostoja. Asetukset (`iRequire\Config\iRequire.json`) ja konekohtaiset ajurit (`iRequire\Drivers`, myös WinPE:n tallennusohjainajurit) voi muokata suoraan tikulle ilman uudelleenrakennusta. Muita tiedostoja ei voi muokata, koska eheystarkistus hylkää muuttuneen tiedoston.

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
| `Sovellukset` | Visual C++ ja DirectX-lisäkirjastot (oletus päällä), Firefox (oletus pois). |
| `Suorituskyky` | Virrankäyttö, GPU-ajoitus, ikkunoidut pelit, horrostila, aktiiviset tunnit. |
| `Tietoturva.BitLocker` | `true` = C: salataan, palautusavain tikulle (ei salausta ilman tikkua). |

Poistettavat sovellukset, palvelut ja ajastukset ovat tiedostossa `Policies\Debloat.json`, ryhmäkäytännöt tiedostoissa `Policies\machine.txt` ja `Policies\user.txt` (LGPO:n tekstimuoto), ja uuden käyttäjän oletusasetukset tiedostossa `Policies\defaultuser.txt`.

## Pelialusta: mitä viritetään ja miksi

Periaate: vain muutoksia, joiden hyöty on mitattu tai Microsoftin dokumentoima. Tietoturvaa ei vaihdeta muutamaan ruudunpäivitykseen.

| Muutos | Miksi |
|---|---|
| **Virrankäyttö**: pöytäkone Ultimate Performance, kannettava Balanced + paras suorituskyky laturissa | Ei kellotaajuuden laskua kesken pelin. Kannettavassa Ultimate vain kuumentaisi. |
| **Laitteistokiihdytetty GPU-ajoitus (HAGS)** | Vaaditaan DLSS Frame Generationiin, pienentää viivettä. |
| **Ikkunoitujen pelien optimoinnit** | DX10/11-pelit ikkunassa flip-mallilla: pienempi viive, VRR/G-Sync toimii ikkunassa. |
| **Game Mode** | Windows antaa pelille etusijan ja lykkää päivitysten asennuksen. |
| **Game DVR / taustatallennus pois** | Taustalla pyörivä videotallennus vie GPU-aikaa. |
| **Hiiren kiihdytys pois** | Tähtäys on lineaarinen ja toistettava. |
| **Horrostila pois pöytäkoneelta** | Vapauttaa RAM-muistin kokoisen tiedoston levyltä. |
| **Käynnistysviive pois** | Windows ei enää pidättele käynnistysohjelmia 10 sekuntia. |
| **Aktiiviset tunnit 8–02** | Windows Update ei käynnistä konetta uudelleen illalla. |
| **Defenderin ajastettu tarkistus matalalla prioriteetilla** | Suojaus on ennallaan, eikä taustatarkistus vie ruutuja. |
| **Toimitusoptimointi pois** | Kone ei jaa päivityksiä muille koneille internetissä, joten lähetyskaista ei kulu. |
| **Telemetria, mainokset, Copilot, Widgets, Store, Xbox pois** | Vähemmän taustaprosesseja ja verkkoliikennettä. |
| **.NET 3.5** (kuvassa valmiina), **Visual C++**, **DirectX 9–11 -lisäkirjastot** | Vanhemmat pelit ja niiden asennusohjelmat toimivat heti. |
| **Näytöt suurimmalle virkistystaajuudelle** | Yleisin pelikoneen virhe on 144/165/240 Hz:n näyttö 60 Hz:llä. Taajuus nostetaan näytön itse ilmoittamaan suurimpaan taajuuteen, ja tila testataan ensin. Asetus tehdään vain asennuksen aikana, sen jälkeen käyttäjä päättää itse. |
| **Laitteiden virransäästö pois** (pöytäkone) | USB-hiiri, näppäimistö ja verkkokortti eivät nukahda, joten niistä ei tule viivepiikkejä. |
| **Pakotetut ajastinasetukset pois** (`useplatformclock` ym.) | Microsoft dokumentoi ne vain vianetsintään. Pakotettu HPET hidastaa ajastinkutsuja moninkertaisesti ja on mitattu heikentävän FPS:ää. |

**Tietoturva pysyy päällä:** Defender, palomuuri, SmartScreen, UAC, Secure Boot ja muistin eheys (HVCI), jos laite tukee. Lisäksi:
- Defenderin PUA-esto
- LLMNR pois (salasanojen kalastus lähiverkossa)
- AutoRun pois (USB-haittaohjelmat)
- SMB1 pois
- Etätuki pois
- Haavoittuvien ajurien estolista pakotettu päälle
- Microsoftin "Standard protection" -ASR-säännöt: haavoittuvien ajurien väärinkäyttö, tunnusten varkaus lsassista ja WMI-pysyvyys estetty
- Automaattinen laitesalaus estetty, koska sen avain katoaisi paikallisella tilillä. BitLocker on valittavissa asetuksella `Tietoturva.BitLocker`, jolloin avain tallennetaan tikulle.

Testit estävät, ettei mikään näistä kytkeydy vahingossa pois.

### Pelikuntoraportti

Suurimmat suorituskykyerot tulevat laitteistosta ja BIOSista, joita mikään Windows-säätö ei korvaa. `yhteenveto.txt` kertoo lopuksi:

- **[TOIMI] RAM perusnopeudella:** XMP tai EXPO on pois päältä. Prosessorisidonnaisissa peleissä tämä on usein kymmenien prosenttien ero, ja korjaus on yksi BIOS-asetus.
- **[TOIMI] Yksi muistikampa:** muisti toimii yksikanavaisena, jolloin muistikaista on puolet pienempi.
- **[TOIMI] Näyttö kytketty emolevyyn:** pelit pyörivät integroidulla grafiikalla, vaikka koneessa on erillinen näytönohjain.
- **[TOIMI] Ei näytönohjaimen ajuria,** tai **Windows kiintolevyllä.**
- **[HUOMIO]** Näyttö ei toimi suurimmalla taajuudellaan, esimerkiksi HDMI 1.4 -kaapelin takia.
- **Tietoturvan tila:** Defender, palomuuri, HVCI, Secure Boot ja BitLocker.

### Ammattilaisoptimoijien säädöt: mitä testit sanovat

Lähteinä on käytetty mittauksiin perustuvia oppaita ([valleyofdoom/PC-Tuning](https://github.com/valleyofdoom/PC-Tuning), [djdallmann/GamingPCSetup](https://github.com/djdallmann/GamingPCSetup)), Microsoftin dokumentaatiota ja riippumattomia testejä.

| Säätö | Päätös | Miksi |
|---|---|---|
| Suurin virkistystaajuus | ✅ tehdään | Suurin näkyvä parannus: pienempi viive ja sulavampi kuva. |
| XMP/EXPO, dual channel | 📋 tarkistetaan | Mitattu suureksi, mutta vain BIOSista korjattavissa. |
| Game Mode, HAGS, flip model | ✅ tehdään | Microsoftin dokumentoimat. Game Mode estää Windows Updaten pelin aikana. |
| Laitteiden virransäästö pois | ✅ pöytäkoneessa | Poistaa laitteiden heräämisviiveet. Kannettavassa kuluttaisi akkua. |
| Game DVR pois, hiiren kiihdytys pois | ✅ tehdään | Taustatallennus vie GPU-aikaa. Lineaarinen tähtäys. |
| NetBIOS pois | ✅ tehdään | Turha kuunteleva palvelu, joka on myös hyökkäyspinta. |
| HPET / `useplatformclock` / `disabledynamictick` | ❌ poistetaan jos asetettu | Microsoft: vain vianetsintään. Pakotettu HPET on mitattu hidastavan. |
| Ajastimen tarkkuus (`GlobalTimerResolutionRequests`) | ❌ ei | Windows 11 antaa tarkkuuden pelille itselleen. Globaali tarkkuus lisää kaikkien taustaprosessien kuormaa. |
| CPU:n lepotilojen (C-state) poisto | ❌ ei | Lämpenee ja estää turbon nousun. Haitallinen, ellei kellotaajuutta ole lukittu. |
| Sivutustiedoston poisto | ❌ ei | Aiheuttaa nykimistä osassa peleistä, vaikka muistia olisi vapaana. |
| Spectre/Meltdown-suojausten poisto | ❌ ei | Uusilla prosessoreilla ei hyötyä tai jopa hidastaa, ja avaa aukot. |
| Muistin eheyden (HVCI/VBS) poisto | ❌ ei | Muutaman prosentin hyöty CPU-sidonnaisissa peleissä ei ole ytimen suojauksen arvoinen. |
| MSI-tilan pakotus | ❌ ei automaattisesti | Ajurit asettavat sen jo tukevilla laitteilla. Pakotus tukemattomalle laitteelle aiheuttaa sinisen ruudun. |
| USB-keskeytysten (XHCI IMOD) säätö | ❌ ei | Vaatii haavoittuvien ajurien estolistan poiston, ja osa anti-cheat-järjestelmistä estää pelin. |
| Nagle, "network throttling", `Win32PrioritySeparation`, ydinten "vapautus" | ❌ ei | Ei mitattua hyötyä nykyisissä Windows-versioissa ja peleissä, joten ne ovat plaseboa. |
| "Standby list cleaner" | ❌ ei | Korjasi Windows 10 1803:n bugin, jota ei enää ole. |

**Mitä kannattaa tehdä itse** (pelikohtaista, ei automatisoitavissa):
- **NVIDIA Reflex** tai **AMD Anti-Lag** pelin asetuksista, jos peli tukee sitä.
- **Ruudunpäivitysraja** hieman näytön taajuuden alle, esimerkiksi 141 FPS 144 Hz:llä, jos käytössä on G-Sync tai FreeSync.
- **Hiiren raportointitaajuus** 1000 Hz tai enemmän.

**Mitä ei tehdä, tarkoituksella:**
- **HPET- tai ajastinsäädöt, Nagle-, "network throttling"- ja ydinten "vapautus" -säädöt:** plaseboa tai haitallisia nykyisillä Windows-versioilla.
- **Muistin eheyden (HVCI) poisto:** voisi antaa muutaman prosentin prosessorisidonnaisissa peleissä, mutta avaisi ytimen ajurihyökkäyksille.
- **Defenderin poikkeukset pelikansioille:** juuri ladatut pelimodit ja huijausohjelmat ovat yleinen haittaohjelmareitti.
- **Näytönohjaimen ajuria ei asenneta valmistajalta automaattisesti,** koska lataukset eivät ole vakaita. Windows Update asentaa toimivan ajurin, ja yhteenveto kertoo mistä uusin löytyy.

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

**Varmistus.** Levyltä valitaan 256 satunnaista kohtaa (alku ja loppu aina mukana), ja jokaiseen kirjoitetaan ennen tyhjennystä oma satunnainen **kanarialintu**. Tyhjennyksen jälkeen samat kohdat luetaan uudelleen:
- **Ylikirjoitus:** jokaisessa kohdassa on oltava nollaa.
- **Laitteen oma tyhjennys:** jokaisen kanarialinnun on kadottava. Laitteelle ei riitä, että se ilmoittaa onnistuneensa. Kanarialintujen ansiosta tämä ei riipu siitä, sattuvatko satunnaiset kohdat osumaan levyllä jo olevaan dataan. Ilman niitä lähes tyhjällä levyllä valehteleva laite menisi läpi sattumalta. Jos yksikin kanarialintu jää, levy ylikirjoitetaan varalta.

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
| "Sisäisiä levyjä ei löytynyt" | Intel RST/VMD-ohjaimen ajuri puuttuu WinPE:stä. Helpoin: kopioi koneen valmistajan RST/VMD-ajuri (kansio jossa .inf) tikun kansioon `iRequire\Drivers` ja käynnistä uudelleen. WinPE lataa sieltä tallennusohjainten ajurit ennen levyjen etsimistä, ja sama ajuri menee myös asennettuun Windowsiin. Vaihtoehdot: `Build\Drivers\WinPE` + uudelleenrakennus, tai BIOSista VMD pois / SATA-tila AHCI. |
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

Neljä tasoa. Kolme ensimmäistä ajetaan automaattisesti GitHub Actionsissa, oikealla Windowsilla (Windows PowerShell 5.1, sama kuin WinPE:ssä) tai virtuaalikoneessa:

**1. `Tests\Test-iRequire.ps1`: jokaisella commitilla.** Noin 50 tarkistusta:
- **Tyhjennys päästä päähän:** levy korvataan testitiedostolla, jolle ajetaan HDD-ylikirjoitus, NVMe:n kryptografinen tyhjennys, "valehteleva" SSD, tukematon komento ja simuloitu viallinen sektori. Todistus kirjoitetaan.
- **Tilakone:** simuloidut uudelleenkäynnistykset, virheet ja vioittunut tila. Silmukka on todistetusti mahdoton.
- **Pelikunto- ja virityspäätökset:** RAM, näytöt, näytönohjaimen tunnistus ja virrankäyttö.
- **Tietoturva:** mikään asetus ei saa heikentää Defenderiä, palomuuria, UAC:ta, SmartScreenia, VBS:ää tai päivityksiä.
- **Tikun eheys, vastaustiedosto, levyjen luokittelu** ja kirjoitusvirheet funktiokutsuissa.
- **Windows-integraatio** (vain lukevat testit):
  - suora levyn luku Win32-kutsuilla
  - levyjen luokittelu oikealla raudalla
  - `bcdedit`-tulosteen tunnistus
  - näyttötilojen luku
  - rekisterikirjoitus

**2. `.github/workflows/build.yml`: kun rakennus muuttuu, tai käsin.**
- Asentaa ADK:n ja WinPE:n sekä lataa virallisen ISOn. Tiiviste tarkistetaan.
- Ajaa `Build-iRequire.ps1`:n ja `New-iRequireIso.ps1`:n.
- `Tests\Test-BuildOutput.ps1` liittää valmiit kuvat vain luku -tilassa ja tarkistaa:
  - boot.wim: PowerShell, Storage-moduuli ja käynnistin
  - asennuskuva: .NET 3.5, SMB1, oletuskäyttäjän asetukset ja poistetut sovellukset
  - eheysmanifesti

**3. Päästä päähän -testi virtuaalikoneessa: automaattisesti rakennuksen perään.** Rakennettu ISO käynnistetään QEMU/KVM-virtuaalikoneessa, joka on varustettu kuin nykyinen pelikone: UEFI ja Secure Boot Microsoftin avaimilla, TPM 2.0 (swtpm) sekä NVMe- ja SATA-levy, joille on kirjoitettu tunnistettavaa "salaista" dataa. Koko ketju ajetaan ilman ihmistä: WinPE, eheystarkistus, laskuri, tyhjennys, asennus, Windowsin ensikäynnistys ja jälkiasennus. Kun Windows sammuttaa itsensä, levyt tutkitaan ulkopuolelta:
- salaista dataa ei löydy kummaltakaan levyltä (jokainen tavu luetaan)
- tyhjennystodistus hyväksyy molemmat levyt
- jälkiasennus on valmis, salasanat ja selväkielinen vastaustiedosto on poistettu
- rekisteristä: telemetria 0, haavoittuvien ajurien estolista, GPU-ajoitus, automaattisen laitesalauksen esto
- yhteenvedosta: Defender, ASR-säännöt (Defenderin mukaan), palomuuri, .NET 3.5, Secure Boot ja TPM

Kuvakaappaukset puolen minuutin välein tallentuvat artefaktiksi. Ajuri: `Tests/e2e/run-e2e.sh`.

**4. Harjoitustila oikealla koneella: sinä, ennen ensimmäistä oikeaa ajoa.** Virtuaalikone ei kerro, tunnistaako WinPE juuri sinun koneesi levyohjaimen. Harjoitustila kertoo, ks. [ensimmäinen kerta](#ensimmäinen-kerta-näin-varmistat-että-se-toimii).

## Rakenne

```
Build/        ISOn muokkaus, tikun kirjoitus, ISO-levykuva
WinPE/        Tikulla ajettava vaihe: eheys, laskuri, tyhjennys, asennus
Unattend/     Vastaustiedoston pohja (OOBE ohitetaan)
PostInstall/  Asennetussa Windowsissa ajettava vaihe
Policies/     Ryhmäkäytännöt, oletuskäyttäjän asetukset, poistolista
Lib/          Yhteiset funktiot: loki, asetukset, eheys, tilakone
Config/       Asetukset
Tools/        Kohdekoneen esitarkistus (kulkee tikulla: iRequire\Tools)
Tests/        Tarkistukset, Hyper-V-testikone ja QEMU/KVM-paasta paahan -testi
```
