#!/bin/bash
# Headless regression for the Laser 310 core.
#   ./regression.sh          quick set (~1-2 min CPU)
#   ./regression.sh --full   adds the tape loads through rtl/vz_tape.sv (CLOAD of flappy .cas/.wav, CRUN of a machine-code WAV)
# Needs `make headless`. Test programs come from ../software (git-ignored, local only);
# tests whose file is missing are skipped, not failed.
cd "$(dirname "$0")"
SIM=./obj_hl/Vemu
SW=../software
OUT=${OUT:-regression_out}
FULL=0; [ "$1" = "--full" ] && FULL=1
mkdir -p "$OUT"
[ -x $SIM ] || { echo "build first: make headless"; exit 2; }

pass=0; fail=0; skip=0
run() {   # name, then Vemu args
    local name=$1; shift
    if "$SIM" --quiet --screenshot-end --screenshot-dir "$OUT" --screenshot-prefix "$name" "$@" > "$OUT/$name.log" 2>&1; then
        echo "PASS $name"; pass=$((pass+1))
    else
        echo "FAIL $name   (see $OUT/$name.log)"; grep "EXPECT FAIL" "$OUT/$name.log" | sed 's/^/     /'; fail=$((fail+1))
    fi
}
need() { [ -f "$1" ] || { echo "SKIP $2 (missing $1)"; skip=$((skip+1)); return 1; }; }

FLAPPY=$SW/homebrew/gameblabla_flappybird_vz200

run boot      --stop-at-frame 80 --expect-text 80:"VIDEO TECHNOLOGY" --expect-text 80:"BASIC V2.0" --expect-text 80:READY
run print     --stop-at-frame 220 --send-keys '70:PRINT 2+3*7,"HI";\n' --expect-text 220:' 23' --expect-text 220:HI
# GitHub issue #1: RAM at 7800h-7FFFh must read back
run issue1    --stop-at-frame 300 --send-keys '70:POKE 32767,55:PRINT PEEK(32767)\n' --expect-text 300:' 55'
# Frame timing: 228 CPU cycles per line; PAL (default) 312 lines, NTSC (status bit 20) 262
check_timing() {   # name, expected lines, expected cpu cycles per frame
    run $1 --stop-at-frame 20 --stats-summary "${@:4}"
    local l=$(grep SUMMARY "$OUT/$1.log"); echo "     ${l#SUMMARY }"
    echo "$l" | grep -q "lines $2.00 cpu_cycles $3.0 " || { echo "FAIL $1: want $2 lines, $3 cycles"; fail=$((fail+1)); }
}
check_timing timing      312 71136
check_timing timing-ntsc 262 59736 --status-bit 20=1
# Keyboard bit 7 = 6847 /FS. A tiny machine-code .VZ (DI, then 65536 reads of
# 6800h) counts the samples with bit 7 low into 7A00h. Expect the /FS-low share of
# the field: PAL 57/312 lines = 18%, NTSC 32/262 = 12%. (BASIC can't see it: the
# ROM's interrupt handler is longer than the vblank, as on the real machine.)
python3 - "$OUT/fscount.vz" <<'PY'
import sys
code = bytes.fromhex('F3 210000 010000 3A0068 17 3801 23 0B 78 B1 20F4 22007A 18FE'.replace(' ', ''))
open(sys.argv[1], 'wb').write(b'VZF0' + b'FSCOUNT'.ljust(17, b'\0') + b'\xF1' + bytes([0x00, 0x7B]) + code)
PY
for std in pal ntsc; do
    a=(); [ $std = ntsc ] && a=(--status-bit 20=1)
    run vblank-bit7-$std --stop-at-frame 300 --vz "$OUT/fscount.vz@100" --dump-ram 300:$OUT/fscount-$std.ram "${a[@]}"
    python3 - $OUT/fscount-$std.ram $std <<'PY' || fail=$((fail+1))
import sys
m = open(sys.argv[1], 'rb').read(); n = m[0x7A00] | m[0x7A01] << 8
want = {'pal': 57 / 312, 'ntsc': 32 / 262}[sys.argv[2]]
print(f'     bit 7 low in {n}/65536 samples = {n / 65536:.3f} (want ~{want:.3f})')
sys.exit(0 if abs(n / 65536 - want) < 0.02 else 1)
PY
done
# Semigraphics (A/S = VRAM D7): eight colour blocks, picture hash
run semigraphics --stop-at-frame 420 --send-keys '70:FORI=0TO7:POKE28928+I*2,143+16*I:NEXT\n' --expect-hash 420:f6a6534af32e4383
# Sound: BASIC SOUND drives the speaker (latch bits 0/5); the core's signed output must swing both ways
run sound --stop-at-frame 200 --send-keys '70:SOUND 20,3\n' --audio-out $OUT/sound.wav
python3 - "$OUT/sound.wav" <<'PY' && echo "     speaker swings both ways" || { echo "FAIL sound: no +/- output"; fail=$((fail+1)); }
import sys, struct
d = open(sys.argv[1], 'rb').read()[44:]
s = struct.unpack('<%dh' % (len(d) // 2), d)
sys.exit(0 if max(s) > 4000 and min(s) < -4000 else 1)
PY
if need $FLAPPY/flappy.vz vz-basic; then
    run vz-basic  --stop-at-frame 400 --vz $FLAPPY/flappy.vz@100 --expect-mem 140:7AE9=047B0100B1 \
                  --send-keys '150:RUN\n' --expect-hint 99:off --expect-hint 140:on --expect-hint 200:off \
                  --expect-latch 400:10/18 --expect-text 400:"flappy bird"   # text mode, CSS=1, inverse title
    # OSD Load hints Off (status bit 11): no box after a BASIC load
    run hint-off  --stop-at-frame 140 --vz $FLAPPY/flappy.vz@100 --status-bit 11=1 --expect-hint 140:off
fi

SFX="$SW/mister11/everything_jan2021/Demos/1-bit audio/Soundfx.vz"
if need "$SFX" vz-mcode; then   # F1 snapshot: loader jumps to 7B00 (tv80 dirset)
    run vz-mcode  --stop-at-frame 300 --vz "$SFX@100" --expect-text 300:"SOUND EFFECTS LIBRARY" --expect-hint 300:off
fi

# Tape (rtl/vz_tape.sv): mount shows "TYPE CRUN"; Tape overlay Off hides it
if need $FLAPPY/flappy.cas tape-mount; then
    run tape-mount     --stop-at-frame 60 --tape $FLAPPY/flappy.cas --expect-tape-hint 60:crun
    run tape-overlay-off --stop-at-frame 60 --tape $FLAPPY/flappy.cas --status-bit 13=1 --expect-tape-hint 60:none
fi

# Floppy (rtl/vz_floppy.sv): VZ DOS DIR, RUN from disk, SAVE + reload, write protect
DD=../refs/emulators/zzemu-cn_LASER310_FPGA_DD20/software
BLANK=../refs/emulators/paulscottrobson_vz-next-2/vzem/blank.dsk
if need $DD/INVADERS.dsk disk-dir; then
    run disk-dir --stop-at-frame 450 --disk1 $DD/INVADERS.dsk --send-keys '120:DIR\n' --expect-text 450:'T:INVADERS'
    run disk-drive2 --stop-at-frame 600 --disk1 $BLANK --disk2 $DD/INVADERS.dsk --send-keys '120:DRIVE2\n\PDIR\n' --expect-text 600:'T:INVADERS'
fi
if need $BLANK disk-save; then
    run disk-wp --stop-at-frame 800 --disk1 $BLANK --disk1-ro --send-keys '120:10 PRINT\n\PSAVE"X"\n' --expect-text 800:'?DISK WRITE PROTECTED'
fi
if [ $FULL = 1 ]; then
    if need $DD/INVADERS.dsk disk-run; then
        run disk-run --stop-at-frame 1500 --disk1 $DD/INVADERS.dsk --send-keys '120:RUN"INVADERS"\n' --expect-text 1500:'PRESS  <S> TO START'
    fi
    if need $BLANK disk-save; then
        run disk-save --stop-at-frame 1100 --disk1 $BLANK --disk1-save $OUT/disk-save.dsk --send-keys '120:10 PRINT"SAVED OK"\n\PSAVE"TEST"\n'
        run disk-reload --stop-at-frame 900 --disk1 $OUT/disk-save.dsk --send-keys '120:DIR\n\P\PRUN"TEST"\n' --expect-text 900:'T:TEST' --expect-text 900:'SAVED OK'
        python3 tools/vzdsk.py $OUT/disk-save.dsk | grep -q " 0 checksum errors" && grep -q "99184 bytes" <(python3 tools/vzdsk.py $OUT/disk-save.dsk) \
            && echo "     saved image: same size, all checksums good" || { echo "FAIL disk-save image"; fail=$((fail+1)); }
    fi

    # CLOAD through the core's player (deck starts by itself, 3x), RAM == .vz body,
    # status bar while loading, "TYPE RUN" after, Rewind brings back "TYPE CRUN"
    for t in cas wav; do
        if need $FLAPPY/flappy.$t tape-$t; then
            run tape-$t --stop-at-frame 1400 --send-keys '80:CLOAD\n' --tape $FLAPPY/flappy.$t \
                        --expect-bar 400:on --expect-tape-hint 1300:run --tape-rewind 1310 --expect-tape-hint 1400:crun \
                        --dump-ram 1300:$OUT/tape-$t.ram --expect-text 1300:READY
            if tools/vzcmp.py $OUT/tape-$t.ram $FLAPPY/flappy.vz > $OUT/tape-$t.cmp; then
                echo "PASS tape-$t-ram"; pass=$((pass+1))
            else echo "FAIL tape-$t-ram"; sed 's/^/     /' $OUT/tape-$t.cmp | head -5; fail=$((fail+1)); fi
        fi
    done
    # machine code: CRUN starts it (bushy555 1-bit music, tested on real hardware)
    PRDRA="$SW/github_more/bushy555_VZ200_VZ300_-_1bit_music_TESTED_on_real_VZ_hardware/PRDRA_2Q.WAV"
    if need "$PRDRA" tape-crun; then
        run tape-crun --stop-at-frame 400 --tape "$PRDRA" --send-keys '80:CRUN\n' --stop-at-pc 8000 --expect-tape-hint 60:crun
        grep -q "STOP pc=8000" $OUT/tape-crun.log && echo "     started at 8000h" || { echo "FAIL tape-crun: never reached 8000h"; fail=$((fail+1)); }
    fi
fi

echo "pass $pass  fail $fail  skip $skip"
[ $fail = 0 ]
