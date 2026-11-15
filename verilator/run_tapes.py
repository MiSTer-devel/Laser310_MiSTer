#!/usr/bin/env python3
"""Load real tapes through the core's tape player (rtl/vz_tape.sv) with CLOAD.

  ./run_tapes.py ../software --sample 40 -j 12 --out library_results/tapes1
  ./run_tapes.py ../software --filter flappy

Per tape: mount it in the Tape slot, type CLOAD at frame 80; the deck starts by
itself and runs at 3x. Outcome, from the BASIC ROM:
  ok        the ROM verified the first file's checksum (PC 36BBh)
  error     LOADING ERROR (PC 3711h): the ROM found a file but the bytes were wrong
  nofile    no file found before the tape ended (still WAITING)
Every failure is run again with Tape polarity: Inverted (--retry-inverted).
Tapes come from tools/vztape_scan.py's list (--scan; only tapes it found a header
in). Writes report.md + results.json.
"""
import argparse, concurrent.futures as cf, json, os, random, re, struct, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.join(HERE, 'obj_hl', 'Vemu')


def seconds(path):
    with open(path, 'rb') as f:
        b = f.read(4096)
    size = os.path.getsize(path)
    if b[:4] != b'RIFF':
        return size * 48 / 3600 + 1
    p = 12; rate = 22050; bpf = 1
    while p + 8 <= len(b):
        cid = b[p:p+4]; sz = struct.unpack('<I', b[p+4:p+8])[0]
        if cid == b'fmt ':
            _, ch, rate = struct.unpack('<HHI', b[p+8:p+16]); bits = struct.unpack('<H', b[p+22:p+24])[0]
            bpf = max(1, bits // 8 * ch)
        if cid == b'data':
            return min(sz, size - p - 8) / (rate * bpf)
        p += 8 + sz + (sz & 1)
    return size / 22050


def run(path, invert, args):
    secs = seconds(path)
    frames = int(80 + 30 + secs * 60 / 3 * 1.15 + 120)       # 3x, with margin (1x for >100 kB/s WAVs: see below)
    if path.lower().endswith('.wav'):
        with open(path, 'rb') as f: b = f.read(64)
        try:
            i = b.index(b'fmt '); _, ch, rate = struct.unpack('<HHI', b[i+8:i+16]); bits = struct.unpack('<H', b[i+22:i+24])[0]
            if rate * bits // 8 * ch > 100000: frames = int(80 + 30 + secs * 60 * 1.1 + 120)
        except ValueError: pass
    frames = min(frames, args.max_frames)
    cmd = [SIM, '--quiet', '--tape', path, '--send-keys', '80:CLOAD\\n', '--stop-at-pc', '36BB',
           '--break-pc', '3711', '--stop-at-frame', str(frames), '--screen-text-end']
    if invert: cmd += ['--status-bit', '17=1']
    if args.pitch: cmd += ['--status-bit', f'18={args.pitch & 1}', '--status-bit', f'19={args.pitch >> 1}']
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=args.timeout, cwd=HERE).stdout
    except subprocess.TimeoutExpired:
        return 'timeout', 0, ''
    m = re.search(r'STOP pc=36BB frame (\d+)', out)
    if m: return 'ok', int(m.group(1)), ''
    text = out.split('TEXT frame', 1)[1] if 'TEXT frame' in out else ''
    if 'BREAK pc=3711' in out: return 'error', frames, text
    return 'nofile', frames, text


def one(item, args):
    path, first = item
    st, fr, text = run(path, False, args)
    r = {'file': path, 'first': first, 'normal': st, 'frame': fr}
    if st != 'ok' and args.retry_inverted:
        st2, fr2, _ = run(path, True, args)
        r['inverted'] = st2; r['frame_inv'] = fr2
    return r


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('root')
    ap.add_argument('--scan', default=os.path.join(HERE, 'library_results', 'tape_scan.tsv'))
    ap.add_argument('--filter', default='')
    ap.add_argument('--sample', type=int, default=0, help='random sample of N tapes (seeded)')
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--max-frames', type=int, default=6000)
    ap.add_argument('--pitch', type=int, default=0, help='OSD Tape pitch index: 0 Auto (default), 1 Normal, 2 +6%%, 3 +12%%')
    ap.add_argument('--no-retry', dest='retry_inverted', action='store_false')
    ap.add_argument('-j', type=int, default=max(1, os.cpu_count() // 2))
    ap.add_argument('--timeout', type=int, default=7200)
    ap.add_argument('--out', default=os.path.join(HERE, 'library_results', 'tapes'))
    args = ap.parse_args()
    if not os.path.exists(SIM): sys.exit('build first: make headless')
    root = os.path.abspath(args.root); rx = re.compile(args.filter, re.I)
    items, seen = [], set()
    for line in open(args.scan):
        f = line.rstrip('\n').split('\t')
        if len(f) < 3 or not f[2]: continue
        p = os.path.abspath(os.path.join(HERE, f[0])) if not os.path.isabs(f[0]) else f[0]
        if not p.startswith(root) or not rx.search(p) or not os.path.exists(p): continue
        key = (os.path.getsize(p), f[2])
        if key in seen: continue                      # same tape in two folders
        seen.add(key); items.append((p, f[2].split(' ')[0]))
    if args.sample and args.sample < len(items):
        items = random.Random(args.seed).sample(items, args.sample)
    os.makedirs(args.out, exist_ok=True)
    print(f'{len(items)} tapes, -j {args.j}')
    res = []
    with cf.ThreadPoolExecutor(args.j) as ex:
        for r in ex.map(lambda it: one(it, args), items):
            print(f"{r['normal']:7} {r.get('inverted', ''):7} {r['first'][:40]:40} {os.path.relpath(r['file'], root)}", flush=True)
            res.append(r)
    json.dump(res, open(os.path.join(args.out, 'results.json'), 'w'), indent=1)
    from collections import Counter
    c = Counter((r['normal'], r.get('inverted', '-')) for r in res)
    with open(os.path.join(args.out, 'report.md'), 'w') as f:
        f.write('# Tape sweep (CLOAD, 3x)\n\n| normal | inverted | tapes |\n|---|---|---|\n')
        for (a, b), n in c.most_common(): f.write(f'| {a} | {b} | {n} |\n')
        f.write('\n| normal | inverted | first file | tape |\n|---|---|---|---|\n')
        for r in sorted(res, key=lambda r: (r['normal'], r['file'])):
            f.write(f"| {r['normal']} | {r.get('inverted', '')} | {r['first']} | {os.path.relpath(r['file'], root)} |\n")
    print(dict(c), '->', os.path.join(args.out, 'report.md'))


if __name__ == '__main__':
    main()
