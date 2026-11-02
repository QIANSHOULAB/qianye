"""纸和图对不对得上（施工单 013 第 4 节）：tests/texts.json 20 段 × 9 个版式 × 3 种比例。
手机宽 390，3 倍屏、2 倍屏各来一遍：截上面那张纸（收起键盘后），再点「分享」拿到分享出去的图，逐像素比。
- 3 倍屏：纸和图都是 1170 宽，直接比。
- 2 倍屏：纸是 780 宽，图还是 1170 宽（图永远按 3 倍出）。比两样：纸跟同一段代码按 2 倍画的图比（该一模一样）；
  纸跟分享出去的图缩到 780 宽比（缩放本身有误差，给出平均差多少）。
结果写 tests/out/paper.json。用法：run_paper.py [--quick]（--quick 只跑 3 段）"""
import base64
import io
import json
import sys
import time
from pathlib import Path

from PIL import Image, ImageChops, ImageStat
from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).parent))
from serve import serve, browser  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
CASES = json.loads((ROOT / "tests" / "texts.json").read_text(encoding="utf-8"))
if "--quick" in sys.argv:
    CASES = CASES[:3]
RATIOS = ["auto", "3:4", "1:1"]
SHARE_MOCK = "navigator.canShare = (d) => !!(d && d.files); navigator.share = async () => {};"
IPHONE_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
OUT = ROOT / "tests" / "out" / "paper"


def img(b):
    return Image.open(io.BytesIO(b)).convert("RGB")


def diff(a, b):
    """差几个像素、最大差多少、平均差多少（0～255）、差在哪（框）"""
    if a.size != b.size:
        return {"size": [a.size, b.size]}
    d = ImageChops.difference(a, b)
    box = d.getbbox()
    if not box:
        return {"px": 0}
    g = d.convert("L")
    px = sum(g.histogram()[1:])
    return {"px": px, "max": max(m for _, m in d.getextrema()), "mean": round(sum(ImageStat.Stat(d).mean) / 3, 4), "box": box}


def run(b, dpr):
    ctx = b.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=dpr, is_mobile=True, has_touch=True, user_agent=IPHONE_UA)
    ctx.add_init_script(SHARE_MOCK)
    pg = ctx.new_page()
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(URL)
    pg.wait_for_function("window.__teng && window.__teng.ready")
    res = []
    for c in CASES:
        for th in pg.evaluate("window.__teng.THEMES.map(t => t.id)"):
            pg.evaluate("([th, t]) => window.__teng.ensureFonts(th, t)", [th, c["text"]])
            for ratio in RATIOS:
                pg.evaluate("([t, th, r]) => window.__teng.set(t, th, r)", [c["text"], th, ratio])
                pg.evaluate("() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))")
                # 底下那条（版式、按钮）是浮在页面上的，长纸的下半截会被它盖住：截纸的时候先让它躲开
                pg.evaluate("document.querySelector('#dock').style.visibility = 'hidden'")
                shot = img(pg.locator("#paper-cv").screenshot(animations="disabled"))
                pg.evaluate("document.querySelector('#dock').style.visibility = ''")
                pg.click("#share")
                url = pg.evaluate("window.__teng.exportUrl")
                out = img(base64.b64decode(url.split(",")[1]))
                r = {"id": c["id"], "theme": th, "ratio": ratio, "paper": shot.size, "image": out.size}
                if dpr == 3:
                    r["diff"] = diff(shot, out)
                else:
                    same = pg.evaluate("([t, th, r]) => window.__teng.render(t, th, r, 2).url", [c["text"], th, ratio])
                    r["diff_same_code_2x"] = diff(shot, img(base64.b64decode(same.split(",")[1])))
                    r["diff_image_scaled"] = diff(shot, out.resize(shot.size, Image.LANCZOS))
                if (r.get("diff") or r.get("diff_same_code_2x"))["px"]:
                    OUT.mkdir(parents=True, exist_ok=True)
                    shot.save(OUT / f"{dpr}x_{c['id']}_{th}_{ratio.replace(':', '')}_纸.png")
                    out.save(OUT / f"{dpr}x_{c['id']}_{th}_{ratio.replace(':', '')}_图.png")
                res.append(r)
    ctx.close()
    return res, errs


def main():
    global URL
    srv, port = serve()
    URL = f"http://127.0.0.1:{port}/qianye/index.html"
    rep = {}
    with sync_playwright() as p:
        b = browser(p)
        for dpr in (3, 2):
            t0 = time.time()
            res, errs = run(b, dpr)
            key = "diff" if dpr == 3 else "diff_same_code_2x"
            exact = sum(1 for r in res if r[key].get("px") == 0)
            print(f"{dpr} 倍屏：{len(res)} 张，纸和{'图' if dpr == 3 else '同一段代码按 2 倍画的图'}逐像素一样 {exact} 张"
                  f"（{time.time() - t0:.0f} 秒）；页面报错 {errs or '无'}", flush=True)
            for r in res:
                if r[key].get("px") != 0:
                    print("   不一样：", r["id"], r["theme"], r["ratio"], r[key])
            if dpr == 2:
                means = [r["diff_image_scaled"].get("mean", 0) for r in res]
                print(f"   纸 vs 分享的图缩到 780 宽：平均差 {sum(means) / len(means):.3f}/255，最大的一张 {max(means):.3f}/255（缩放本身的误差）")
            rep[f"{dpr}x"] = {"n": len(res), "exact": exact, "errors": errs, "cases": res}
        b.close()
    (ROOT / "tests" / "out").mkdir(parents=True, exist_ok=True)
    (ROOT / "tests" / "out" / "paper.json").write_text(json.dumps(rep, ensure_ascii=False, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
