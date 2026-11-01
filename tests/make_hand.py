"""造手写拍照样本：用 Google Fonts 的手写体（龙藏体 Long Cang、马善政 Ma Shan Zheng、站酷快乐体 ZCOOL KuaiLe）
写在横线本上，再加拍照效果：放在桌面上、透视歪斜、一侧阴影、轻微模糊、噪点、JPEG 压缩。
出 tests/hand/hN.jpg 和标准答案 hN.txt。公开的手写样本网站不在 012 放行的名单里，所以自己造（报告里写明）。"""
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "tests" / "hand"
SAMPLES = [
    ("h1", "Long Cang", "#1c2f6e", "11月2日产量\nA线 1280件\nB线 960件\nC线 1105件\n合计 3345件", (0.06, 0.03)),
    ("h2", "Ma Shan Zheng", "#111111", "采购清单\n1. 螺丝 200个\n2. 垫片 50个\n3. 胶带 12卷\n4. 手套 30双", (0.04, 0.05)),
    ("h3", "Long Cang", "#111111", "明天早上8点开会\n地点：二楼会议室\n带上本周的报表", (0.05, 0.02)),
    ("h4", "Ma Shan Zheng", "#1c2f6e", "本月出勤\n张师傅 22天\n李师傅 20天\n王师傅 21天", (0.08, 0.06)),
    ("h5", "ZCOOL KuaiLe", "#222222", "交接班\n3号机换了刀\n冷却液快没了\n晚班记得加", (0.03, 0.04)),
    ("h6", "Long Cang", "#1c2f6e", "不良品统计\n划伤 12个\n尺寸超差 5个\n毛刺 8个\n合计 25个", (0.12, 0.09)),
]


def solve(a, b):
    n = len(b)
    m = [row[:] + [b[i]] for i, row in enumerate(a)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(m[r][c]))
        m[c], m[p] = m[p], m[c]
        for r in range(n):
            if r != c:
                f = m[r][c] / m[c][c]
                m[r] = [x - f * y for x, y in zip(m[r], m[c])]
    return [m[i][n] / m[i][i] for i in range(n)]


def persp_coeffs(src, dst):
    """PIL 的 PERSPECTIVE 要「输出点 → 输入点」的 8 个系数"""
    a, b = [], []
    for (x, y), (u, v) in zip(dst, src):
        a.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); b.append(u)
        a.append([0, 0, 0, x, y, 1, -v * x, -v * y]); b.append(v)
    return solve(a, b)


def photo(paper, seed, tilt):
    rnd = random.Random(seed)
    W, H = 1500, 1900
    desk = Image.new("RGB", (W, H), (rnd.randint(120, 150), rnd.randint(100, 118), rnd.randint(80, 95)))
    dd = ImageDraw.Draw(desk)
    for i in range(0, H, 7):                      # 木纹
        c = rnd.randint(-14, 14)
        dd.line([(0, i), (W, i + rnd.randint(-20, 20))], fill=(130 + c, 108 + c, 86 + c), width=3)
    pw, ph = paper.size
    k = 0.8 * W / pw
    paper = paper.resize((int(pw * k), int(ph * k)))
    pw, ph = paper.size
    ox, oy = (W - pw) // 2, (H - ph) // 2
    tx, ty = tilt
    dst = [(ox + pw * tx, oy + ph * ty * 0.5), (ox + pw * (1 - tx * 0.3), oy), (ox + pw * (1 + tx * 0.2), oy + ph * (1 - ty * 0.2)), (ox - pw * tx * 0.4, oy + ph)]
    src = [(0, 0), (pw, 0), (pw, ph), (0, ph)]
    co = persp_coeffs(src, dst)
    mask = Image.new("L", paper.size, 255)
    warped = paper.transform((W, H), Image.PERSPECTIVE, co, Image.BICUBIC, fillcolor=(0, 0, 0))
    wmask = mask.transform((W, H), Image.PERSPECTIVE, co, Image.BICUBIC, fillcolor=0)
    shadow = wmask.filter(ImageFilter.GaussianBlur(18)).point(lambda v: int(v * 0.45))
    desk.paste((40, 30, 20), (14, 18), shadow)
    desk.paste(warped, (0, 0), wmask)
    # 一侧暗一点（手机挡了光）
    g = Image.linear_gradient("L").resize((W, H)).rotate(rnd.choice([30, 120, 210]), expand=False)
    dark = Image.new("RGB", (W, H), (0, 0, 0))
    desk = Image.composite(dark, desk, g.point(lambda v: int(v * 0.32)))
    desk = desk.filter(ImageFilter.GaussianBlur(1.1))
    noise = Image.effect_noise((W, H), 18).convert("RGB")
    desk = Image.blend(desk, noise, 0.06)
    return desk


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    fams = sorted({s[1] for s in SAMPLES})
    css = "https://fonts.googleapis.com/css2?" + "&".join("family=" + f.replace(" ", "+") for f in fams) + "&display=block"
    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge")
        pg = b.new_page(viewport={"width": 900, "height": 1150}, device_scale_factor=2)
        for name, fam, ink, text, tilt in SAMPLES:
            rnd = random.Random(name)
            lines = text.split("\n")
            spans = "".join(
                f'<div class="l" style="transform: translate({rnd.uniform(-6, 10):.1f}px,{rnd.uniform(-4, 4):.1f}px) rotate({rnd.uniform(-1.6, 1.6):.2f}deg);'
                f'font-size:{rnd.uniform(50, 58) if i else 64:.0f}px">{l}</div>' for i, l in enumerate(lines))
            html = f"""<!doctype html><meta charset=utf-8><link rel=stylesheet href="{css}"><style>
              body{{margin:0;background:#fbfaf4}} .page{{width:900px;height:1150px;padding:120px 80px 0 110px;box-sizing:border-box;
              background:repeating-linear-gradient(#fbfaf4 0 92px,#b9c8e0 92px 94px);position:relative}}
              .page:before{{content:"";position:absolute;left:84px;top:0;bottom:0;width:2px;background:#e8a2a2}}
              .l{{font-family:'{fam}',cursive;color:{ink};height:94px;line-height:94px;white-space:nowrap;transform-origin:left center}}
              </style><div class=page>{spans}</div>"""
            pg.set_content(html)
            pg.evaluate(f"document.fonts.load('56px \"{fam}\"', {text!r})")
            pg.wait_for_timeout(2500)
            pg.evaluate("document.fonts.ready")
            tmp = OUT / f"_{name}.png"
            pg.screenshot(path=str(tmp))
            paper = Image.open(tmp).convert("RGB")
            tmp.unlink()
            img = photo(paper, name, tilt)
            img.save(OUT / f"{name}.jpg", quality=82)
            (OUT / f"{name}.txt").write_text(text, encoding="utf-8")
            print(name, fam, img.size)
        b.close()


if __name__ == "__main__":
    main()
