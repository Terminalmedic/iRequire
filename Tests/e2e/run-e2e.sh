#!/usr/bin/env bash
# ==============================================================
#  iRequire - paasta paahan -testi QEMU/KVM-virtuaalikoneessa
#
#  1. ISO jossa testiasetukset (tehty Windows-ajossa)
#  2. Kaksi levya taynna "salaista" dataa: NVMe (kohde) ja SATA
#  3. Kone kaynnistyy ISOlta UEFI:lla ja koko ketju ajetaan ilman
#     ihmista: WinPE -> tyhjennys -> asennus -> OOBE -> jalkiasennus
#  4. Kun Windows sammuttaa itsensa, levyt tutkitaan ulkopuolelta:
#       - salaista dataa ei loydy kummaltakaan levylta
#       - tyhjennystodistus: molemmat levyt HYVAKSYTTY
#       - jalkiasennuksen tila: Valmis
#
#  Kaytto: run-e2e.sh <iRequire.iso> <tyokansio>
# ==============================================================
set -euo pipefail

ISO_IN="$1"
WORK="$2"
TIMEOUT_MIN="${E2E_TIMEOUT_MIN:-150}"
SECRET="IREQUIRE-SALAINEN-TESTIDATA-7f3a9c"

mkdir -p "$WORK/shots" "$WORK/out"
cd "$WORK"
log() { echo "[$(date +%H:%M:%S)] $*"; }

# --- 1. ISO ----------------------------------------------------
# Testiasetukset (lyhyt laskuri, sammutus lopuksi) on asetettu jo
# Windows-ajossa Set-E2eConfig.ps1:lla ennen ISOn tekoa.
# Ei kopioida: levytila on CI-ajurissa tiukka.
ln -sf "$ISO_IN" iso.iso
log "ISO: $(du -hL iso.iso | cut -f1)"
resources() { log "resurssit: $(df -h --output=avail "$WORK" | tail -1 | tr -d ' ') vapaana, muistia $(free -m | awk '/Mem:/ {print $7}') Mt vapaana"; }
resources

# --- 2. Levyt salaisella datalla ------------------------------
seed_disk() {
    local file="$1" size_gb="$2"
    rm -f "$file.raw"
    truncate -s "${size_gb}G" "$file.raw"
    # Salaisuus alkuun, keskelle ja loppuun + satunnaista dataa valiin.
    for pos_mb in 1 64 $(( size_gb * 512 )) $(( size_gb * 1024 - 8 )); do
        { for _ in $(seq 1 2048); do printf '%s-%08d\n' "$SECRET" "$pos_mb"; done
          head -c 4M /dev/urandom; } | dd of="$file.raw" bs=1M seek="$pos_mb" conv=notrunc status=none
    done
    qemu-img convert -f raw -O qcow2 "$file.raw" "$file.qcow2"
    rm -f "$file.raw"
}
log "Luodaan levyt (NVMe 48 Gt kohde, SATA 16 Gt data)"
seed_disk nvme 48
seed_disk sata 16

# Ulkoinen USB-levy "IRQLOKI": WinPE kirjoittaa lokinsa sille (ISO on vain
# luku), joten syy nakyy vaikka kone pysahtyisi. Samalla testataan, etta
# ulkoiseen USB-levyyn ei kosketa: merkkitiedoston pitaa sailya.
# Kuten oikea tikku: MBR-osiotaulu ja FAT32-osio 1 MiB:n kohdalla. Ilman
# osiotaulua (superfloppy) Windows ei liita kiinteaa levya (ajo 19).
rm -f loki.img; truncate -s 64M loki.img
echo 'start=2048, type=c' | sfdisk -q loki.img
mkfs.vfat -F 32 --offset 2048 -n IRQLOKI loki.img $(( (64 * 1024 * 1024 / 512 - 2048) / 2 )) >/dev/null
LOKI="loki.img@@1M"
echo "$SECRET-USB" > usb-merkki.txt; mcopy -i "$LOKI" usb-merkki.txt ::/usb-merkki.txt

# Kuten oikea pelikone: Secure Boot paalla Microsoftin avaimilla ja TPM 2.0.
# Nain testataan myos etta tikku kaynnistyy Secure Bootin kanssa.
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.ms.fd
for f in "$OVMF_CODE" "$OVMF_VARS"; do [ -f "$f" ] || { log "puuttuu $f"; exit 1; }; done
cp "$OVMF_VARS" vars.fd
mkdir -p tpm
swtpm socket --tpm2 --tpmstate dir=tpm --ctrl type=unixio,path=tpm/swtpm.sock --log file=out/swtpm.log &
for _ in $(seq 1 50); do [ -S tpm/swtpm.sock ] && break; sleep 0.1; done
[ -S tpm/swtpm.sock ] || { log "swtpm ei kaynnistynyt"; exit 1; }

# --- 3. Kaynnistys --------------------------------------------
# CD:ta ei pakoteta ensimmaiseksi: kuten tyhjassa PC:ssa, laiteohjelmisto
# kokeilee ensin levyja (ei kaynnistettavaa) ja sitten CD:ta. Asennuksen
# jalkeen bcdbootin luoma Windows Boot Manager on ensimmaisena.
log "Kaynnistetaan virtuaalikone (aikaraja $TIMEOUT_MIN min)"
qemu-system-x86_64 \
    -enable-kvm -machine q35,smm=on -cpu host -smp 2 -m 3072 \
    -global driver=cfi.pflash01,property=secure,value=on \
    -global ICH9-LPC.disable_s3=1 \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,unit=1,file=vars.fd \
    -chardev socket,id=chrtpm,path=tpm/swtpm.sock \
    -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0 \
    -drive file=nvme.qcow2,if=none,id=nvm,format=qcow2,discard=unmap,detect-zeroes=unmap \
    -device nvme,drive=nvm,serial=IREQNVME0001 \
    -device ahci,id=ahci \
    -drive file=sata.qcow2,if=none,id=sata,format=qcow2,discard=unmap,detect-zeroes=unmap \
    -device ide-hd,drive=sata,bus=ahci.0,serial=IREQSATA0001 \
    -drive file=iso.iso,if=none,id=cd,media=cdrom,readonly=on \
    -device ide-cd,drive=cd,bus=ahci.1 \
    -device qemu-xhci,id=xhci \
    -drive file=loki.img,if=none,id=loki,format=raw \
    -device usb-storage,bus=xhci.0,drive=loki,serial=IREQLOKI0001,removable=on \
    -netdev user,id=n0 -device e1000e,netdev=n0,romfile= \
    -vga std -display none \
    -monitor unix:mon.sock,server,nowait \
    -serial file:out/serial.log \
    -name iRequire-e2e &
QEMU_PID=$!

shot=0
deadline=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
STALL_MIN="${E2E_STALL_MIN:-25}"
last_size=0
last_change=$(date +%s)
while kill -0 "$QEMU_PID" 2>/dev/null; do
    sleep 30
    shot=$((shot + 1))
    # Joka minuutti resurssit ajon lokiin: jos ajuri kuolee, syy nakyy.
    if [ $((shot % 2)) -eq 0 ]; then resources; log "levyt: nvme $(du -h nvme.qcow2 | cut -f1), sata $(du -h sata.qcow2 | cut -f1)"; fi
    # iRequiren oma loki sarjaportista reaaliajassa ajon lokiin.
    if [ -f out/serial.log ]; then
        now_lines=$(wc -l < out/serial.log)
        if [ "$now_lines" -gt "${seen_lines:-0}" ]; then
            tail -n +$(( ${seen_lines:-0} + 1 )) out/serial.log | head -n $(( now_lines - ${seen_lines:-0} )) | tr -d '\r' | sed 's/^/    VM> /'
            seen_lines=$now_lines
        fi
    fi
    # Kuvakaappaus puolen minuutin valein: jos jokin jumittuu, nakyy mihin.
    f="$WORK/shots/s$(printf %04d $shot)"
    echo "screendump $f.ppm" | socat - "unix-connect:mon.sock" >/dev/null 2>&1 || true
    # Heti PNG:ksi, jotta perutustakin ajosta jaa kuvat. Vanhat harvennetaan.
    sleep 1; if [ -f "$f.ppm" ]; then pnmtopng "$f.ppm" > "$f.png" 2>/dev/null || true; fi; rm -f "$f.ppm"
    old="$WORK/shots/s$(printf %04d $((shot - 8))).png"
    [ $(( (shot - 8) % 4 )) -ne 0 ] && rm -f "$old"
    # Jumin tunnistus: jos kone ei $STALL_MIN minuuttiin kirjoita sarjaporttiin
    # eika levykuva kasva, se odottaa jotain (virheilmoitus, nappainta).
    # Pelkka levykuvan koko ei riita: se kasvaa vain kun uusia lohkoja
    # varataan (ja TRIM jopa pienentaa sita), joten tyossa oleva kone
    # naytti jumittuneelta.
    size=$(( $(stat -c %s nvme.qcow2) + $(stat -c %s sata.qcow2) ))
    serial=$(stat -c %s out/serial.log 2>/dev/null || echo 0)
    if [ "$size" -ne "$last_size" ] || [ "$serial" -ne "${last_serial:-0}" ]; then
        last_size=$size; last_serial=$serial; last_change=$(date +%s)
    fi
    if [ $(( $(date +%s) - last_change )) -gt $(( STALL_MIN * 60 )) ]; then
        log "JUMISSA: ei sarjaporttilokia eika levymuutoksia $STALL_MIN minuuttiin"
        echo "quit" | socat - "unix-connect:mon.sock" >/dev/null 2>&1 || kill "$QEMU_PID" || true
        wait "$QEMU_PID" || true
        echo "STALL" > out/tulos.txt
        break
    fi
    if [ "$(date +%s)" -gt "$deadline" ]; then
        log "AIKARAJA: kone ei sammunut itse $TIMEOUT_MIN minuutissa"
        echo "quit" | socat - "unix-connect:mon.sock" >/dev/null 2>&1 || kill "$QEMU_PID" || true
        wait "$QEMU_PID" || true
        echo "TIMEOUT" > out/tulos.txt
        break
    fi
done
wait "$QEMU_PID" 2>/dev/null || true
log "Virtuaalikone pysahtyi"

# --- 4. Tarkistus ulkopuolelta --------------------------------
# Jokainen tarkistus on sellainen, ettei lukuvirhe voi naytta lapaisylta:
# listaukset tallennetaan ensin tiedostoihin ja levyn skannaus vaatii
# etta koko levy luettiin.
fail=0
check() { if eval "$2"; then log "OK    $1"; else log "VIRHE $1"; fail=1; fi; }
export LIBGUESTFS_BACKEND=direct

log "Luetaan tulokset levylta (libguestfs)"
mkdir -p out/loki; mcopy -s -n -i "$LOKI" ::/iRequire out/loki/ 2>/dev/null || true
check 'Ulkoinen USB-levy koskematon (merkkitiedosto sailyi)' "mtype -i '$LOKI' ::/usb-merkki.txt 2>/dev/null | grep -q '$SECRET-USB'"
check 'WinPE:n loki tallentui lokitikulle' "ls out/loki/iRequire/Reports/*/winpe.log >/dev/null 2>&1"
virt-copy-out -a nvme.qcow2 /iRequire/Logs /iRequire/Reports out/ 2>out/guestfs.err || log "kopiointi epaonnistui: $(tail -3 out/guestfs.err)"
for dir in /Windows/System32/config /Windows/Panther /iRequire /iRequire/Config; do
    name=$(echo "$dir" | tr '/' '_')
    virt-ls -a nvme.qcow2 "$dir" > "out/ls$name.txt" 2>>out/guestfs.err || echo "__LUKUVIRHE__" > "out/ls$name.txt"
done
# Heti ajon lokiin: artefakteja ei aina voi ladata, ja myohempi vaihe voi kaatua.
if [ -f out/Reports/yhteenveto.txt ]; then echo '----- yhteenveto.txt -----'; tr -d '\r' < out/Reports/yhteenveto.txt; fi

scan_disk() {
    # Tulostaa: luetut_tavut levyn_koko osumat
    local disk="$1" size
    size=$(guestfish --ro -a "$disk" run : blockdev-getsize64 /dev/sda)
    guestfish --ro -a "$disk" run : download /dev/sda - | python3 -c '
import sys
secret = sys.argv[1].encode(); keep = len(secret) - 1
total = hits = 0; tail = b""
while True:
    chunk = sys.stdin.buffer.read(16 << 20)
    if not chunk: break
    total += len(chunk)
    buf = tail + chunk
    hits += buf.count(secret)
    tail = buf[-keep:] if keep else b""
print(total, sys.argv[2], hits)' "$SECRET" "$size"
}

check 'Windows asennettiin NVMe-levylle' "grep -qx 'SYSTEM' out/ls_Windows_System32_config.txt"
if [ "${E2E_EXPECT_UPDATES:-0}" = "1" ]; then
    check 'Windows Update: paivityksia asennettiin' "python3 -c \"import json,sys; d=json.load(open('out/Logs/tila.json',encoding='utf-8-sig')); sys.exit(0 if int(d.get('Paivityksia',0))>0 else 1)\""
fi
check 'Jalkiasennus valmis (tila.json)' "python3 -c \"import json,sys; d=json.load(open('out/Logs/tila.json',encoding='utf-8-sig')); sys.exit(0 if d.get('Valmis') else 1)\""
check 'Tyhjennystodistus: molemmat levyt HYVAKSYTTY' "[ \$(cat out/Reports/tyhjennystodistus-*.txt 2>/dev/null | grep -c 'Varmistus:    HYVAKSYTTY') -eq 2 ]"
check 'Yhteenveto kirjoitettu' "test -s out/Reports/yhteenveto.txt"
check 'Yhtaan jalkiasennuksen vaihetta ei ohitettu' "grep -a -q 'Kaikki vaiheet onnistuivat' out/Reports/yhteenveto.txt"
check '.NET 3.5 kaytossa (offline-asennus viimeistelty kaynnistyksessa)' "grep -a -q '.NET Framework 3.5: Enabled' out/Reports/yhteenveto.txt"
check 'Defender paalla' "grep -a -q 'reaaliaikainen suojaus paalla' out/Reports/yhteenveto.txt"
check 'Palomuuri paalla' "grep -a -q 'Palomuuri: paalla kaikissa profiileissa' out/Reports/yhteenveto.txt"
check 'Secure Boot paalla (tikku kaynnistyi Secure Bootilla)' "grep -a -q 'Secure Boot: paalla' out/Reports/yhteenveto.txt"
check 'TPM valmis' "grep -a -q 'TPM: valmis' out/Reports/yhteenveto.txt"
check 'Pelikunto: huijauksenestojen vaatimukset tayttyvat' "grep -a -q 'Secure Boot ja TPM 2.0 paalla' out/Reports/yhteenveto.txt"
check 'Keskeneraisen asennuksen merkki poistettu' "grep -q 'PostInstall' out/ls_iRequire.txt && ! grep -q 'ASENNUS-KESKEN.tag' out/ls_iRequire.txt"
check 'C:\\iRequire lukittu, kayttajalle oma kansio (Register-PostInstall)' "grep -qx 'Kayttaja' out/ls_iRequire.txt"
virt-ls -a nvme.qcow2 '/Program Files (x86)/Steam' > out/ls_steam.txt 2>/dev/null || true
virt-ls -a nvme.qcow2 '/Program Files/Mozilla Firefox' > out/ls_firefox.txt 2>/dev/null || true
check 'Steam asennettu (Valven allekirjoitus hyvaksytty)' "grep -qix 'steam.exe' out/ls_steam.txt"
check 'Firefox asennettu (Mozillan allekirjoitus hyvaksytty)' "grep -qix 'firefox.exe' out/ls_firefox.txt"
virt-ls -a nvme.qcow2 '/Users/user/AppData/Local/Discord' > out/ls_discord.txt 2>/dev/null || true
virt-ls -a nvme.qcow2 '/Users/user/AppData/Roaming/Spotify' > out/ls_spotify.txt 2>/dev/null || true
check 'Discord asennettu kayttajalle (kayttajan istunto)' "grep -qix 'Update.exe' out/ls_discord.txt"
check 'Spotify asennettu kayttajalle (kayttajan istunto)' "grep -qix 'Spotify.exe' out/ls_spotify.txt"
virt-ls -a nvme.qcow2 '/Users/Public/Desktop' > out/ls_desktop.txt 2>/dev/null || true
check 'Yhteenveto tyopoydalla' "grep -qi 'iRequire - yhteenveto.lnk' out/ls_desktop.txt"
check 'Selvakielinen unattend.xml poistettu' "! grep -q '__LUKUVIRHE__' out/ls_Windows_Panther.txt && ! grep -qix 'unattend.xml' out/ls_Windows_Panther.txt"
check 'Asetustiedosto (salasanat) poistettu' "! grep -q '__LUKUVIRHE__' out/ls_iRequire_Config.txt && ! grep -q 'iRequire.json' out/ls_iRequire_Config.txt"

# Rekisteri luetaan suoraan levylta: tulivatko kaytannot ja viritykset voimaan?
# Puuttuva avain ei saa kaataa skriptia (set -e + pipefail): tarkistus kertoo.
# --unsafe-printable-strings: muuten REG_SZ tulostuu muodossa hex(1):...
reg() { virt-win-reg --unsafe-printable-strings nvme.qcow2 "$1" 2>>out/reg-virheet.txt | tr -d '\r' || true; }
# Levylla ei ole CurrentControlSet-avainta (Windows luo sen kaynnistyessa):
# oikea ControlSet00N luetaan avaimesta Select.
cs=$(reg 'HKLM\SYSTEM\Select' | sed -n 's/^"Current"=dword:0*\([0-9a-f]*\)$/\1/Ip' | head -1)
ccs="HKLM\\SYSTEM\\ControlSet$(printf '%03d' "$((16#${cs:-1}))")"
log "Kaytossa oleva ControlSet: $ccs"
reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' > out/reg-telemetria.txt
reg "$ccs\\Control\\CI\\Config" > out/reg-ci.txt
reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Windows Defender Exploit Guard\ASR\Rules' > out/reg-asr.txt
reg "$ccs\\Control\\GraphicsDrivers" > out/reg-gpu.txt
reg "$ccs\\Control\\BitLocker" > out/reg-bitlocker.txt
check 'Telemetria tasolla 0 (kaytanto voimassa)' "grep -qi '\"AllowTelemetry\"=dword:00000000' out/reg-telemetria.txt"
check 'Haavoittuvien ajurien estolista paalla' "grep -qi '\"VulnerableDriverBlocklistEnable\"=dword:00000001' out/reg-ci.txt"
# ASR: Defenderin oma nakemys yhteenvedosta (Get-MpPreference). Levylta luettu
# kaytantoavain vain diagnostiikkaan.
reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender' > out/reg-defender.txt
check 'ASR-saannot estotilassa (3 kpl, Defenderin mukaan)' "grep -a -q 'ASR-saannot: [3-9] estotilassa' out/Reports/yhteenveto.txt"
check 'Laitteistokiihdytetty GPU-ajoitus' "grep -qi '\"HwSchMode\"=dword:00000002' out/reg-gpu.txt"
check 'Automaattinen laitesalaus estetty' "grep -qi '\"PreventDeviceEncryption\"=dword:00000001' out/reg-bitlocker.txt"

for d in sata nvme; do
    read -r got size hits < <(scan_disk "$d.qcow2" || echo "0 1 -1")
    log "levy $d: luettu $got / $size tavua, salaisuuden osumia $hits"
    check "Koko levy luettiin ($d)" "[ '$got' = '$size' ] && [ '$size' -gt 1000000 ]"
    check "Salaista dataa ei loydy levylta ($d)" "[ '$hits' = '0' ]"
done


# --- 5. Diagnostiikka ajon lokiin (artefaktit eivat aina ole saatavilla) ---
if [ "$fail" -ne 0 ]; then
    # Diagnostiikka ei saa kaatua (set -e + pipefail): jokainen komento || true.
    set +e +o pipefail
    echo '===== DIAGNOSTIIKKA ====='
    # Ensin nayton teksti: jos WinPE pysahtyi, syy on ruudulla eika levylla ole mitaan.
    echo '----- Nayton teksti (OCR, viimeiset kuvakaappaukset) -----'
    for png in $(ls shots/*.png 2>/dev/null | tail -n 3); do
        echo ">> $png"
        convert "$png" -negate -resize 200% -threshold 50% /tmp/ocr.png 2>/dev/null && tesseract /tmp/ocr.png - 2>/dev/null | grep -v '^\s*$' | head -60
    done
    for f in out/loki/iRequire/Reports/*/winpe.log; do
        [ -f "$f" ] || continue
        echo "----- $f (lokitikku, viimeiset 80 rivia) -----"; tail -n 80 "$f" | tr -d '\r'
    done
    echo '----- Sarjaporttiloki (viimeiset 80 rivia) -----'
    tail -n 80 out/serial.log 2>/dev/null | tr -d '\r'
    for f in out/Reports/*.log out/Logs/*.log out/Logs/*.json; do
        [ -f "$f" ] || continue
        echo "----- $f (viimeiset 60 rivia) -----"; tail -n 60 "$f" | tr -d '\r'
    done
    for dir in /iRequire /iRequire/Logs /iRequire/Reports /Windows/Panther /Windows/Setup/Scripts; do
        echo "----- ls $dir -----"; virt-ls -a nvme.qcow2 "$dir" 2>&1 | head -40
    done
    for f in out/reg-*.txt; do echo "----- $f -----"; head -n 20 "$f"; done
    echo '----- EFI-osio -----'
    virt-ls -a nvme.qcow2 -m /dev/sda1 /EFI/Microsoft/Boot 2>&1 | head -20
    for f in /Windows/Panther/setupact.log /Windows/Panther/setuperr.log /Windows/Panther/UnattendGC/setupact.log /Windows/Panther/UnattendGC/setuperr.log /iRequire/Logs/setupcomplete.log; do
        echo "----- $f (viimeiset 40 rivia) -----"
        virt-cat -a nvme.qcow2 "$f" 2>/dev/null | tr -d '\r' | tail -n 40
    done
    set -e -o pipefail
fi
for f in out/Reports/tyhjennystodistus-*.txt; do [ -f "$f" ] && { echo "----- $(basename "$f") -----"; cat "$f"; }; done

if [ "$fail" -ne 0 ]; then log "PAASTA PAAHAN -TESTI EPAONNISTUI"; exit 1; fi
log "PAASTA PAAHAN -TESTI LAPI"
