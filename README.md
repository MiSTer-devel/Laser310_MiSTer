
This is a MiSTer port of the core by:
https://github.com/zzemu-cn/LASER310_FPGA_DD20


# VZ Loader

Load VZ snapshots - there are two types, basic images and binary images. The basic images will load, and you need to type RUN&lt;enter&gt; to start. Binary ones should start automatically.

With **Load hints** On (the default), after a BASIC snapshot loads the bottom-left corner of the picture shows the program's name (from the .VZ header) and `TYPE RUN ↵`, until you press Return. Binary snapshots start by themselves and show nothing. Turn it off in the OSD with Load hints: Off.

# Tape

Mount a `.wav` or `.cas` in the OSD **Tape** slot, then type `CLOAD` (BASIC) or `CRUN` (load and start, BASIC or machine code) and press Return. The VZ has no motor control, so the deck starts by itself when the BASIC ROM starts reading the tape and stops when it finishes; you never press play. The tape is not remembered between core starts, and every mount starts at the beginning ("Tape ready (rewound)").

- **Formats:** `.wav` 8-bit or 16-bit PCM or 32-bit float, mono or stereo (left channel), any sample rate; `.cas` (the raw tape byte stream, as MAME's `vt_cas`). Tapes stream from the SD card, so any length works.
- **Tape speed:** 3x (default) runs the CPU and the tape three times faster while the ROM loads, so a load takes a third of the time and the program then runs at normal speed. Normal plays at real speed. WAVs that need more than 100 kB/s (for example 96 kHz float) always play at 1x.
- **Tape overlay:** On (default) shows `TAPE ▶ 0:14/ 0:58 x3` and a progress bar while the tape plays, and what to type while it is stopped: `TYPE CRUN ↵` when a tape is at its start, `TYPE RUN ↵` after `CLOAD` of a BASIC program. `CRUN` is a guess the tape doesn't state: it works for BASIC (type F0) and machine-code (F1) programs, which is the first file of every tape in our test set that has a readable header. The box covers the bottom text line, where the ROM prints WAITING / LOADING, while it is shown.
- **Tape deck:** Auto (default) plays only while the ROM's tape routine runs. Play keeps the tape running whenever one is mounted, for programs with their own loaders (such as the 2018AD demo's later parts); turbo still only applies while the ROM reads.
- **Tape pitch:** Auto (default) measures each tape's speed from its leader when you mount it and plays it at the speed the ROM reads best, like setting a cassette deck's speed trim per tape. The ROM's bit timing is narrow and real recordings run a few percent fast or slow: on a 60-tape sample, Normal loads 41, a fixed +6% loads 52 but breaks some fast recordings, and Auto loads 52 plus one more with Tape polarity Inverted. Normal, +6% and +12% are fixed settings. The samples themselves are never changed, only the rate they play at.
- **Tape polarity:** Inverted flips the signal, for recordings made through an inverting player or tool.
- **Tape audio:** On mixes the tape signal into the sound quietly.
- **Rewind tape** goes back to the start.
- `CSAVE` is not supported yet.

# Video and sound

- **Video standard:** PAL (50 Hz, the default) gives the 312-line field of the VZ300 / Laser 310 and PAL VZ200: the 6847's 262-line field padded with 25 border lines above and 25 below, as the PAL machines do. NTSC (60 Hz) is the Laser 200 / NTSC VZ200 timing. Games timed by the frame interrupt run at their intended speed only with the right standard; most VZ software was written for PAL. Lines are 228 CPU cycles (59,736 cycles per frame NTSC, 71,136 PAL). The CPU clock is 3.5795 MHz in both; a real VZ300 runs 0.9% slower (3.5469 MHz), which also slows its video by the same amount.
- **Interrupt and vblank:** the Z80 interrupt and bit 7 of the keyboard port (6800h) both follow the 6847 field-sync pin, low for the vertical blanking period, as on the real machine. Games that poll bit 7 to wait for vblank (TENNIS, 3D-MAZE, BENNY) work.
- **Colour blocks:** VRAM characters 80h-FFh are the 6847's semigraphic blocks in 8 colours (bits 6-4), as used by BASIC `SET`/`COLOR` in text mode.
- **SHRG:** the Australian SHRG graphics mod (port 20h), On by default; Off gives a stock machine.
- **Sound:** the speaker is driven push-pull by latch bits 0 and 5 (three levels), as 1-bit music engines expect. With Tape audio On the tape input and the cassette output are mixed in quietly.

# Joystick Support

The original system has a left and right joystick. It is possible you may need a second joystick to play some games.


# 08-SEP-20

Added switchable 64x32 Screen mode
Added 24K VRAM mode
Fixed error with CPU reading $7800-$7FFF range
Added 6847T1 style Lower Case, requires SHRG *ON*

# 16-SEP-20

Fixed display shakiness.
Tweaked display parameters slightly.

# TODO

* cassette save (CSAVE)
* floppy support
