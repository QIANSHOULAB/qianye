#!/usr/bin/env python3
"""录入僧 163：iOS 模拟器的 Safari 里，拿「拍照那种」「相册那种」大 JPG 各种画法各画一遍，看哪种白。
用法：luru163.py <模拟器 UDID> <名字>。结果打到 stderr，小图、截图推到 luru-163-ios 分支的 luru163-out/。"""
import http.server, json, os, random, subprocess, sys, threading, time, base64
from PIL import Image, ImageDraw

UDID, SIMNAME = sys.argv[1], sys.argv[2]
REF = os.environ.get('LURU_REF', 'main')
W = '/tmp/l163'
OUT = os.path.join(os.getcwd(), 'luru163-out')
os.makedirs(W, exist_ok=True)
os.makedirs(OUT, exist_ok=True)
here = os.path.dirname(os.path.abspath(__file__))
P = lambda *a: print(*a, flush=True)

subprocess.run(['git', 'clone', '-q', 'https://github.com/QIANSHOULAB/luruseng.git', f'{W}/lr'], check=True)
subprocess.run(['git', '-C', f'{W}/lr', 'checkout', '-q', REF], check=True)
P('luruseng', subprocess.check_output(['git', '-C', f'{W}/lr', 'log', '-1', '--format=%h %s']).decode().strip())
IMG = f'{W}/lr/img'
os.makedirs(IMG, exist_ok=True)


def sheets(size, spots, seed, noisy):
    Wd, H = size
    rnd = random.Random(seed)
    if noisy:
        im = Image.effect_noise(size, 90).convert('RGB')
        im = Image.blend(im, Image.new('RGB', size, (70, 58, 48)), 0.35)
    else:
        im = Image.new('RGB', size, (70, 58, 48))
    d0 = ImageDraw.Draw(im)
    for _ in range(3000 if noisy else 300):
        x, y = rnd.randrange(Wd), rnd.randrange(H)
        d0.ellipse([x, y, x + 9, y + 9], fill=(230, 230, 225))
    k = 0.40
    pw, ph = int(Wd * k), int(H * k)
    for n, (fx, fy) in enumerate(spots):
        s = Image.new('RGB', (pw, ph), (246, 246, 242))
        d = ImageDraw.Draw(s)
        d.rectangle([pw * .08, ph * .07, pw * (.30 + .05 * n), ph * .18], fill=(40, 40, 50))
        for r in range(9):
            y = int(ph * (.28 + r * .075))
            d.line([(pw * .07, y), (pw * .93, y)], fill=(70, 70, 70), width=4)
            for c in range(5):
                x = int(pw * (.09 + c * .17))
                d.rectangle([x, y - ph * .045, x + pw * (.05 + .02 * ((r + c + n) % 3)), y - ph * .018], fill=(40, 40, 50))
        im.paste(s, (int(Wd * fx - pw / 2), int(H * fy - ph / 2)))
    return im


def save(im, name, orient, q=92):
    ex = Image.Exif()
    ex[0x0112] = orient
    ex[0x010f] = 'Apple'
    ex[0x0110] = 'iPhone 15 Pro'
    p = os.path.join(IMG, name)
    im.save(p, quality=q, exif=ex.tobytes())
    return p


X = [(.27, .27), (.73, .27), (.27, .73), (.73, .73)]
up_noisy = sheets((3024, 4032), X, 6, True)
up_calm = sheets((3024, 4032), X, 7, False)
names = []
names.append(os.path.basename(save(up_noisy.transpose(Image.Transpose.ROTATE_90), 'cam6_noisy.jpg', 6)))      # 竖着拍：像素横的、方向 6、很花
names.append(os.path.basename(save(up_calm.transpose(Image.Transpose.ROTATE_90), 'cam6_calm.jpg', 6)))        # 竖着拍、不花
names.append(os.path.basename(save(sheets((4032, 3024), X, 8, True), 'cam1_land_noisy.jpg', 1)))               # 横着拍、方向 1、很花
names.append(os.path.basename(save(up_noisy, 'album1_noisy.jpg', 1)))                                          # 相册导出：转好了
big = sheets((5712, 4284), X, 9, True)
names.append(os.path.basename(save(big.transpose(Image.Transpose.ROTATE_90), 'cam6_48mp_noisy.jpg', 6)))   # 4800 万像素
subprocess.run(['swiftc', '-O', '-o', f'{W}/gain', os.path.join(here, 'gain.swift')], check=False)
for kind in ('apple', 'iso'):
    for src, orient in (('cam6_noisy.jpg', 6), ('cam6_calm.jpg', 6)):
        dst = f'gain_{kind}_{src}'
        r = subprocess.run([f'{W}/gain', os.path.join(IMG, src), os.path.join(IMG, dst), kind, str(orient)], capture_output=True, text=True)
        P('gain', kind, src, r.returncode, r.stdout.strip(), r.stderr.strip()[-300:])
        if r.returncode == 0 and os.path.exists(os.path.join(IMG, dst)):
            names.append(dst)
for n in names:
    b = open(os.path.join(IMG, n), 'rb').read()
    P(f'  {n}: {len(b)/1e6:.2f}MB MPF={b"MPF" in b[:200000]} HDRGainMap={b"HDRGainMap" in b} iso={b"21496" in b} hdrgm={b"hdrgm" in b}')
json.dump(names, open(os.path.join(IMG, 'list.json'), 'w'))

open(f'{W}/lr/web/sim163.html', 'w').write('''<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<body style="font:13px -apple-system"><pre id="o" style="white-space:pre-wrap">start</pre>
<script type="module">
import * as I from './image.js';
const o = document.getElementById('o');
const say = (s) => { o.textContent += '\\n' + s; };
const post = (path, body) => fetch(path, { method: 'POST', body: JSON.stringify(body) });
window.onerror = (m) => post('/log', { m: String(m) });
const LIMIT = 1800000, SIDE = 2560;
async function legacy(file) {
  const img = await I.legacyImg(file);
  let side = SIDE, q = 0.86, blob, rounds = 0;
  for (;;) {
    rounds++;
    blob = await I.toBlob(I.draw(img, side), q);
    if (blob.size <= LIMIT || side <= 1400) break;
    if (q > 0.62) q -= 0.12; else { side = Math.round(side * 0.8); q = 0.8; }
  }
  return { blob, rounds, nat: [img.naturalWidth, img.naturalHeight] };
}
async function look(blob) {
  const b = await createImageBitmap(blob);
  const t = I.thumb(b, 240), wh = [b.width, b.height];
  b.close();
  return { t, wh };
}
try {
  const list = await (await fetch('/img/list.json')).json();
  await post('/log', { ua: navigator.userAgent, offscreen: typeof OffscreenCanvas });
  for (const name of list) {
    const blob = await (await fetch('/img/' + name)).blob();
    const file = new File([blob], 'image.jpg', { type: 'image/jpeg', lastModified: Date.now() });
    const info = I.jpegInfo(await file.slice(0, 4 << 20).arrayBuffer());
    const rows = [];
    for (const way of ['legacy', 'img', 'imgOff', 'bitmap', 'bitmapRaw']) {
      const t0 = performance.now();
      try {
        let out, rounds = 0, cf = null, nat = null;
        if (way === 'legacy') { const r = await legacy(file); out = r.blob; rounds = r.rounds; nat = r.nat; }
        else { const c = await I.paintWith(way, file, SIDE, info); cf = I.flatness(c); out = await I.toBlob(c, 0.86); c.width = c.height = 1; }
        const bf = await I.blobFlatness(out);
        const { t, wh } = await look(out);
        rows.push({ way, cf, bf, size: out.size, rounds, nat, wh, ms: Math.round(performance.now() - t0), thumb: t });
      } catch (e) { rows.push({ way, err: String(e && (e.name + ': ' + e.message)) }); }
    }
    let sq;
    try { const r = await I.squeeze(file, SIDE, LIMIT); sq = { way: r.way, flat: r.flat, tried: r.tried, ok: !!r.blob, size: r.blob && r.blob.size, thumb: r.look }; }
    catch (e) { sq = { err: String(e) }; }
    await post('/report', { name, info, rows, squeeze: sq });
    say(name + ' ' + rows.map((r) => r.way + ':' + (r.err ? 'ERR' : r.bf)).join(' '));
  }
} catch (e) { await post('/log', { fatal: String(e) }); }
await post('/done', {});
say('done');
</script>''')

done = threading.Event()
results = []


class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=f'{W}/lr', **k)

    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['content-length'])) or b'{}')
        if self.path == '/report':
            results.append(body)
            P(f"\n== {body['name']}  info={json.dumps(body['info'])}")
            for r in body['rows']:
                if r.get('err'):
                    P(f"   {r['way']:10s} 出错 {r['err']}")
                    continue
                P(f"   {r['way']:10s} {'白  ' if r['bf'] < 4 else '不白'} jpg平整度 {r['bf']:5}  画布 {r['cf']}  {r['wh'][0]}×{r['wh'][1]}  "
                  f"{r['size']/1e6:.2f}MB  {r['ms']}ms  遍数 {r['rounds']} img {r['nat']}")
                with open(os.path.join(OUT, f"{body['name']}_{r['way']}.jpg"), 'wb') as f:
                    f.write(base64.b64decode(r['thumb'].split(',', 1)[1]))
            sq = dict(body['squeeze'])
            sq.pop('thumb', None)
            P(f"   squeeze -> {json.dumps(sq, ensure_ascii=False)}")
        elif self.path == '/done':
            done.set()
        else:
            P('LOG', json.dumps(body, ensure_ascii=False))
        self.send_response(200)
        self.end_headers()


srv = http.server.ThreadingHTTPServer(('127.0.0.1', 8163), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
subprocess.run(['xcrun', 'simctl', 'boot', UDID])
subprocess.run(['xcrun', 'simctl', 'bootstatus', UDID, '-b'], timeout=600)
time.sleep(5)
subprocess.run(['xcrun', 'simctl', 'openurl', UDID, 'http://127.0.0.1:8163/web/sim163.html'], check=True)
t0 = time.time()
shot = 0
while not done.wait(30):
    shot += 1
    subprocess.run(['xcrun', 'simctl', 'io', UDID, 'screenshot', os.path.join(OUT, f'screen_{shot}.png')], capture_output=True)
    P(f'... {int(time.time() - t0)}s, {len(results)} 张')
    if time.time() - t0 > 900:
        P('超时')
        break
subprocess.run(['xcrun', 'simctl', 'io', UDID, 'screenshot', os.path.join(OUT, 'screen_end.png')], capture_output=True)
for r in results:
    for row in r['rows']:
        row.pop('thumb', None)
    r['squeeze'].pop('thumb', None)
json.dump({'sim': SIMNAME, 'results': results}, open(os.path.join(OUT, 'results.json'), 'w'), ensure_ascii=False, indent=1)

P('\n==== 汇总（' + SIMNAME + '）')
for r in results:
    P(f"{r['name']:34s} " + '  '.join(f"{x['way']}={'ERR' if x.get('err') else ('白' if x['bf'] < 4 else '好')}" for x in r['rows'])
      + f"  squeeze={r['squeeze'].get('way')}/{'发' if r['squeeze'].get('ok') else '不发'}")

# 小图、截图推回这个分支，方便看
subprocess.run('git config user.name "$(git log -1 --format=%an)"; git config user.email "$(git log -1 --format=%ae)"; '
               'git add luru163-out && git commit -q -m "luru163 结果 [skip ci]" && git push -q origin HEAD:refs/heads/luru-163-ios',
               shell=True)
