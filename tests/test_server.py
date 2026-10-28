#!/usr/bin/env python3
"""The processing server the app's "Process World" talks to (ai-kit/splat/server.py): auth,
validation, a full job on the synthetic scan (tiny settings, CPU), and downloading the World.

usage: test_server.py <out-dir>   (needs torch in this interpreter; run.sh runs it with TORCH_PYTHON)
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, '..', 'ai-kit', 'splat', 'server.py')
OUT = sys.argv.pop(1) if len(sys.argv) > 1 else os.path.join(HERE, 'out')
TOKEN = 'test-token-123'


def call(url, data=None, token=TOKEN, method=None):
    req = urllib.request.Request(url, data=data, method=method or ('POST' if data is not None else 'GET'))
    if token:
        req.add_header('Authorization', f'Bearer {token}')
    if data is not None:
        req.add_header('Content-Type', 'application/zip')
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


class Server(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.mkdtemp()
        # tiny training so the whole job takes a minute on a CPU
        cls.proc = subprocess.Popen([sys.executable, SERVER, '--port', '0', '--token', TOKEN, '--work', cls.work, '--',
                                     '--steps', '60', '--downscale', '4', '--init-points', '3000', '--sh-degree', '0',
                                     '--gen-rounds', '1', '--gen-views', '2', '--no-playcanvas'],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        line = cls.proc.stdout.readline()
        cls.base = 'http://127.0.0.1:' + re.search(r':(\d+) ', line).group(1)

    @classmethod
    def tearDownClass(cls):
        cls.proc.kill()
        cls.proc.wait()

    def test_needs_the_token(self):
        self.assertEqual(call(self.base + '/health', token=None)[0], 401)
        self.assertEqual(call(self.base + '/health', token='wrong')[0], 401)
        code, body = call(self.base + '/health')
        self.assertEqual(code, 200)
        self.assertTrue(json.loads(body)['ok'])

    def test_rejects_bad_uploads(self):
        self.assertEqual(call(self.base + '/jobs?quality=ultra', data=b'PK..')[0], 400)
        self.assertEqual(call(self.base + '/jobs', data=b'not a zip')[0], 400)
        self.assertEqual(call(self.base + '/jobs/nope')[0], 404)

    def test_a_scan_becomes_a_world(self):
        with open(os.path.join(OUT, 'FakeHouse.zip'), 'rb') as f:
            code, body = call(self.base + '/jobs?quality=preview&fixer=classic', data=f.read())
        self.assertEqual(code, 201, body)
        jid = json.loads(body)['id']
        seen, deadline = set(), time.time() + 900
        while time.time() < deadline:
            job = json.loads(call(f'{self.base}/jobs/{jid}')[1])
            seen.add(job['step'].split(' (')[0])
            if job['state'] in ('done', 'failed'):
                break
            time.sleep(1)
        self.assertEqual(job['state'], 'done', job.get('error') or job.get('log', '')[-1500:])
        self.assertEqual(job['progress'], 1.0)
        self.assertIn('Training the splats', seen, 'progress steps reach the app')
        self.assertIn('splat.html', job['files'])
        code, html = call(f'{self.base}/jobs/{jid}/files/splat.html')
        self.assertEqual(code, 200)
        self.assertIn(b'startSplat', html)
        self.assertEqual(call(f'{self.base}/jobs/{jid}/files/..%2Fjob.json')[0], 404)
        self.assertFalse(os.path.exists(os.path.join(self.work, jid, 'scan.zip')), 'the upload is deleted after the job')


if __name__ == '__main__':
    unittest.main(verbosity=1)
