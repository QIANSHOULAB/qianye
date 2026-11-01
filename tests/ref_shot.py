"""收参照：ref_shot.py 网址 名字 [宽 高] [--full] [--scroll N]
干净的 Edge 打开网址，cookie 弹窗点「只要必要的」那种，截图存 docs/参照/<名字>.png，打印标题和页面上的链接（挑作品用）。
参照图是别人的作品，只留在本机，不进仓库（.gitignore）。"""
import re
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
args = [a for a in sys.argv[1:] if not a.startswith("--")]
url, name = args[0], args[1]
w, h = (int(args[2]), int(args[3])) if len(args) > 3 else (1280, 860)
full = "--full" in sys.argv
scroll = int(sys.argv[sys.argv.index("--scroll") + 1]) if "--scroll" in sys.argv else 0
links = "--links" in sys.argv
dpr = int(sys.argv[sys.argv.index("--dpr") + 1]) if "--dpr" in sys.argv else 1
clip = [int(v) for v in sys.argv[sys.argv.index("--clip") + 1].split(",")] if "--clip" in sys.argv else None
REJECT = re.compile(r"^(reject all|reject|decline|only necessary|necessary only|use necessary cookies only|deny|拒绝|仅必要)", re.I)

with sync_playwright() as p:
    b = p.chromium.launch(channel="msedge")
    pg = b.new_context(viewport={"width": w, "height": h}, device_scale_factor=dpr, locale="en-US").new_page()
    pg.goto(url, wait_until="domcontentloaded", timeout=60_000)
    pg.wait_for_timeout(4000)
    for el in pg.query_selector_all("button, a[role=button], [role=button]"):
        try:
            t = (el.inner_text() or "").strip()
            if t and REJECT.match(t) and el.is_visible():
                el.click()
                print("cookie：点了", t)
                pg.wait_for_timeout(1500)
                break
        except Exception:
            pass
    if scroll:
        pg.mouse.wheel(0, scroll)
        pg.wait_for_timeout(2500)
    out = ROOT / "docs" / "参照" / f"{name}.png"
    if clip:
        pg.screenshot(path=str(out), full_page=True, clip={"x": clip[0], "y": clip[1], "width": clip[2], "height": clip[3]})
    else:
        pg.screenshot(path=str(out), full_page=full)
    print("标题", pg.title(), "|", pg.url)
    if links:
        seen = set()
        for a in pg.query_selector_all("a[href]"):
            href = a.get_attribute("href") or ""
            t = re.sub(r"\s+", " ", (a.inner_text() or "")).strip()
            if t and href not in seen and len(t) < 80:
                seen.add(href)
                print("  ", t, "→", href)
    b.close()
