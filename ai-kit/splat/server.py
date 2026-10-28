#!/usr/bin/env python3
"""Processing server for the iPhone app's "Process World": receives a scan zip, runs
make_splat.py (video keyframes → Gaussian splats → generative repair → viewers) one job at a
time, and serves the results. Run it on a machine with an NVIDIA GPU.

usage: server.py [--host 0.0.0.0] [--port 8787] [--token SECRET] [--work ~/splat-jobs]
                 [-- extra make_splat.py arguments]

  POST /jobs?quality=preview|standard|high&fixer=difix|fal|openai|classic|none   body: the zip
       → 201 {"id": "..."}
  GET  /jobs/<id>            → {"state": queued|running|done|failed, "step", "progress" 0–1,
                                "position" (in the queue), "error", "files": [...], "log"}
  GET  /jobs/<id>/files/<name>   splat.html, playcanvas.html, scene.sog, scene.ply, metrics.json
  GET  /health               → {"ok": true, "gpu": "...", "queue": n}

Every request needs `Authorization: Bearer <token>` when a token is set (always set one when the
server is reachable from outside your network). The app talks to it over HTTPS: put it behind a
tunnel (e.g. `cloudflared tunnel --url http://localhost:8787` or Tailscale) rather than opening
a port.
"""
import argparse
import json
import os
import queue
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
QUALITIES = {'preview', 'standard', 'high'}
FIXERS = {'difix', 'fal', 'openai', 'classic', 'none'}
OUTPUTS = ('splat.html', 'playcanvas.html', 'scene/scene.sog', 'scene/scene.ply', 'scene/metrics.json')
# make_splat.py prints these as it goes: they tell the app how far along a job is
STEPS = [('export_dataset.py', 'Picking keyframes from the video', 0.05), ('train.py', 'Training the splats', 0.15),
         ('generative round', 'Repairing with generative AI', 0.7), ('PlayCanvas outputs', 'Packing for PlayCanvas', 0.9),
         ('make_splat_html.py', 'Building the viewer', 0.95)]


class Jobs:
    def __init__(self, work, extra):
        self.work, self.extra = work, extra
        self.lock = threading.Lock()
        self.jobs = {}
        self.q = queue.Queue()
        os.makedirs(work, exist_ok=True)
        # jobs from an earlier run of the server stay downloadable
        for jid in os.listdir(work):
            meta = os.path.join(work, jid, 'job.json')
            if os.path.exists(meta):
                with open(meta) as f:
                    j = json.load(f)
                if j['state'] in ('queued', 'running'):
                    j.update(state='failed', error='the server restarted during this job; upload it again')
                self.jobs[jid] = j
        threading.Thread(target=self.worker, daemon=True).start()

    def add(self, zip_path, quality, fixer):
        jid = secrets.token_hex(8)
        d = os.path.join(self.work, jid)
        os.makedirs(d)
        shutil.move(zip_path, os.path.join(d, 'scan.zip'))
        job = {'id': jid, 'state': 'queued', 'step': 'Waiting in line', 'progress': 0.0, 'quality': quality,
               'fixer': fixer, 'created': time.time(), 'error': None, 'files': []}
        with self.lock:
            self.jobs[jid] = job
        self.save(job)
        self.q.put(jid)
        return job

    def get(self, jid):
        with self.lock:
            job = self.jobs.get(jid)
            if not job:
                return None
            out = dict(job)
            out['position'] = sum(1 for j in self.jobs.values() if j['state'] == 'queued' and j['created'] < job['created'])
        log = os.path.join(self.work, jid, 'log.txt')
        if os.path.exists(log):
            with open(log, errors='replace') as f:
                out['log'] = f.read()[-3000:]
        return out

    def save(self, job):
        with open(os.path.join(self.work, job['id'], 'job.json'), 'w') as f:
            json.dump(job, f)

    def update(self, jid, **kw):
        with self.lock:
            self.jobs[jid].update(kw)
            job = dict(self.jobs[jid])
        self.save(job)

    def worker(self):
        while True:
            jid = self.q.get()
            d = os.path.join(self.work, jid)
            job = self.jobs[jid]
            self.update(jid, state='running', step='Starting', progress=0.01, started=time.time())
            cmd = [sys.executable, os.path.join(HERE, 'make_splat.py'), os.path.join(d, 'scan.zip'), '-o', os.path.join(d, 'out'),
                   '--quality', job['quality'], '--fixer', job['fixer']] + self.extra
            try:
                with open(os.path.join(d, 'log.txt'), 'w') as log:
                    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
                                         env=dict(os.environ, PYTHONUNBUFFERED='1'))  # live progress
                    for line in p.stdout:
                        log.write(line)
                        log.flush()
                        self.progress(jid, line)
                    p.wait()
                if p.returncode != 0:
                    raise RuntimeError(self.last_error(d))
                files = [os.path.basename(f) for f in OUTPUTS if os.path.exists(os.path.join(d, 'out', f))]
                self.update(jid, state='done', step='Done', progress=1.0, files=files, finished=time.time())
            except Exception as e:
                self.update(jid, state='failed', step='Failed', error=str(e)[-500:], finished=time.time())
            finally:
                try:  # the upload isn't needed any more; the results are
                    os.remove(os.path.join(d, 'scan.zip'))
                except OSError:
                    pass

    def progress(self, jid, line):
        for key, label, p in STEPS:
            if key in line:
                self.update(jid, step=label, progress=p)
        m = re.search(r'step (\d+)/(\d+)', line)
        if m:  # training: 15 % → 90 % of the job
            frac = int(m.group(1)) / max(1, int(m.group(2)))
            self.update(jid, step=f'Training the splats ({int(frac * 100)}%)', progress=round(0.15 + 0.75 * frac, 3))

    def last_error(self, d):
        with open(os.path.join(d, 'log.txt'), errors='replace') as f:
            lines = [l.strip() for l in f if l.strip()]
        return next((l for l in reversed(lines) if 'Error' in l or 'error' in l or l.startswith('SystemExit')), lines[-1] if lines else 'failed')

    def file(self, jid, name):
        for f in OUTPUTS:
            if os.path.basename(f) == name:
                path = os.path.join(self.work, jid, 'out', f)
                return path if os.path.exists(path) else None
        return None


def make_handler(jobs, token, max_upload):
    class Handler(BaseHTTPRequestHandler):
        server_version = 'SplatServer/1'

        def log_message(self, fmt, *args):
            sys.stderr.write('%s %s\n' % (self.address_string(), fmt % args))

        def send_json(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def authorized(self):
            if not token or secrets.compare_digest(self.headers.get('Authorization', ''), f'Bearer {token}'):
                return True
            self.send_json(401, {'error': 'wrong or missing token'})
            return False

        def do_GET(self):
            if not self.authorized():
                return
            parts = [p for p in urlparse(self.path).path.split('/') if p]
            if parts == ['health']:
                gpu = shutil.which('nvidia-smi') and subprocess.run(['nvidia-smi', '--query-gpu=name', '--format=csv,noheader'],
                                                                     capture_output=True, text=True).stdout.strip()
                return self.send_json(200, {'ok': True, 'gpu': gpu or None, 'queue': jobs.q.qsize()})
            if len(parts) == 2 and parts[0] == 'jobs':
                job = jobs.get(parts[1])
                return self.send_json(200, job) if job else self.send_json(404, {'error': 'no such job'})
            if len(parts) == 4 and parts[0] == 'jobs' and parts[2] == 'files':
                path = jobs.file(parts[1], parts[3])
                if not path:
                    return self.send_json(404, {'error': 'no such file'})
                self.send_response(200)
                self.send_header('Content-Type', {'html': 'text/html', 'json': 'application/json'}.get(path.rsplit('.', 1)[-1], 'application/octet-stream'))
                self.send_header('Content-Length', str(os.path.getsize(path)))
                self.end_headers()
                with open(path, 'rb') as f:
                    shutil.copyfileobj(f, self.wfile)
                return
            self.send_json(404, {'error': 'not found'})

        def do_POST(self):
            if not self.authorized():
                return
            url = urlparse(self.path)
            if url.path.rstrip('/') != '/jobs':
                return self.send_json(404, {'error': 'not found'})
            q = parse_qs(url.query)
            quality = q.get('quality', ['standard'])[0]
            fixer = q.get('fixer', ['difix'])[0]
            if quality not in QUALITIES or fixer not in FIXERS:
                return self.send_json(400, {'error': f'quality must be one of {sorted(QUALITIES)}, fixer one of {sorted(FIXERS)}'})
            size = int(self.headers.get('Content-Length') or 0)
            if size <= 0 or size > max_upload:
                return self.send_json(413 if size else 411, {'error': f'upload must be 1 byte–{max_upload // 10**9} GB with a Content-Length'})
            tmp = os.path.join(jobs.work, f'upload-{secrets.token_hex(6)}.zip')
            left = size
            with open(tmp, 'wb') as f:
                while left:
                    chunk = self.rfile.read(min(left, 1 << 20))
                    if not chunk:
                        break
                    f.write(chunk)
                    left -= len(chunk)
            if left:
                os.remove(tmp)
                return self.send_json(400, {'error': 'upload was cut off'})
            with open(tmp, 'rb') as f:
                if f.read(2) != b'PK':
                    os.remove(tmp)
                    return self.send_json(400, {'error': 'not a zip file'})
            job = jobs.add(tmp, quality, fixer)
            self.send_json(201, {'id': job['id']})

    return Handler


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--host', default='127.0.0.1', help='0.0.0.0 to accept other machines (set --token!)')
    ap.add_argument('--port', type=int, default=8787)
    ap.add_argument('--token', default=os.environ.get('SPLAT_TOKEN'), help='required bearer token (or env SPLAT_TOKEN)')
    ap.add_argument('--work', default=os.path.expanduser('~/splat-jobs'))
    ap.add_argument('--max-upload-gb', type=float, default=20)
    a, extra = ap.parse_known_args()
    extra = [x for x in extra if x != '--']
    if a.host not in ('127.0.0.1', 'localhost', '::1') and not a.token:
        sys.exit('refusing to listen on a public address without --token')
    jobs = Jobs(a.work, extra)
    srv = ThreadingHTTPServer((a.host, a.port), make_handler(jobs, a.token, int(a.max_upload_gb * 1e9)))
    print(f'processing server on http://{a.host}:{srv.server_port} · jobs in {a.work}' + (' · token required' if a.token else ''), flush=True)
    srv.serve_forever()


if __name__ == '__main__':
    main()
