#!/usr/bin/env python3
"""Check / list a VZ .dsk image (any of the 98560 / 99184 / 99185 ... byte variants).

  tools/vzdsk.py disk.dsk          sectors found, checksum errors, directory
  tools/vzdsk.py a.dsk b.dsk       also: which sectors differ (data)

Parses like MAME vtech_dsk_format::load: each sector is a header mark
00 FE E7 18 C3, track, sector, track+sector, then a data mark 00 C3 18 E7 FE,
128 data bytes and their 16-bit sum (low byte first).
"""
import sys

HDR = bytes.fromhex('00fee718c3'); DAT = bytes.fromhex('00c318e7fe')


def parse(b):
    secs, bad = {}, []
    i = 0
    while True:
        i = b.find(HDR, i)
        if i < 0 or i + 8 > len(b): break
        t, s, c = b[i + 5], b[i + 6], b[i + 7]
        i += 8
        if (t + s) & 0xff != c or t >= 40: continue
        j = b.find(DAT, i)
        if j < 0 or j - i > 40: continue
        d = b[j + 5:j + 5 + 128]
        if len(d) < 128: break
        chk = b[j + 133] | b[j + 134] << 8 if j + 134 < len(b) else -1
        if chk != sum(d) & 0xffff: bad.append((t, s & 15))
        secs[(t, s & 15)] = d
        i = j + 133
    return secs, bad


def directory(secs):
    # VZ DOS: track 0 sectors 0-14 hold 8 directory entries of 16 bytes:
    # type, ':', 8-char name, track, sector, start, end
    out = []
    for s in range(15):
        d = secs.get((0, s))
        if not d: continue
        for e in range(8):
            r = d[e * 16:e * 16 + 16]
            if r[0] in (0, 1) or r[1] != ord(':'): continue
            out.append(f"{chr(r[0])}:{r[2:10].decode('latin1').rstrip()}  track {r[10]} sector {r[11]}  {r[13]<<8|r[12]:04X}-{r[15]<<8|r[14]:04X}")
    return out


def main():
    imgs = [open(f, 'rb').read() for f in sys.argv[1:]]
    for f, b in zip(sys.argv[1:], imgs):
        secs, bad = parse(b)
        print(f"{f}: {len(b)} bytes, {len(secs)}/640 sectors, {len(bad)} checksum errors {bad[:8]}")
        for l in directory(secs): print('   ', l)
    if len(imgs) == 2:
        a, _ = parse(imgs[0]); b, _ = parse(imgs[1])
        diff = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
        print('sectors that differ:', diff)


if __name__ == '__main__':
    main()
