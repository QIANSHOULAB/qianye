"""看一眼：look.py [宽 高] [--text 文字] [--theme id] [--out 文件] [--export 目录]
本机起服务，iPhone 尺寸（默认 390x844、3 倍屏）打开千叶，打印页面报错，整页截图。
--export 目录：把 9 个版式各出一张 3 倍图存进去（用 __teng.render）。"""
import base64
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).parent))
from serve import serve  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
args = [a for a in sys.argv[1:] if not a.startswith("--")]
w, h = (int(args[0]), int(args[1])) if len(args) >= 2 else (390, 844)
opt = lambda k, d=None: sys.argv[sys.argv.index(k) + 1] if k in sys.argv else d
text = opt("--text")
theme = opt("--theme")
out = opt("--out", str(ROOT / "docs" / "对比" / "_look.png"))
export = opt("--export")

srv, port = serve()
with sync_playwright() as p:
    b = p.chromium.launch(channel="msedge")
    mobile = w < 700
    ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    ctx = b.new_context(viewport={"width": w, "height": h}, device_scale_factor=3 if mobile else 1, is_mobile=mobile, has_touch=mobile, **({"user_agent": ua} if mobile else {}))
    pg = ctx.new_page()
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.on("console", lambda m: errs.append(m.text) if m.type == "error" else None)
    pg.add_init_script("localStorage.clear()")
    pg.goto(f"http://127.0.0.1:{port}/qianye/index.html")
    pg.wait_for_function("window.__teng && window.__teng.ready", timeout=20000)
    if text is not None or theme:
        pg.evaluate("([t, th]) => window.__teng.set(t, th)", [(text or "").replace("\\n", "\n"), theme])
    pg.wait_for_timeout(1500)
    pg.screenshot(path=out, full_page=True)
    print("截图", out)
    if export:
        Path(export).mkdir(parents=True, exist_ok=True)
        t = text.replace("\\n", "\n") if text else pg.evaluate("window.__teng.SAMPLE")
        for th in pg.evaluate("window.__teng.THEMES.map(t => t.id)"):
            pg.evaluate("([th, t]) => window.__teng.ensureFonts(th, t)", [th, t])
            r = pg.evaluate("([t, th]) => window.__teng.render(t, th)", [t, th])
            (Path(export) / f"{th}.png").write_bytes(base64.b64decode(r["url"].split(",")[1]))
            print("出图", th, r["H"])
    print("报错", errs or "无")
    b.close()
