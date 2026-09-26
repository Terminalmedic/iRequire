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

cp /usr/share/OVMF/OVMF_VARS_4M.fd vars.fd

# --- 3. Kaynnistys --------------------------------------------
# CD:ta ei pakoteta ensimmaiseksi: kuten tyhjassa PC:ssa, laiteohjelmisto
# kokeilee ensin levyja (ei kaynnistettavaa) ja sitten CD:ta. Asennuksen
# jalkeen bcdbootin luoma Windows Boot Manager on ensimmaisena.
log "Kaynnistetaan virtuaalikone (aikaraja $TIMEOUT_MIN min)"
qemu-system-x86_64 \
    -enable-kvm -machine q35 -cpu host -smp 2 -m 3072 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file=vars.fd \
    -drive file=nvme.qcow2,if=none,id=nvm,format=qcow2,discard=unmap,detect-zeroes=unmap \
    -device nvme,drive=nvm,serial=IREQNVME0001 \
    -device ahci,id=ahci \
    -drive file=sata.qcow2,if=none,id=sata,format=qcow2,discard=unmap,detect-zeroes=unmap \
    -device ide-hd,drive=sata,bus=ahci.0,serial=IREQSATA0001 \
    -drive file=iso.iso,if=none,id=cd,media=cdrom,readonly=on \
    -device ide-cd,drive=cd,bus=ahci.1 \
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
    # Jumin tunnistus: jos kumpikaan levy ei muutu $STALL_MIN minuuttiin,
    # kone odottaa jotain (virheilmoitus, nappainta) - ei kannata odottaa tunteja.
    size=$(( $(stat -c %s nvme.qcow2) + $(stat -c %s sata.qcow2) ))
    if [ "$size" -ne "$last_size" ]; then last_size=$size; last_change=$(date +%s); fi
    if [ $(( $(date +%s) - last_change )) -gt $(( STALL_MIN * 60 )) ]; then
        log "JUMISSA: levyt eivat ole muuttuneet $STALL_MIN minuuttiin"
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
virt-copy-out -a nvme.qcow2 /iRequire/Logs /iRequire/Reports out/ 2>out/guestfs.err || log "kopiointi epaonnistui: $(tail -3 out/guestfs.err)"
for dir in /Windows/System32/config /Windows/Panther /iRequire /iRequire/Config; do
    name=$(echo "$dir" | tr '/' '_')
    virt-ls -a nvme.qcow2 "$dir" > "out/ls$name.txt" 2>>out/guestfs.err || echo "__LUKUVIRHE__" > "out/ls$name.txt"
done

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
check 'Jalkiasennus valmis (tila.json)' "python3 -c \"import json,sys; d=json.load(open('out/Logs/tila.json',encoding='utf-8-sig')); sys.exit(0 if d.get('Valmis') else 1)\""
check 'Tyhjennystodistus: molemmat levyt HYVAKSYTTY' "[ \$(cat out/Reports/tyhjennystodistus-*.txt 2>/dev/null | grep -c 'Varmistus:    HYVAKSYTTY') -eq 2 ]"
check 'Yhteenveto kirjoitettu' "test -s out/Reports/yhteenveto.txt"
check '.NET 3.5 kaytossa (offline-asennus viimeistelty kaynnistyksessa)' "grep -a -q '.NET Framework 3.5: Enabled' out/Reports/yhteenveto.txt"
check 'Defender paalla' "grep -a -q 'reaaliaikainen suojaus paalla' out/Reports/yhteenveto.txt"
check 'Palomuuri paalla' "grep -a -q 'Palomuuri: paalla kaikissa profiileissa' out/Reports/yhteenveto.txt"
check 'Keskeneraisen asennuksen merkki poistettu' "grep -q 'PostInstall' out/ls_iRequire.txt && ! grep -q 'ASENNUS-KESKEN.tag' out/ls_iRequire.txt"
check 'Selvakielinen unattend.xml poistettu' "! grep -q '__LUKUVIRHE__' out/ls_Windows_Panther.txt && ! grep -qix 'unattend.xml' out/ls_Windows_Panther.txt"
check 'Asetustiedosto (salasanat) poistettu' "! grep -q '__LUKUVIRHE__' out/ls_iRequire_Config.txt && ! grep -q 'iRequire.json' out/ls_iRequire_Config.txt"

# Rekisteri luetaan suoraan levylta: tulivatko kaytannot ja viritykset voimaan?
reg() { virt-win-reg nvme.qcow2 "$1" 2>/dev/null | tr -d '\r'; }
reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' > out/reg-telemetria.txt
reg 'HKLM\SYSTEM\CurrentControlSet\Control\CI\Config' > out/reg-ci.txt
reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Windows Defender Exploit Guard\ASR\Rules' > out/reg-asr.txt
reg 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' > out/reg-gpu.txt
reg 'HKLM\SYSTEM\CurrentControlSet\Control\BitLocker' > out/reg-bitlocker.txt
check 'Telemetria tasolla 0 (kaytanto voimassa)' "grep -qi '\"AllowTelemetry\"=dword:00000000' out/reg-telemetria.txt"
check 'Haavoittuvien ajurien estolista paalla' "grep -qi '\"VulnerableDriverBlocklistEnable\"=dword:00000001' out/reg-ci.txt"
check 'ASR-saannot estotilassa (3 kpl)' "[ \$(grep -ci '=\"1\"' out/reg-asr.txt) -ge 3 ]"
check 'Laitteistokiihdytetty GPU-ajoitus' "grep -qi '\"HwSchMode\"=dword:00000002' out/reg-gpu.txt"
check 'Automaattinen laitesalaus estetty' "grep -qi '\"PreventDeviceEncryption\"=dword:00000001' out/reg-bitlocker.txt"

for d in sata nvme; do
    read -r got size hits < <(scan_disk "$d.qcow2" || echo "0 1 -1")
    log "levy $d: luettu $got / $size tavua, salaisuuden osumia $hits"
    check "Koko levy luettiin ($d)" "[ '$got' = '$size' ] && [ '$size' -gt 1000000 ]"
    check "Salaista dataa ei loydy levylta ($d)" "[ '$hits' = '0' ]"
done

if [ -f out/Reports/yhteenveto.txt ]; then echo '----- yhteenveto.txt -----'; cat out/Reports/yhteenveto.txt; fi

# --- 5. Diagnostiikka ajon lokiin (artefaktit eivat aina ole saatavilla) ---
if [ "$fail" -ne 0 ]; then
    echo '===== DIAGNOSTIIKKA ====='
    for f in out/Reports/*.log out/Logs/*.log out/Logs/*.json; do
        [ -f "$f" ] || continue
        echo "----- $f (viimeiset 60 rivia) -----"; tail -n 60 "$f" | tr -d '\r'
    done
    for dir in /iRequire /iRequire/Logs /iRequire/Reports /Windows/Panther /Windows/Setup/Scripts; do
        echo "----- ls $dir -----"; virt-ls -a nvme.qcow2 "$dir" 2>&1 | head -40
    done
    echo '----- EFI-osio -----'
    virt-ls -a nvme.qcow2 -m /dev/sda1 /EFI/Microsoft/Boot 2>&1 | head -20
    for f in /Windows/Panther/setupact.log /Windows/Panther/setuperr.log /Windows/Panther/UnattendGC/setupact.log /Windows/Panther/UnattendGC/setuperr.log /iRequire/Logs/setupcomplete.log; do
        echo "----- $f (viimeiset 40 rivia) -----"
        virt-cat -a nvme.qcow2 "$f" 2>/dev/null | tr -d '\r' | tail -n 40
    done
    echo '----- Nayton teksti (OCR, viimeiset kuvakaappaukset) -----'
    for png in $(ls shots/*.png 2>/dev/null | tail -n 2); do
        echo ">> $png"
        convert "$png" -negate -resize 200% -threshold 50% /tmp/ocr.png 2>/dev/null && tesseract /tmp/ocr.png - 2>/dev/null | grep -v '^\s*$' | head -40
    done
fi
for f in out/Reports/tyhjennystodistus-*.txt; do [ -f "$f" ] && { echo "----- $(basename "$f") -----"; cat "$f"; }; done

if [ "$fail" -ne 0 ]; then log "PAASTA PAAHAN -TESTI EPAONNISTUI"; exit 1; fi
log "PAASTA PAAHAN -TESTI LAPI"
