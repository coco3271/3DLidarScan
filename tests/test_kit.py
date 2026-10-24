#!/usr/bin/env python3
"""Unit checks for ai-kit/make_walkthrough.py and the bundle data the AI relies on.

usage: test_kit.py <out-dir>   (after make_fake_bundle.py / make_variants.py ran into it)
"""
import base64
import io
import json
import math
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.join(HERE, '..', 'ai-kit')
sys.path.insert(0, KIT)
import make_walkthrough as mw  # noqa: E402

OUT = sys.argv.pop(1) if len(sys.argv) > 1 else os.path.join(HERE, 'out')
BUNDLE = os.path.join(OUT, 'FakeHouse')


def build(src, *args):
    with tempfile.TemporaryDirectory() as d:
        html = os.path.join(d, 'w.html')
        subprocess.run([sys.executable, os.path.join(KIT, 'make_walkthrough.py'), src, '-o', html, *args],
                       check=True, capture_output=True)
        text = open(html, encoding='utf-8').read()
    start = text.index('<script id="data" type="application/json">') + len('<script id="data" type="application/json">')
    return json.loads(text[start:text.index('</script>', start)])


class Kit(unittest.TestCase):
    def test_finds_root_in_nested_zip_and_flat_zip_and_folder(self):
        for src in (BUNDLE + '.zip', os.path.join(OUT, 'variants', 'flat-zip.zip'), BUNDLE, OUT + '/variants/../FakeHouse'):
            b = mw.Bundle(src)
            self.assertTrue(b.has('manifest.json'), src)
            self.assertEqual(json.loads(b.read('manifest.json'))['format'], 'house-capture/5')

    def test_rejects_paths_outside_the_bundle(self):
        b = mw.Bundle(BUNDLE)
        for bad in ('../secret', '/etc/passwd', 'photos/../../x'):
            with self.assertRaises(ValueError):
                b.read(bad)

    def test_evenly_keeps_order_and_limit(self):
        self.assertEqual(mw.evenly(list(range(10)), 5), [0, 2, 4, 6, 8])
        self.assertEqual(mw.evenly([1, 2], 5), [1, 2])
        self.assertEqual(mw.evenly([1, 2, 3], 0), [1, 2, 3])

    def test_embedded_payload_is_complete(self):
        data = build(BUNDLE + '.zip')
        files = data['files']
        manifest = json.loads(base64.b64decode(files['manifest.json']))
        self.assertIn(manifest['mesh']['file'], files)
        self.assertIn(manifest['structure'], files)
        for room in manifest['rooms']:
            self.assertIn(room['file'], files)
        photos = json.loads(base64.b64decode(files['photos/photos.json']))
        self.assertTrue(photos and all(p['manual'] for p in photos), 'tour = the shutter photos')
        for p in photos:
            self.assertIn(p['file'], files)
        for f in json.loads(base64.b64decode(files['depth/frames.json'])):
            for key in ('file', 'confidence', 'rgb'):
                self.assertIn(f[key], files)
        self.assertTrue(base64.b64decode(data['viewer']).startswith(b'//'))
        self.assertGreater(len(base64.b64decode(data['three'])), 100_000)

    def test_limits_and_downscaling(self):
        data = build(BUNDLE, '--max-photos', '2', '--max-depth-frames', '5', '--photo-edge', '200')
        photos = json.loads(base64.b64decode(data['files']['photos/photos.json']))
        frames = json.loads(base64.b64decode(data['files']['depth/frames.json']))
        self.assertEqual((len(photos), len(frames)), (2, 5))
        from PIL import Image
        with Image.open(io.BytesIO(base64.b64decode(data['files'][photos[0]['file']]))) as im:
            self.assertLessEqual(max(im.size), 200)
            self.assertEqual(im.getexif().get(0x0112), 6, 'EXIF orientation survives downscaling')

    def test_html_cannot_be_broken_by_script_tags_in_names(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, 'b')
            import shutil
            shutil.copytree(BUNDLE, src)
            m = json.load(open(os.path.join(src, 'manifest.json')))
            m['property']['name'] = 'Evil </script><script>alert(1)</script>'
            json.dump(m, open(os.path.join(src, 'manifest.json'), 'w'))
            data = build(src)
            self.assertIn('alert(1)', json.loads(base64.b64decode(data['files']['manifest.json']))['property']['name'])

    def test_pose_fields_match_transforms(self):
        # what the app writes as `pose` must be exactly the transform, unpacked
        for p in json.load(open(os.path.join(BUNDLE, 'photos/photos.json'))):
            t, pose = p['transform'], p['pose']
            self.assertEqual([round(v, 5) for v in pose['position']], [round(v, 5) for v in t[12:15]])
            f = [-t[8], -t[9], -t[10]]
            self.assertAlmostEqual(pose['yaw'], math.degrees(math.atan2(-f[0], -f[2])), places=3)
            self.assertTrue(os.path.exists(os.path.join(BUNDLE, p['depthFrame'])), 'every photo has its LiDAR frame')

    def test_rejects_non_house_capture_bundles(self):
        with tempfile.TemporaryDirectory() as d:
            z = os.path.join(d, 'x.zip')
            with zipfile.ZipFile(z, 'w') as f:
                f.writestr('scan/manifest.json', json.dumps({'format': 'something-else'}))
            r = subprocess.run([sys.executable, os.path.join(KIT, 'make_walkthrough.py'), z, '-o', os.path.join(d, 'o.html')],
                               capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('unsupported bundle format', r.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=1)
