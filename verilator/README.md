# Laser 310 / VZ200 Verilator simulation

Two builds share `sim.v` (the `emu` stand-in) and the RTL:

```bash
cd verilator
make              # old ImGui/SDL GUI           -> obj_dir/Vemu
make headless     # scriptable, no SDL/ImGui    -> obj_hl/Vemu
make headless TRACE=1   # + --trace-from/--trace-to (FST)
```

Run from `verilator/` (ROM `.hex` init files are relative; the binary also
finds them from its own location). `./obj_hl/Vemu --help` lists every option.

## Headless examples

```bash
# boot, check the prompt, screenshot
./obj_hl/Vemu --stop-at-frame 80 --expect-text 80:READY --screenshot-end

# type a line (VZ layout: " is Shift+2 etc.) and check the answer
./obj_hl/Vemu --stop-at-frame 220 --send-keys '70:PRINT 2+3*7\n' --expect-text 220:' 23'

# .VZ snapshot at frame 100, RUN it, PNG every 100 frames
./obj_hl/Vemu --vz game.vz@100 --send-keys '130:RUN\n' --stop-at-frame 900 --screenshot-every 100 --screenshot-dir out

# mount a tape in the core's Tape slot and CLOAD it (the deck starts by itself,
# 3x), check the hints, then compare RAM with the matching .vz
./obj_hl/Vemu --tape flappy.cas --send-keys '80:CLOAD\n' --stop-at-frame 1300 \
    --expect-tape-hint 60:crun --expect-bar 400:on --expect-tape-hint 1300:run \
    --dump-ram 1300:ram.bin --expect-text 1300:READY
tools/vzcmp.py ram.bin flappy.vz

# timing: lines/frame, Hz, CPU cycles per frame
./obj_hl/Vemu --stop-at-frame 20 --stats-summary
```

Output lines are prefixed for grepping: `TEXT`, `SHOT`, `FBHASH`, `STATS`,
`SUMMARY`, `EXPECT OK|FAIL`, `CPU`, `WRITE`, `OUT`, `IN`, `LATCH`, `BREAK`,
`STOP`, `TAPE`, `LOAD`, `DONE`. Exit status is 1 if any `--expect-*` failed,
2 on bad arguments / missing files.

| group | options |
|---|---|
| run | `--stop-at-frame N`, `--reset-at-frame N`, `--stop-at-pc ADDR`, `--break-pc ADDR`, `--quiet` |
| disks | `--disk1 F[@FRAME]`, `--disk2 F[@FRAME]` (S1/S2, imply `--dos-rom`), `--disk1-ro`, `--disk2-ro`, `--disk1-save F`, `--disk2-save F` (image with the core's writes, at exit); the harness serves reads and writes of 512-byte blocks like hps_io |
| OSD | `--status HEX`, `--status-bit N=V`, `--turbo` (O5), `--dos-rom` (O6), `--shrg on\|off` (O7, default On), `--sysrom F`, `--dosrom F` (sim only) |
| media | `--vz FILE[@FRAME]`, `--ioctl FRAME:INDEX:FILE`, `--tape F.cas\|F.wav` (mounted in the core's Tape slot, streamed by `rtl/vz_tape.sv`), `--tape-mount-frame N`, `--sd-latency CLOCKS`, `--tape-rewind FRAME`; tape OSD rows as `--status-bit` 12 (Speed Normal), 13 (Overlay Off), 14 (Audio On), 16 (Deck Play), 17 (Polarity Inverted), 18-19 (Pitch: 0 Auto default, 1 Normal, 2 +6%, 3 +12%); `--tape-direct F` bypasses the player (harness comparator, with `--tape-frame/--tape-speed/--tape-threshold/--tape-invert`) |
| input | `--send-keys FRAME:TEXT` (`\n` `\b` `\e`=BREAK `\U\D\L\R` `\^X` `\\` `\p` `\P`), `--key-hold N`, `--key-gap N`, `--hold-key FRAME:NAME:N`, `--joy FRAME:HEX`, `--joy2 FRAME:HEX` (bits 0 R 1 L 2 D 3 U 4 fire 5 arm) |
| output | `--screenshot N,..`, `--screenshot-every N`, `--screenshot-end`, `--screenshot-dir`, `--screenshot-prefix`, `--screen-text N,..`, `--screen-text-every N`, `--screen-text-end`, `--hash`, `--hash-at N`, `--dump-ram FRAME:F` (64 KB CPU view), `--dump-vram FRAME:F` (8 KB), `--tape-out F.wav` (latch bit 2), `--audio-out F.wav` (the core's signed AUDIO_L), `--wav-rate HZ`, `--stats`, `--stats-summary` |
| debug | `--watch LO-HI`, `--io-log`, `--cpu-log-from N --cpu-log-to N`, `--trace-from/--trace-to/--trace-file` (TRACE=1 build) |
| checks | `--expect-text FRAME:TEXT`, `--expect-no-text FRAME:TEXT`, `--expect-mem FRAME:ADDR=HEX`, `--expect-hash FRAME:HASH`, `--expect-latch FRAME:VAL[/MASK]` (6800h latch: bit 3 MODE(1), 4 CSS, 2 cassette out, 0/5 speaker), `--expect-hint FRAME:on\|off` (.VZ load hint, `rtl/vz_overlay.sv`; OSD Load hints Off = `--status-bit 11=1`), `--expect-tape-hint FRAME:none\|crun\|run`, `--expect-bar FRAME:on\|off` |

The text screen decode (`--screen-text`, `--expect-text`) reads VRAM bank 0 as
32x16: D6=1 is normal text, D6=0 inverse (letters shown lower case), 80h-FFh
semigraphics shown as `#` (80h as space). It is only meaningful in text mode.

## Scripts

- `regression.sh [--full]`: boot, PRINT, GitHub issue #1 (7800h RAM), timing
  (PAL 312 lines / 71,136 cycles, NTSC 262 / 59,736), keyboard bit 7 = /FS (a
  generated machine-code `.vz` counts low samples with interrupts off: 18% PAL,
  12% NTSC), semigraphic colour blocks (frame hash), SOUND output swinging both ways,
  `.VZ` load + RUN (with the load hint shown, then removed by Return), hint Off,
  machine-code `.VZ` autostart, floppy `DIR` (drive 1 and 2) and write protect;
  `--full` adds CLOAD from flappy `.cas` and `.wav` with a RAM compare, `RUN` from disk,
  and `SAVE` to a blank disk then reboot, `RUN` it, and check the image. Test files come from `../software` (git-ignored); missing ones are skipped.
- `run_library.py DIR [--filter RE] [-j N] [--frames N] [--out DIR]`: every `.vz`
  under DIR (deduplicated by SHA-1), screenshots + `report.md`/`results.json`,
  classified ok / static / ready / error / crash.
- `run_disks.py DIR.. [--filter RE] [-j N]`: `DIR` of every `.dsk` (deduplicated) through
  the core's floppy controller; listed / empty / error / hang, compared with the
  software directory read of `tools/vzdsk.py`.
- `tools/vzdsk.py IMG [IMG2]`: parse a `.dsk` like MAME, sector count, checksum errors,
  directory; with two images, the sectors that differ.
- `run_tapes.py DIR [--sample N] [--filter RE] [-j N]`: CLOAD real tapes through the core's
  player; ok (ROM verified the checksum, PC 36BBh) / error (LOADING ERROR, 3711h) /
  nofile, each failure retried with Tape polarity Inverted. Uses the list from:
- `tools/vztape_scan.py DIR --csv F`: software decode of every `.wav`/`.cas` header
  (comparator + the ROM's pulse rule): first-file types for the hint, undecodable files.
- `tools/vzcmp.py RAM.bin PROG.vz`: compare a RAM dump with a `.vz` body.

## How the sim differs from the FPGA build

- CPU is `tv80s` (T80 is VHDL); its IN-port mux now matches the T80pa path.
- Tape: `rtl/vz_tape.sv` is inside `LASER310_TOP`, so the sim runs the same player
  as the FPGA; the harness only plays the MiSTer's part, serving 512-byte sectors
  after `--sd-latency` clocks. `cass_in` (ORed with the player) is the old direct
  path for `--tape-direct`. Keyboard bit 6 = `~(cass_in | player)`.
- The 6847 runs on the real 14.318 MHz enable in sim too (it used to run 3x
  fast under `VERILATOR`; define `SIM_FAST_VIDEO` for the old behaviour).
- Power-on: Verilator starts all registers at 0, so the harness pulses reset
  once to give the async resets an edge (otherwise the tv80 never resets).
- Measured: PAL (default, status bit 20 = 0) 853,632 clocks/frame = 50.320 Hz,
  312 lines, 71,136 CPU cycles/frame; NTSC (`--status-bit 20=1`) 716,832 clocks =
  59.923 Hz, 262 lines, 59,736 cycles. 228 CPU cycles (456 pixel clocks) per line,
  256x192 picture. /INT and keyboard bit 7 = 6847 /FS: low 57 lines PAL, 32 NTSC.
  (Before: 466 pixel clocks per line, NTSC only, 58.637 Hz, INT on the 2-line vsync.)
- Machine-code (`F1`) `.vz` autostart: the loader holds `dirset` on the tv80.
  The tv80 used to load only PC while its T-state machine kept running, so it
  resumed mid-instruction (Soundfx.vz started at 7B22 instead of 7B00). `dirset`
  now holds the core at M1/T1 with PC=start, SP=B7BBh and interrupts off,
  matching what `z80_regset` gives the T80pa through `DIR` (other registers are
  left as they were; T80pa sets A=01h, F=00h). Regression test `vz-mcode`.
  `tv80s` also drops the bus cycle it was frozen in while `dirset` is high: if the
  loader stopped the CPU inside a memory write (a PUSH in the interrupt handler),
  that write used to land at the start address and corrupt the program's first byte.
- The GUI build (`make`) doesn't build with Verilator 5: it bundles Verilator 4
  headers in `sim/vinc` and doesn't find the SDL2 headers. Use `make headless`.
