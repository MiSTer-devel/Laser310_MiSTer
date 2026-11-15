#!/usr/bin/env python3
"""DIR every .dsk image through the core's floppy controller (rtl/vz_floppy.sv).

  ./run_disks.py ../software -j 10 --out library_results/disks
  ./run_disks.py ../software --filter extbasic --frames 600

Per image (deduplicated by SHA-1): boot VZ DOS with the image in drive 1, type
DIR at frame 120, read the text screen at --frames. Outcome:
  listed    DIR printed at least one file (T:NAME / B:NAME ...) and READY
  empty     READY right after DIR, no files
  error     a ?... ERROR message (DISK I/O ERROR etc.)
  hang      no READY after DIR (still reading)
Compares the files listed with tools/vzdsk.py's software read of the
directory. Writes report.md + results.json.
"""
import argparse, concurrent.futures as cf, glob, hashlib, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.join(HERE, 'obj_hl', 'Vemu')
sys.path.insert(0, os.path.join(HERE, 'tools'))
import vzdsk


def one(path, args):
    cmd = [SIM, '--quiet', '--disk1', path, '--send-keys', '120:DIR\\n', '--stop-at-frame', str(args.frames), '--screen-text-end']
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=args.timeout, cwd=HERE).stdout
    except subprocess.TimeoutExpired:
        return {'file': path, 'status': 'timeout'}
    text = out.split('TEXT frame', 1)[1].split('\n', 1)[1].split('----')[0] if 'TEXT frame' in out else ''
    after = text.split('DIR\n', 1)[1] if 'DIR\n' in text else text   # a long listing scrolls DIR off the screen
    files = re.findall(r'^([A-Z]):(\S.*)$', after, re.M)
    secs, bad = vzdsk.parse(open(path, 'rb').read())
    sw = [l.split('  ')[0] for l in vzdsk.directory(secs)]
    if re.search(r'\?[A-Z ]*ERROR', after): st = 'error'
    elif not after.strip().endswith('READY'): st = 'hang'
    elif files: st = 'listed'
    else: st = 'empty'
    return {'file': path, 'status': st, 'files': [f'{a}:{b.strip()}' for a, b in files], 'sw_files': sw,
            'sectors': len(secs), 'size': os.path.getsize(path), 'text': after.strip()[:400]}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('root', nargs='+')
    ap.add_argument('--filter', default='')
    ap.add_argument('--frames', type=int, default=700)
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('-j', type=int, default=max(1, os.cpu_count() // 2))
    ap.add_argument('--timeout', type=int, default=1800)
    ap.add_argument('--out', default=os.path.join(HERE, 'library_results', 'disks'))
    args = ap.parse_args()
    if not os.path.exists(SIM): sys.exit('build first: make headless')
    rx = re.compile(args.filter, re.I)
    seen, items = set(), []
    for r in args.root:
        for p in sorted(glob.glob(os.path.join(r, '**', '*'), recursive=True)):
            if not p.lower().endswith('.dsk') or not rx.search(p) or not os.path.isfile(p): continue
            h = hashlib.sha1(open(p, 'rb').read()).hexdigest()
            if h in seen: continue
            seen.add(h); items.append(os.path.abspath(p))
    if args.limit: items = items[:args.limit]
    os.makedirs(args.out, exist_ok=True)
    print(f'{len(items)} images, -j {args.j}', flush=True)
    res = []
    with cf.ThreadPoolExecutor(args.j) as ex:
        for r in ex.map(lambda p: one(p, args), items):
            n = len(r.get('files', [])); m = len(r.get('sw_files', []))
            print(f"{r['status']:7} {n:3}/{m:<3} {r.get('size', 0):7} {os.path.relpath(r['file'], HERE)}", flush=True)
            res.append(r)
    json.dump(res, open(os.path.join(args.out, 'results.json'), 'w'), indent=1)
    from collections import Counter
    c = Counter(r['status'] for r in res)
    with open(os.path.join(args.out, 'report.md'), 'w') as f:
        f.write('# Disk sweep (DIR)\n\n' + ', '.join(f'{k}: {v}' for k, v in sorted(c.items())) + '\n\n')
        f.write('| status | files (core / software) | sectors | size | image |\n|---|---|---|---|---|\n')
        for r in sorted(res, key=lambda r: (r['status'], r['file'])):
            f.write(f"| {r['status']} | {len(r.get('files', []))} / {len(r.get('sw_files', []))} | {r.get('sectors', '')} | {r.get('size', '')} | {os.path.relpath(r['file'], HERE)} |\n")
    print(dict(c), '->', os.path.join(args.out, 'report.md'))


if __name__ == '__main__':
    main()
