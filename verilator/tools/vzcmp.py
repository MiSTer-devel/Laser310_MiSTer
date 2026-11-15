#!/usr/bin/env python3
"""Compare a 64 KB RAM dump (Vemu --dump-ram) with the body of a .VZ file.

usage: vzcmp.py RAM.bin PROGRAM.vz
Exit 0 when every body byte matches RAM at the .VZ start address.
"""
import sys

ram = open(sys.argv[1], 'rb').read()
vz = open(sys.argv[2], 'rb').read()
kind = {0xF0: 'BASIC', 0xF1: 'MCODE'}.get(vz[21], hex(vz[21]))
start = vz[22] | vz[23] << 8
body = vz[24:]
bad = [i for i, b in enumerate(body) if start + i > 0xFFFF or ram[start + i] != b]
print(f"{sys.argv[2]}: {kind} start {start:04X} len {len(body)}: "
      f"{len(body) - len(bad)}/{len(body)} bytes match")
for i in bad[:16]:
    a = start + i
    print(f"  {a:04X}: ram {ram[a] if a < 65536 else -1:02X} vz {body[i]:02X}")
sys.exit(1 if bad else 0)
