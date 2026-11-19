#!/usr/bin/env python3
"""Corpus check for VZ tapes (.wav / .cas): decode the file headers in software.

  tools/vztape_scan.py ../software [--csv out.csv]

For each tape: comparator (sample > +4% of full scale, as MAME vtech1.cpp and
the core's tape input), then the ROM's bit rule (TAPE_READ_BIT 378Fh: after a
clock pulse, one more pulse in the bit cell = 1, none = 0), then the header
the ROM's TAPE_FIND_PROGRAM (35E1h) looks for: 80h leader, 5 x FEh, type
(F0 BASIC, F1 machine code, F2 data), name up to 00h, start, end. Reports the
type of every file found, so the core's next-step hint can be checked against
the corpus (tape-standard rule 12/25). Decoding uses pulse spacing, not the
ROM's exact loop timing, so it is a corpus statistic, not a proof.
"""
import os, struct, sys, argparse

def wav_levels(b):
    if b[:4] != b'RIFF' or b[8:12] != b'WAVE':
        return None, 0
    p = 12; fmt = ch = bits = rate = 0; data = None
    while p + 8 <= len(b):
        cid = b[p:p+4]; sz = struct.unpack('<I', b[p+4:p+8])[0]
        if cid == b'fmt ':
            fmt, ch, rate = struct.unpack('<HHI', b[p+8:p+16]); bits = struct.unpack('<H', b[p+22:p+24])[0]
        elif cid == b'data':
            data = b[p+8:p+8+sz]; break
        p += 8 + sz + (sz & 1)
    if data is None: return None, 0
    bps = bits // 8 * ch
    n = len(data) // bps
    lv = bytearray(n)
    if fmt == 1 and bits == 8:
        for i in range(n): lv[i] = data[i*bps] > 128 + 5        # 128 + 4% of 127
    elif fmt == 1 and bits == 16:
        for i in range(n):
            v = data[i*bps] | data[i*bps+1] << 8
            lv[i] = v < 0x8000 and v > 1310
    elif fmt == 3 and bits == 32:
        for i in range(n): lv[i] = struct.unpack_from('<f', data, i*bps)[0] > 0.04
    else:
        return None, 0
    return lv, rate

def cas_levels(d):
    # same waveform as the sim and the core (MAME vt_cas.cpp): 6 samples per bit at 3600 Hz
    s = bytearray(800)
    nul = False
    for c in d:
        for i in range(7, -1, -1):
            s += bytes([1, 0, 1, 0, 1, 0] if (c >> i) & 1 else [1, 0, 1, 1, 0, 0])
        if not nul and c == 0: s += bytes(12); nul = True
    return s, 3600

def bits_from(lv, rate, invert=False):
    """rising edges -> bits. unit = 1/3 of a 600 baud bit cell."""
    unit = rate / 1800.0
    rises = []; prev = 1 if invert else 0
    for i, v in enumerate(lv):
        v = v ^ invert
        if v and not prev: rises.append(i)
        prev = v
    out = []; k = 0
    while k + 2 < len(rises):
        a = rises[k+1] - rises[k]
        if a > 2.6 * unit: k += 1; continue                      # gap: resync
        b = rises[k+2] - rises[k+1]
        if b > 1.5 * unit: out.append(0); k += 2                   # a long space (or a gap) ends a 0
        else: out.append(1); k += 3
    return out

def files_in(bits):
    files = []; i = 0; n = len(bits)
    while i + 8 <= n:
        v = 0
        for j in range(8): v = v << 1 | bits[i+j]
        if v != 0x80: i += 1; continue
        # aligned on a leader byte: skip leaders
        def byte(at):
            r = 0
            for j in range(8): r = r << 1 | bits[at+j]
            return r
        while i + 8 <= n and byte(i) == 0x80: i += 8
        if i + 8 * 6 > n: break
        if all(byte(i + 8*j) == 0xFE for j in range(5)):
            i += 40; t = byte(i); i += 8
            name = bytearray()
            while i + 8 <= n and len(name) < 18:
                c = byte(i); i += 8
                if c == 0: break
                name.append(c)
            if i + 32 <= n:
                st = byte(i) | byte(i+8) << 8; en = byte(i+16) | byte(i+24) << 8
                files.append((t, name.decode('latin1'), st, en))
                i += 32 + max(0, (en - st)) * 8
            else: break
        else:
            i += 8
    return files

def scan_one(p):
    b = open(p, 'rb').read()
    if p.lower().endswith('.cas'): lv, rate = cas_levels(b)
    else: lv, rate = wav_levels(b)
    if lv is None: return (p, 'unsupported', '')
    fl = files_in(bits_from(lv, rate)); pol = 'normal'
    if not fl:
        fl = files_in(bits_from(lv, rate, True)); pol = 'inverted'
    if not fl: return (p, 'no header', '')
    return (p, pol, ' '.join('%02X:%s:%04X-%04X' % f for f in fl))

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('root'); ap.add_argument('--csv'); ap.add_argument('--limit', type=int, default=0)
    a = ap.parse_args()
    paths = []
    for d, _, fs in os.walk(a.root):
        for f in sorted(fs):
            if f.lower().endswith(('.wav', '.cas')): paths.append(os.path.join(d, f))
    if a.limit: paths = paths[:a.limit]
    from collections import Counter
    from multiprocessing import Pool
    first = Counter()
    with Pool() as pool:
        rows = pool.map(scan_one, paths, chunksize=1)
    for p, pol, fl in rows:
        first[pol if not fl else (pol, fl[:2])] += 1
    for k, v in first.most_common(): print(v, k)
    if a.csv:
        with open(a.csv, 'w') as f:
            for r in rows: f.write('\t'.join(r) + '\n')

if __name__ == '__main__':
    main()
