#!/usr/bin/env bash
# ==============================================================
#  iRequire - paasta paahan -testi QEMU/KVM-virtuaalikoneessa
#
#  1. Testiasetukset ISOon (lyhyt laskuri, sammutus lopuksi)
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
TIMEOUT_MIN="${E2E_TIMEOUT_MIN:-210}"
UPDATE_ROUNDS="${E2E_UPDATE_ROUNDS:-0}"
SECRET="IREQUIRE-SALAINEN-TESTIDATA-7f3a9c"

mkdir -p "$WORK/shots" "$WORK/out"
cd "$WORK"
log() { echo "[$(date +%H:%M:%S)] $*"; }

# --- 1. Testiasetukset ISOon ---------------------------------
log "Testiasetukset ISOon"
rm -f cfg.json iso.iso
xorriso -osirrox on -indev "$ISO_IN" -extract /iRequire/Config/iRequire.json cfg.json >/dev/null 2>&1
chmod u+w cfg.json
python3 - "$UPDATE_ROUNDS" <<'EOF'
import json, sys
p = 'cfg.json'
raw = open(p, encoding='utf-8-sig').read()
c = json.loads(raw)
c['Tyhjennys']['LaskuriSekuntia'] = 5
c['Tyhjennys']['MinimikokoGt'] = 20
c['Tyhjennys']['OdotaVerkkovirtaa'] = False
c['Paivitykset']['MaksimiKierrokset'] = int(sys.argv[1])
c['Paivitykset']['VerkonOdotusMinuuttia'] = 3
c['Asennus']['LopuksiSammutus'] = True
open(p, 'w', encoding='utf-8').write(json.dumps(c, indent=2, ensure_ascii=True))
EOF
# Kayttajan muokattavissa oleva asetustiedosto ei kuulu eheysmanifestiin,
# joten sen vaihtaminen ei riko tarkistusta - tama testaa myos sen.
xorriso -indev "$ISO_IN" -outdev iso.iso -boot_image any replay \
    -map cfg.json /iRequire/Config/iRequire.json -commit >/dev/null 2>&1
log "ISO valmis: $(du -h iso.iso | cut -f1)"

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
log "Luodaan levyt (NVMe 64 Gt kohde, SATA 16 Gt data)"
seed_disk nvme 64
seed_disk sata 16

cp /usr/share/OVMF/OVMF_VARS_4M.fd vars.fd

# --- 3. Kaynnistys --------------------------------------------
# CD:ta ei pakoteta ensimmaiseksi: kuten tyhjassa PC:ssa, laiteohjelmisto
# kokeilee ensin levyja (ei kaynnistettavaa) ja sitten CD:ta. Asennuksen
# jalkeen bcdbootin luoma Windows Boot Manager on ensimmaisena.
log "Kaynnistetaan virtuaalikone (aikaraja $TIMEOUT_MIN min)"
qemu-system-x86_64 \
    -enable-kvm -machine q35 -cpu host -smp 2 -m 4096 \
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
while kill -0 "$QEMU_PID" 2>/dev/null; do
    sleep 30
    shot=$((shot + 1))
    # Kuvakaappaus puolen minuutin valein: jos jokin jumittuu, nakyy mihin.
    echo "screendump $WORK/shots/s$(printf %04d $shot).ppm" | socat - "unix-connect:mon.sock" >/dev/null 2>&1 || true
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

# Kuvakaappaukset PNG:ksi (vain joka neljas ja viimeiset, jottei artefakti paisu).
for f in shots/*.ppm; do
    [ -e "$f" ] || continue
    n=$(basename "$f" .ppm | tr -dc 0-9); n=$((10#$n))
    if [ $((n % 4)) -eq 0 ] || [ "$n" -gt $((shot - 6)) ]; then pnmtopng "$f" > "${f%.ppm}.png" 2>/dev/null || true; fi
    rm -f "$f"
done

# --- 4. Tarkistus ulkopuolelta --------------------------------
fail=0
check() { if eval "$2"; then log "OK    $1"; else log "VIRHE $1"; fail=1; fi; }

log "Luetaan tulokset levylta (libguestfs)"
export LIBGUESTFS_BACKEND=direct
virt-copy-out -a nvme.qcow2 /iRequire/Logs /iRequire/Reports out/ 2>out/guestfs.err || log "levyn luku epaonnistui: $(tail -3 out/guestfs.err)"

check 'Windows asennettiin NVMe-levylle' "virt-ls -a nvme.qcow2 /Windows/System32/config 2>/dev/null | grep -q '^SYSTEM$'"
check 'Jalkiasennus valmis (tila.json)' "python3 -c \"import json,sys; d=json.load(open('out/Logs/tila.json',encoding='utf-8-sig')); sys.exit(0 if d.get('Valmis') else 1)\""
check 'Tyhjennystodistus: molemmat levyt HYVAKSYTTY' "[ \$(cat out/Reports/tyhjennystodistus-*.txt 2>/dev/null | grep -c 'Varmistus:    HYVAKSYTTY') -eq 2 ]"
check 'Yhteenveto kirjoitettu' "test -s out/Reports/yhteenveto.txt"
check 'Keskeneraisen asennuksen merkki poistettu' "! virt-ls -a nvme.qcow2 /iRequire 2>/dev/null | grep -q 'ASENNUS-KESKEN.tag'"
check 'Salasanat poistettu koneelta (unattend.xml, asetukset)' "! virt-ls -a nvme.qcow2 /Windows/Panther 2>/dev/null | grep -qi '^unattend.xml$' && ! virt-ls -a nvme.qcow2 /iRequire/Config 2>/dev/null | grep -q iRequire.json"

for d in sata nvme; do
    qemu-img convert -O raw "$d.qcow2" "$d.raw"
    check "Salaista dataa ei loydy levylta ($d)" "! grep -a -q '$SECRET' $d.raw"
    rm -f "$d.raw"
done

if [ -f out/Reports/yhteenveto.txt ]; then echo '----- yhteenveto.txt -----'; cat out/Reports/yhteenveto.txt; fi
for f in out/Reports/tyhjennystodistus-*.txt; do [ -f "$f" ] && { echo "----- $(basename "$f") -----"; cat "$f"; }; done

if [ "$fail" -ne 0 ]; then log "PAASTA PAAHAN -TESTI EPAONNISTUI"; exit 1; fi
log "PAASTA PAAHAN -TESTI LAPI"
