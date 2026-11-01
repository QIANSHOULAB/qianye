"""iPhone 尺寸（390x844，3 倍屏，触屏）真点一遍，数点了几下：
A. 打字 → 分享
B. 拍照 → 改一个错字 → 分享
C. 换版式、3:4、1:1、JPG 再分享，看出来的图对不对
D. 第一次打开下载多大（不认字）；第一次认字又下多大（模型；跟渡表僧共用缓存，用过渡表僧就是 0）
手机的分享面板在测试浏览器里弹不出来，换成假的：记下分享出去的文件。结果写 tests/out/phone.json。"""
import json
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).parent))
from serve import serve  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SHARE_MOCK = """
window.__shared = [];
navigator.canShare = (d) => !!(d && d.files && d.files.length);
navigator.share = async (d) => { const f = d.files[0]; const b = new Uint8Array(await f.arrayBuffer());
  window.__shared.push({ name: f.name, type: f.type, size: f.size, head: Array.from(b.slice(0, 4)) }); };
"""
IPHONE_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"


def new_ctx(b):
    return b.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=3, is_mobile=True, has_touch=True, user_agent=IPHONE_UA)


def main():
    srv, port = serve()
    url = f"http://127.0.0.1:{port}/tengchao/index.html"
    rep = {}
    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge")

        # D. 第一次打开下载多大
        ctx = new_ctx(b)
        pg = ctx.new_page()
        sizes = []
        pg.on("requestfinished", lambda r: sizes.append((r.url, r.sizes()["responseBodySize"])))
        pg.goto(url, wait_until="networkidle")
        pg.wait_for_function("window.__teng && window.__teng.ready")
        pg.wait_for_timeout(1500)
        first = sum(s for _, s in sizes)
        rep["first_open_bytes"] = first
        rep["first_open_files"] = [(u.split("/")[-1][:60], s) for u, s in sizes]
        print(f"D. 第一次打开：{len(sizes)} 个文件，{first / 1024:.0f} KB（本机服务不压缩；线上 GitHub Pages 会 gzip）", flush=True)
        n0 = len(sizes)
        pg.set_input_files("#pick-album", str(ROOT / "tests" / "hand" / "h2.jpg"))
        pg.wait_for_function("window.__teng.reading === false", timeout=300_000)
        ocr = sum(s for _, s in sizes[n0:])
        rep["first_ocr_bytes"] = ocr
        print(f"   第一次认字：又下 {ocr / 1048576:.1f} MB（{', '.join(u.split('/')[-1] for u, _ in sizes[n0:])}）", flush=True)
        ctx.close()

        # A. 打字 → 分享
        ctx = new_ctx(b)
        ctx.add_init_script(SHARE_MOCK)
        pg = ctx.new_page()
        pg.goto(url)
        pg.wait_for_function("window.__teng && window.__teng.ready")
        taps = 0
        pg.tap("#text"); taps += 0          # 点进写字框不算（打字本身就得点）
        pg.keyboard.insert_text("今日产量\nA线 1280件\nB线 960件\n合计 2240件")
        pg.wait_for_timeout(900)            # 预览、预先画好的图
        pg.tap("#share"); taps += 1
        pg.wait_for_function("window.__shared.length === 1")
        s = pg.evaluate("window.__shared[0]")
        rep["A_typing_share"] = {"taps": taps, "file": {k: s[k] for k in ("name", "type", "size")}, "png": s["head"] == [137, 80, 78, 71]}
        print(f"A. 打字 → 分享：点了 {taps} 下 · {s['name']} {s['type']} {s['size']} 字节 · PNG 头{'对' if s['head'] == [137, 80, 78, 71] else '不对'}", flush=True)

        # C. 换版式、比例、格式
        for th, ratio, fmt in (("mag", "3:4", "jpg"), ("big", "1:1", "png")):
            pg.tap(f".th[data-id={th}]")
            pg.tap(f"#ratio button[data-v='{ratio}']")
            pg.tap(f"#fmt button[data-v='{fmt}']")
            pg.wait_for_timeout(900)
            pg.tap("#share")
            pg.wait_for_timeout(1200)
            s = pg.evaluate("window.__shared[window.__shared.length - 1]")
            wh = pg.evaluate("window.__teng.exportSize")
            rep[f"C_{th}_{ratio}_{fmt}"] = {"type": s["type"], "size": s["size"], "w": wh[0], "h": wh[1], "ratio": round(wh[1] / wh[0], 3)}
            print(f"C. {th} {ratio} {fmt}：{s['type']} {wh[0]}×{wh[1]}（高/宽 {wh[1] / wh[0]:.3f}）{s['size']} 字节", flush=True)
        ctx.close()

        # B. 拍照 → 改一个错字 → 分享
        ctx = new_ctx(b)
        ctx.add_init_script(SHARE_MOCK)
        pg = ctx.new_page()
        pg.goto(url)
        pg.wait_for_function("window.__teng && window.__teng.ready")
        taps = 0
        with pg.expect_file_chooser() as fc:
            pg.tap("#snap"); taps += 1      # 拍（相机拍照、「使用照片」是手机自己的界面，不算）
        fc.value.set_files(str(ROOT / "tests" / "hand" / "h1.jpg"))
        pg.wait_for_function("window.__teng.reading === false", timeout=300_000)
        before = pg.input_value("#text")
        box = pg.evaluate("(() => { const m = document.querySelector('#mirror mark'); if (!m) return null; const r = m.getBoundingClientRect(); return {x: r.x + r.width / 2, y: r.y + r.height / 2, s: m.textContent}; })()")
        fixed = None
        if box:
            pg.mouse.click(box["x"], box["y"]); taps += 1          # 点一下黄字：那几个字被选中
            sel = pg.evaluate("[document.querySelector('#text').selectionStart, document.querySelector('#text').selectionEnd]")
            pg.keyboard.press("Backspace")                          # 多认出来的「1」：删掉（键盘不算点）
            fixed = {"mark": box["s"], "selected": sel}
        pg.wait_for_timeout(900)
        pg.tap("#share"); taps += 1
        pg.wait_for_timeout(1200)
        s = pg.evaluate("window.__shared[0]")
        after = pg.input_value("#text")
        rep["B_photo_fix_share"] = {"taps": taps, "fixed": fixed, "before": before, "after": after, "file": {k: s[k] for k in ("name", "type", "size")}}
        print(f"B. 拍照 → 改一个错字 → 分享：点了 {taps} 下（拍 1、点黄字 1、分享 1）· 黄字 {fixed and fixed['mark']!r} 被选中 {fixed and fixed['selected']}", flush=True)
        print(f"   改前：{before.splitlines()[1] if len(before.splitlines()) > 1 else before!r} → 改后：{after.splitlines()[1] if len(after.splitlines()) > 1 else after!r}")
        ctx.close()
        b.close()
    (ROOT / "tests" / "out").mkdir(parents=True, exist_ok=True)
    (ROOT / "tests" / "out" / "phone.json").write_text(json.dumps(rep, ensure_ascii=False, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
