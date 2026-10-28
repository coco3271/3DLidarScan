"""Generative fixers: turn a rough render of the splat scene into a clean, plausible image.

This is the "reconstruction as generation" step. A splat trained only on the capture looks
right where the camera looked and breaks down elsewhere (holes, floaters, smears). We render
the scene from new viewpoints, let an image model repair those renders using what it has
learned about real rooms (and the nearest real photo as reference), then train the splat on
the repaired renders too, so the 3D scene itself gets cleaner (Difix3D+, Wu et al., CVPR 2025).

  fix(render, mask, ref, prompt) -> image        all uint8 (H,W,3); mask (H,W) bool = unreliable

Providers (choose with --fixer):
  difix    NVIDIA Difix / Difix-ref, single-step diffusion made exactly for this (local, CUDA,
           ~8 GB VRAM). Repairs the whole render (floaters too), guided by the reference photo.
           Needs a clone of https://github.com/nv-tlabs/Difix3D (env DIFIX_REPO) + diffusers.
  fal      FLUX.1 Fill [pro] on fal.ai (env FAL_KEY). Fills the masked holes.
  openai   OpenAI image edits with a mask (env OPENAI_API_KEY, model gpt-image-1). Fills holes.
  classic  No AI: smooth push-pull fill of the holes. For tests and offline previews.

The API providers only fill the masked areas and leave the rest pixel-identical, so they never
move what the capture measured.
"""
import base64
import io
import json
import os
import sys
import urllib.request

import numpy as np
from PIL import Image, ImageFilter

PROMPT = ('photorealistic photo of the same interior, seamlessly continue the walls, floor, ceiling and '
          'furniture exactly as they are, natural light, no people, no text, no new objects')


def get(name):
    return {'classic': ClassicFixer, 'difix': DifixFixer, 'fal': FalFixer, 'openai': OpenAIFixer}[name]()


class ClassicFixer:
    """Push-pull inpainting: average the known pixels down a pyramid, then fill holes on the way up"""
    name = 'classic'

    def __call__(self, render, mask, ref=None, prompt=PROMPT):
        img = render.astype(np.float32)
        known = (~mask).astype(np.float32)
        out = push_pull(img, known)
        return composite(render, out.astype(np.uint8), mask)


def push_pull(img, w):
    if min(img.shape[:2]) <= 2 or w.min() > 0:
        return img
    h, wd = img.shape[:2]
    h2, w2 = (h + 1) // 2, (wd + 1) // 2
    pad = lambda a: np.pad(a, [(0, h2 * 2 - h), (0, w2 * 2 - wd)] + [(0, 0)] * (a.ndim - 2), mode='edge')
    iw, ww = pad(img * w[..., None]), pad(w)
    sw = ww.reshape(h2, 2, w2, 2).sum((1, 3))
    si = iw.reshape(h2, 2, w2, 2, 3).sum((1, 3))
    small = si / np.maximum(sw, 1e-6)[..., None]
    small = push_pull(small, np.minimum(sw, 1.0))
    # smooth (bilinear) upsampling, one channel at a time
    up = np.stack([np.asarray(Image.fromarray(small[..., c].astype(np.float32), 'F').resize((w2 * 2, h2 * 2), Image.BILINEAR))
                   for c in range(3)], -1)[:h, :wd]
    return img * w[..., None] + up * (1 - w[..., None])


def composite(original, fixed, mask, feather=4):
    """Fixed pixels inside the (feathered) mask, the original everywhere else"""
    if fixed.shape != original.shape:
        fixed = np.asarray(Image.fromarray(fixed).resize(original.shape[1::-1], Image.LANCZOS))
    m = Image.fromarray((mask * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(feather))
    a = np.asarray(m, dtype=np.float32)[..., None] / 255
    return (original * (1 - a) + fixed * a).astype(np.uint8)


class DifixFixer:
    """NVIDIA Difix(-ref): https://github.com/nv-tlabs/Difix3D, weights nvidia/difix_ref on Hugging Face"""
    name = 'difix'

    def __init__(self):
        repo = os.environ.get('DIFIX_REPO')
        if repo:
            sys.path.insert(0, os.path.join(repo, 'src'))
        try:
            import torch
            from pipeline_difix import DifixPipeline
        except ImportError as e:
            raise SystemExit('difix: clone https://github.com/nv-tlabs/Difix3D, pip install -r its requirements.txt, '
                             f'and set DIFIX_REPO to the clone ({e})')
        if not torch.cuda.is_available():
            raise SystemExit('difix needs an NVIDIA GPU (CUDA)')
        self.pipe = DifixPipeline.from_pretrained('nvidia/difix_ref', trust_remote_code=True).to('cuda')
        self.pipe.set_progress_bar_config(disable=True)

    def __call__(self, render, mask, ref=None, prompt='remove degradation'):
        h, w = render.shape[:2]
        # Difix works on 512-ish images with sides divisible by 8
        s = 576 / max(h, w)
        size = (max(8, round(w * s / 8) * 8), max(8, round(h * s / 8) * 8))
        img = Image.fromarray(render).resize(size, Image.LANCZOS)
        kw = {'ref_image': Image.fromarray(ref).resize(size, Image.LANCZOS)} if ref is not None else {}
        out = self.pipe('remove degradation', image=img, num_inference_steps=1, timesteps=[199], guidance_scale=0.0, **kw).images[0]
        out = np.asarray(out.convert('RGB').resize((w, h), Image.LANCZOS))
        # Difix repairs the whole frame (floaters, blur), not only the holes: keep all of it
        return out


def _png_data_uri(arr):
    buf = io.BytesIO()
    Image.fromarray(arr).save(buf, 'PNG')
    return 'data:image/png;base64,' + base64.b64encode(buf.getvalue()).decode()


def _http(url, body, headers, timeout=180):
    req = urllib.request.Request(url, data=body, headers=headers, method='POST')
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def _image_from(url_or_data):
    if url_or_data.startswith('data:'):
        data = base64.b64decode(url_or_data.split(',', 1)[1])
    else:
        with urllib.request.urlopen(url_or_data, timeout=120) as r:
            data = r.read()
    return np.asarray(Image.open(io.BytesIO(data)).convert('RGB'))


class FalFixer:
    """FLUX.1 Fill [pro] on fal.ai: https://fal.ai/models/fal-ai/flux-pro/v1/fill"""
    name = 'fal'

    def __init__(self):
        self.key = os.environ.get('FAL_KEY')
        if not self.key:
            raise SystemExit('fal: set FAL_KEY (https://fal.ai/dashboard/keys)')

    def __call__(self, render, mask, ref=None, prompt=PROMPT):
        if not mask.any():
            return render
        m = np.repeat((mask * 255).astype(np.uint8)[..., None], 3, 2)
        res = _http('https://fal.run/fal-ai/flux-pro/v1/fill',
                    json.dumps({'image_url': _png_data_uri(render), 'mask_url': _png_data_uri(m), 'prompt': prompt,
                                'sync_mode': True, 'output_format': 'png', 'safety_tolerance': '5'}).encode(),
                    {'Authorization': f'Key {self.key}', 'Content-Type': 'application/json'})
        return composite(render, _image_from(res['images'][0]['url']), mask)


class OpenAIFixer:
    """OpenAI image edits with a mask: https://platform.openai.com/docs/api-reference/images/createEdit"""
    name = 'openai'

    def __init__(self):
        self.key = os.environ.get('OPENAI_API_KEY')
        if not self.key:
            raise SystemExit('openai: set OPENAI_API_KEY')
        self.model = os.environ.get('OPENAI_IMAGE_MODEL', 'gpt-image-1')

    def __call__(self, render, mask, ref=None, prompt=PROMPT):
        if not mask.any():
            return render
        h, w = render.shape[:2]
        size = (1536, 1024) if w > h else (1024, 1536) if h > w else (1024, 1024)
        img = Image.fromarray(render).resize(size, Image.LANCZOS)
        # the API edits where the mask is transparent
        alpha = Image.fromarray(((~mask) * 255).astype(np.uint8)).resize(size, Image.NEAREST)
        m = Image.new('RGBA', size, (0, 0, 0, 255))
        m.putalpha(alpha)
        boundary = '----splatfix' + os.urandom(8).hex()
        parts = []

        def field(name, value, filename=None, ctype=None):
            head = f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"' + (f'; filename="{filename}"' if filename else '') + '\r\n'
            if ctype:
                head += f'Content-Type: {ctype}\r\n'
            parts.append(head.encode() + b'\r\n' + (value if isinstance(value, bytes) else value.encode()) + b'\r\n')

        def png(im):
            b = io.BytesIO(); im.save(b, 'PNG'); return b.getvalue()
        field('model', self.model)
        field('prompt', prompt)
        field('size', f'{size[0]}x{size[1]}')
        field('image', png(img), 'image.png', 'image/png')
        field('mask', png(m), 'mask.png', 'image/png')
        body = b''.join(parts) + f'--{boundary}--\r\n'.encode()
        res = _http('https://api.openai.com/v1/images/edits', body,
                    {'Authorization': f'Bearer {self.key}', 'Content-Type': f'multipart/form-data; boundary={boundary}'})
        out = np.asarray(Image.open(io.BytesIO(base64.b64decode(res['data'][0]['b64_json']))).convert('RGB').resize((w, h), Image.LANCZOS))
        return composite(render, out, mask)
