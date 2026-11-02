"""013 边做边比：手机界面跟苹果的参照并排放。compare_ui.py <轮次>
出 docs/对比/<轮次>_界面_对R03R04.png：左起 刚打开、写了字、两个按钮的三种配法（实心在右 / 实心在左 / 都浅色），最右参照。
参照是别人的作品，对比图只留在本机（.gitignore 里有 docs/对比/*.png）。"""
import io
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).parent))
from serve import serve, browser  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
RND = sys.argv[1] if len(sys.argv) > 1 else "r4"
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
TEXT = "11月1日 各线产量\nA线早班 1,280件\nB线早班 960件\nC线中班 1,105件\n合计 3,345件\n\n明天上午8点到12点停电检修，请各线提前把数据存好。"
VARIANTS = {
    "实心在右": "",
    "实心在左": "document.querySelector('#save').className='btn'; document.querySelector('#share').className='btn tint';",
    "都浅色": "document.querySelector('#share').className='btn tint';",
}
FONT = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 34)


def shot(pg):
    return Image.open(io.BytesIO(pg.screenshot())).convert("RGB")


srv, port = serve()
tiles = []
with sync_playwright() as p:
    b = browser(p)
    ctx = b.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=3, is_mobile=True, has_touch=True, user_agent=UA)
    ctx.add_init_script("localStorage.clear()")
    pg = ctx.new_page()
    pg.goto(f"http://127.0.0.1:{port}/qianye/index.html")
    pg.wait_for_function("window.__teng && window.__teng.ready")
    pg.wait_for_timeout(800)
    tiles.append(("刚打开", shot(pg)))
    pg.evaluate("t => window.__teng.set(t)", TEXT)
    pg.wait_for_timeout(800)
    for name, js in VARIANTS.items():
        pg.evaluate(js)
        tiles.append((f"写了字 · 按钮{name}", shot(pg)))
        pg.evaluate("document.querySelector('#save').className='btn tint'; document.querySelector('#share').className='btn';")
    b.close()
refs = [ROOT / "docs" / "参照" / n for n in ("R03_apple_iPad备忘录.png", "R04_ADA2026_页面排版.png")]
for r in refs:
    if r.exists():
        im = Image.open(r).convert("RGB")
        tiles.append((r.stem, im))
H = 1600
cols = []
for name, im in tiles:
    im = im.resize((round(im.width * H / im.height), H))
    c = Image.new("RGB", (im.width, H + 70), "white")
    c.paste(im, (0, 70))
    ImageDraw.Draw(c).text((12, 14), name, fill="#333", font=FONT)
    cols.append(c)
out = Image.new("RGB", (sum(c.width for c in cols) + 24 * (len(cols) - 1), H + 70), "#ddd")
x = 0
for c in cols:
    out.paste(c, (x, 0))
    x += c.width + 24
dst = ROOT / "docs" / "对比" / f"{RND}_界面_对R03R04.png"
out.save(dst)
print("对比图", dst)
