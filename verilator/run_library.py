#!/usr/bin/env python3
"""Run every .VZ snapshot under a directory headless and collect screenshots.

  ./run_library.py ../software/mister11 --filter games -j 8 --frames 900 --out library_results/run1

Per file: download at frame 100 (--vz-frame), type RUN for BASIC (type F0)
snapshots (binary F1 ones autostart), screenshots at --shots, final text
screen. Files are de-duplicated by SHA-1. Writes report.md + results.json and
classifies each run:
  ok        picture changes between the last two shots
  static    picture identical in the last two shots (waiting for a key, or hung)
  ready     ended at a BASIC READY prompt (BASIC program stopped / error)
  error     ?SYNTAX ERROR etc. on the text screen
  crash     simulator exited non-zero / timeout
--keys FRAME:TEXT and --joy FRAME:HEX are passed to every run.
"""
import argparse, concurrent.futures as cf, hashlib, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.join(HERE, 'obj_hl', 'Vemu')


def one(path, args, outdir):
    with open(path, 'rb') as f:
        data = f.read()
    kind = data[21] if len(data) > 23 else 0
    name = re.sub(r'[^A-Za-z0-9_.-]', '_', os.path.relpath(path, args.root))[-80:]
    shots = [int(x) for x in args.shots.split(',')] + [args.frames]
    cmd = [SIM, '--quiet', '--stop-at-frame', str(args.frames), '--vz', f'{path}@{args.vz_frame}',
           '--screenshot', ','.join(map(str, shots)), '--screenshot-dir', outdir,
           '--screenshot-prefix', name, '--hash-at', ','.join(map(str, shots)), '--screen-text-end']
    if kind == 0xF0:
        cmd += ['--send-keys', f'{args.vz_frame + 30}:RUN\\n']
    for k in args.keys:
        cmd += ['--send-keys', k]
    for j in args.joy:
        cmd += ['--joy', j]
    cmd += args.extra
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=args.timeout, cwd=HERE)
        out, rc = p.stdout, p.returncode
    except subprocess.TimeoutExpired:
        out, rc = '', -1
    hashes = re.findall(r'FBHASH frame (\d+) (\w+)', out)
    text = out.split('TEXT frame', 1)[1].split('\n', 1)[1].split('----')[0] if 'TEXT frame' in out else ''
    if rc != 0:
        status = 'crash'
    elif re.search(r'\?\w+ ERROR', text):
        status = 'error'
    elif text.rstrip().endswith('READY'):
        status = 'ready'
    elif len(hashes) >= 2 and hashes[-1][1] == hashes[-2][1]:
        status = 'static'
    else:
        status = 'ok'
    return {'file': path, 'name': name, 'type': {0xF0: 'BASIC', 0xF1: 'MCODE'}.get(kind, hex(kind)),
            'status': status, 'hashes': hashes, 'text': text,
            'shots': [f'{name}_{s:05d}.png' for s in shots]}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('root')
    ap.add_argument('--filter', default='', help='regex on the path (case-insensitive)')
    ap.add_argument('--frames', type=int, default=900)
    ap.add_argument('--shots', default='300,600')
    ap.add_argument('--vz-frame', type=int, default=100)
    ap.add_argument('--keys', action='append', default=[])
    ap.add_argument('--joy', action='append', default=[])
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('-j', type=int, default=os.cpu_count() // 2)
    ap.add_argument('--timeout', type=int, default=1800)
    ap.add_argument('--out', default='library_results/run')
    ap.add_argument('extra', nargs='*', help='extra Vemu args after --')
    args = ap.parse_args()
    if not os.path.exists(SIM):
        sys.exit('build first: make headless')
    files, seen = [], set()
    rx = re.compile(args.filter, re.I)
    for d, _, fs in os.walk(args.root):
        for f in sorted(fs):
            p = os.path.join(d, f)
            if not f.lower().endswith('.vz') or not rx.search(p):
                continue
            h = hashlib.sha1(open(p, 'rb').read()).hexdigest()
            if h not in seen:
                seen.add(h); files.append(os.path.abspath(p))
    if args.limit:
        files = files[:args.limit]
    os.makedirs(args.out, exist_ok=True)
    outdir = os.path.abspath(args.out)
    print(f'{len(files)} unique .vz files, -j {args.j}')
    res = []
    with cf.ThreadPoolExecutor(args.j) as ex:
        for r in ex.map(lambda p: one(p, args, outdir), files):
            print(f"{r['status']:7} {r['type']:5} {r['file']}")
            res.append(r)
    json.dump(res, open(os.path.join(outdir, 'results.json'), 'w'), indent=1)
    counts = {}
    for r in res:
        counts[r['status']] = counts.get(r['status'], 0) + 1
    with open(os.path.join(outdir, 'report.md'), 'w') as f:
        f.write('# Library run\n\n' + ', '.join(f'{k}: {v}' for k, v in sorted(counts.items())) + '\n\n')
        f.write('| status | type | file | last shot |\n|---|---|---|---|\n')
        for r in sorted(res, key=lambda r: (r['status'], r['file'])):
            f.write(f"| {r['status']} | {r['type']} | {os.path.relpath(r['file'], args.root)} | ![]({r['shots'][-1]}) |\n")
    print(counts, '->', os.path.join(outdir, 'report.md'))


if __name__ == '__main__':
    main()
