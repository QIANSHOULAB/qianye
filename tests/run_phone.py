"""iPhone 尺寸（390x844，3 倍屏，触屏）真点一遍，数点了几下（施工单 013 第 4 节）。系统面板里的点按不算。
A  打字 → 分享：1 下；打字 → 保存相册：1 下（iPhone 弹系统面板，面板里点「存储图像」）
B  打字 → 换版式 → 分享 / 保存：2 下
C  拍照 → 点黄字改 → 分享：3 下
D  换版式：光标不丢、字不丢
E  正在打的那一行不跳：一个字一个字打，已经打出来的字在纸上的位置一点不动；换行以后才落定
F  拼音组字中不被打断（CDP Input.imeSetComposition）：组字时纸不重画、像素不变；上屏后字对
G  点「保存相册」「分享」之前：toBlob 0 次、File 0 个
H  微信（UA 带 MicroMessenger）：两个按钮都弹大图页，大图是 data 地址
I  电脑宽屏：「保存相册」直接下文件；没有分享面板时「分享」把图放进剪贴板
J  第一次打开下载多大；第一次认手写又下多大
K  假键盘（弹起来 336 高，挡住屏幕下面）：键盘弹着时底下那条整条收起来；点键盘上的 ✓ 收键盘，它再出来。打字 → ✓ → 分享：2 下
   （A–J 的模拟浏览器里没有键盘，底下那条一直在；真 iPhone 上打完字要先点 ✓，所以比 A、B、C 各多 1 下）
手机的分享面板在测试浏览器里弹不出来，换成假的：记下分享出去的文件。结果写 tests/out/phone.json。"""
import base64
import json
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).parent))
from serve import serve, browser  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
COUNT = """
window.__cnt = { toBlob: 0, file: 0, toDataURL: 0 };
const _tb = HTMLCanvasElement.prototype.toBlob;
HTMLCanvasElement.prototype.toBlob = function (...a) { window.__cnt.toBlob++; return _tb.apply(this, a); };
const _td = HTMLCanvasElement.prototype.toDataURL;
HTMLCanvasElement.prototype.toDataURL = function (...a) { window.__cnt.toDataURL++; return _td.apply(this, a); };
window.File = new Proxy(window.File, { construct(t, a) { window.__cnt.file++; return new t(...a); } });
"""
SHARE_MOCK = COUNT + """
window.__shared = [];
navigator.canShare = (d) => !!(d && d.files && d.files.length);
navigator.share = async (d) => { const f = d.files[0]; const b = new Uint8Array(await f.arrayBuffer());
  window.__shared.push({ name: f.name, type: f.type, size: f.size, head: Array.from(b.slice(0, 4)) }); };
"""
IPHONE_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
WECHAT_UA = IPHONE_UA + " MicroMessenger/8.0.50(0x18003237) NetType/WIFI Language/zh_CN"
TEXT = "今日产量\nA线 1280件\nB线 960件\n合计 2240件"
FAKE_KB = """
window.__kb = 0;
Object.defineProperty(VisualViewport.prototype, 'height', { configurable: true, get() { return window.innerHeight - window.__kb; } });
const kb = (h) => { window.__kb = h; window.visualViewport.dispatchEvent(new Event('resize')); };
document.addEventListener('focusin', (e) => { if (e.target.id === 'text') kb(336); });
document.addEventListener('focusout', (e) => { if (e.target.id === 'text') kb(0); });
"""


def phone(b, ua=IPHONE_UA, init=SHARE_MOCK):
    ctx = b.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=3, is_mobile=True, has_touch=True, user_agent=ua)
    ctx.add_init_script("localStorage.clear()")
    ctx.add_init_script(init)
    pg = ctx.new_page()
    pg.goto(URL)
    pg.wait_for_function("window.__teng && window.__teng.ready")
    return ctx, pg


def tap_paper(pg, i=None):
    """点纸：i 给了就点第 i 个字前面，没给就点纸的中间偏下"""
    if i is None:
        bb = pg.locator("#paper-cv").bounding_box()
        pg.touchscreen.tap(bb["x"] + bb["width"] / 2, bb["y"] + bb["height"] * 0.6)
    else:
        p = pg.evaluate("i => window.__teng.at(i)", i)
        pg.touchscreen.tap(p["x"] + 1, p["y"])


def line_pos(pg, a, b):
    return pg.evaluate("([a, b]) => { const out = []; for (let i = a; i <= b; i++) { const p = window.__teng.at(i); out.push(p && [Math.round(p.x * 100) / 100, Math.round(p.y * 100) / 100]); } return out; }", [a, b])


def main():
    global URL
    srv, port = serve()
    URL = f"http://127.0.0.1:{port}/qianye/index.html"
    rep = {}
    say = lambda *a: print(*a, flush=True)
    with sync_playwright() as p:
        b = browser(p)

        # A. 打字 → 分享；G. 点之前不出文件
        ctx, pg = phone(b)
        tap_paper(pg)                       # 点纸、弹键盘：打字本身就得点，不算
        pg.keyboard.insert_text(TEXT)
        pg.wait_for_timeout(600)
        before = pg.evaluate("({...window.__cnt})")
        taps = 0
        pg.tap("#share"); taps += 1
        pg.wait_for_function("window.__shared.length === 1")
        s = pg.evaluate("window.__shared[0]")
        why = pg.evaluate("window.__teng.shared.why")
        rep["A_typing_share"] = {"taps": taps, "why": why, "file": {k: s[k] for k in ("name", "type", "size")}, "png": s["head"] == [137, 80, 78, 71]}
        rep["G_before_click"] = before
        say(f"A. 打字 → 分享：点了 {taps} 下 · 弹系统面板 · {s['name']} {s['size']} 字节 · PNG 头{'对' if s['head'] == [137, 80, 78, 71] else '不对'}")
        say(f"G. 点按钮之前：toBlob {before['toBlob']} 次、File {before['file']} 个、toDataURL {before['toDataURL']} 次")
        ctx.close()

        ctx, pg = phone(b)
        tap_paper(pg)
        pg.keyboard.insert_text(TEXT)
        taps = 0
        pg.tap("#save"); taps += 1
        pg.wait_for_function("window.__shared.length === 1")
        why = pg.evaluate("window.__teng.shared.why")
        rep["A_typing_save_iphone"] = {"taps": taps, "why": why, "sheet": pg.evaluate("window.__teng.sheet || null")}
        say(f"A. 打字 → 保存相册（iPhone）：点了 {taps} 下 · 弹系统面板（{why}），面板里点「存储图像」进相册")
        ctx.close()

        # B. 打字 → 换版式 → 分享 / 保存
        for btn in ("share", "save"):
            ctx, pg = phone(b)
            tap_paper(pg)
            pg.keyboard.insert_text(TEXT)
            taps = 0
            pg.tap(".th[data-id=mag]"); taps += 1
            pg.tap(f"#{btn}"); taps += 1
            pg.wait_for_function("window.__shared.length === 1")
            same = pg.evaluate("t => window.__teng.exportUrl === window.__teng.render(t, 'mag', 'auto', 3).url", TEXT)
            rep[f"B_typing_theme_{btn}"] = {"taps": taps, "image_is_mag": same}
            say(f"B. 打字 → 换版式（杂志）→ {'分享' if btn == 'share' else '保存相册'}：点了 {taps} 下 · 出的图是杂志版{'，对' if same else '，不对'}")
            ctx.close()

        # C. 拍照 → 点黄字改 → 分享
        ctx, pg = phone(b)
        taps = 0
        with pg.expect_file_chooser() as fc:
            pg.tap("#snap"); taps += 1      # 拍（相机拍照、「使用照片」是手机自己的界面，不算）
        fc.value.set_files(str(ROOT / "tests" / "hand" / "h1.jpg"))
        pg.wait_for_function("window.__teng.reading === false", timeout=300_000)
        before = pg.evaluate("document.querySelector('#text').value")
        m = pg.evaluate("window.__teng.markAt(0)")
        fixed = None
        if m:
            pg.touchscreen.tap(m["x"], m["y"]); taps += 1        # 点一下黄字：那几个字被选中
            sel = pg.evaluate("window.__teng.sel()")
            pg.keyboard.press("Backspace")                      # 多认出来的「1」：删掉（键盘不算点）
            fixed = {"mark": m["s"], "selected": sel}
        pg.tap("#share"); taps += 1
        pg.wait_for_function("window.__shared.length === 1")
        after = pg.evaluate("document.querySelector('#text').value")
        rep["C_photo_fix_share"] = {"taps": taps, "fixed": fixed, "before": before, "after": after}
        line = lambda v: v.splitlines()[1] if len(v.splitlines()) > 1 else v
        say(f"C. 拍照 → 点黄字改 → 分享：点了 {taps} 下 · 黄字 {fixed and fixed['mark']!r} 被选中 {fixed and fixed['selected']} · 改前 {line(before)!r} → 改后 {line(after)!r}")
        ctx.close()

        # D. 换版式：光标不丢、字不丢
        ctx, pg = phone(b)
        tap_paper(pg)
        pg.keyboard.insert_text(TEXT)
        tap_paper(pg, 8)                    # 点「A线 1280件」的「1」前面
        sel0, v0 = pg.evaluate("window.__teng.sel()"), pg.evaluate("document.querySelector('#text').value")
        res = []
        for th in ("white", "night", "notice", "note"):
            pg.tap(f".th[data-id={th}]")
            res.append({"theme": th, "sel": pg.evaluate("window.__teng.sel()"), "same_text": pg.evaluate("document.querySelector('#text').value") == v0,
                        "focused": pg.evaluate("document.activeElement.id")})
        pg.keyboard.insert_text("2")         # 接着打：字落在原来光标那儿
        v1 = pg.evaluate("document.querySelector('#text').value")
        ok = all(r["sel"] == sel0 and r["same_text"] for r in res)
        rep["D_theme_keeps_caret"] = {"sel": sel0, "after": res, "typed_into": v1.splitlines()[1], "ok": ok}
        say(f"D. 换 4 次版式：光标 {sel0} → {[r['sel'] for r in res]} · 字{'一个没动' if all(r['same_text'] for r in res) else '变了'} · 接着打一个「2」：{v1.splitlines()[1]!r}")
        ctx.close()

        # E. 正在打的那一行不跳
        ctx, pg = phone(b)
        tap_paper(pg)
        drift, steps = 0.0, []
        for line_text, start in (("今日产量", 0), ("A线早班 1,280件", 5)):
            prev = None
            for k, ch in enumerate(line_text):
                pg.keyboard.insert_text(ch)
                pos = line_pos(pg, start, start + k + 1)
                if prev:
                    for a, c in zip(prev, pos):
                        if a and c:
                            drift = max(drift, abs(a[0] - c[0]), abs(a[1] - c[1]))
                prev = pos
            size_typing = pg.evaluate("i => { const p = window.__teng.at(i); return p && p.y; }", start)
            pg.keyboard.press("Enter")
            pos_after = line_pos(pg, start, start + len(line_text))
            steps.append({"line": line_text, "moved_after_enter": pos_after != prev})
        model = pg.evaluate("window.__teng.model.blocks.map(b => b.k)")
        rep["E_no_jump"] = {"max_drift_px": drift, "steps": steps, "blocks_after": model}
        say(f"E. 一个字一个字打两行：打的时候已出来的字最多挪了 {drift} 像素 · 换行后落定："
            + "、".join(f"{s['line']} {'变了样' if s['moved_after_enter'] else '没变'}" for s in steps) + f" · 现在认成 {model}")
        ctx.close()

        # F. 拼音组字
        ctx, pg = phone(b)
        tap_paper(pg)
        pg.keyboard.insert_text("今日产量\nA线 1280件\n")
        pg.wait_for_timeout(300)
        cdp = ctx.new_cdp_session(pg)
        snap = "() => document.querySelector('#paper-cv').getContext('2d').getImageData(0, 0, 1170, 300).data.reduce((h, v, i) => (h * 31 + v * (i % 7 + 1)) % 1000000007, 7)"
        r0, h0 = pg.evaluate("window.__teng.renders"), pg.evaluate(snap)
        comp = []
        for t in ("b", "bx", "bxi", "bxian"):
            cdp.send("Input.imeSetComposition", {"text": t, "selectionStart": len(t), "selectionEnd": len(t)})
            comp.append({"t": t, "renders": pg.evaluate("window.__teng.renders") - r0, "same_pixels": pg.evaluate(snap) == h0,
                         "composing": pg.evaluate("window.__teng.composing"), "shown": pg.evaluate("document.querySelector('#comp').hidden ? null : document.querySelector('#comp').textContent")})
        cdp.send("Input.insertText", {"text": "B线"})
        pg.keyboard.insert_text(" 960件")
        v = pg.evaluate("document.querySelector('#text').value")
        ok = all(c["renders"] == 0 and c["same_pixels"] and c["composing"] for c in comp) and v.endswith("B线 960件")
        rep["F_ime"] = {"steps": comp, "value": v, "ok": ok}
        say(f"F. 拼音组字 b→bx→bxi→bxian：纸重画 {[c['renders'] for c in comp]} 次、像素{'没变' if all(c['same_pixels'] for c in comp) else '变了'}、组的字浮在光标那儿 {[c['shown'] for c in comp]} · 上屏后最后一行 {v.splitlines()[-1]!r}")
        ctx.close()

        # H. 微信
        ctx, pg = phone(b, ua=WECHAT_UA, init=COUNT)
        tap_paper(pg)
        pg.keyboard.insert_text(TEXT)
        res = {}
        for btn in ("share", "save"):
            pg.tap(f"#{btn}")
            res[btn] = pg.evaluate("({ sheet: window.__teng.sheet, src: document.querySelector('#sheet-img').src.slice(0, 22), tip: document.querySelector('#sheet-tip').textContent, save_btn: !document.querySelector('#sheet-save').hidden, open: !document.querySelector('#sheet').hidden })")
            pg.tap("#sheet-close")
        rep["H_wechat"] = res
        say(f"H. 微信里：分享 → {res['share']['sheet']} 大图页（{res['share']['src']}…）「{res['share']['tip']}」；保存相册 → {res['save']['sheet']} 大图页；存图按钮{'有' if res['save']['save_btn'] else '藏了'}")
        ctx.close()

        # I. 电脑宽屏
        ctx = b.new_context(viewport={"width": 1280, "height": 800}, accept_downloads=True)
        ctx.grant_permissions(["clipboard-read", "clipboard-write"], origin=f"http://127.0.0.1:{port}")
        ctx.add_init_script("localStorage.clear(); delete Navigator.prototype.share; delete Navigator.prototype.canShare;")
        pg = ctx.new_page()
        pg.goto(URL)
        pg.wait_for_function("window.__teng && window.__teng.ready")
        pg.keyboard.insert_text(TEXT)        # 电脑上一打开光标就在纸上
        with pg.expect_download() as dl:
            pg.click("#save")
        d = dl.value
        path = d.path()
        toast1 = pg.evaluate("document.querySelector('#toast').textContent")
        pg.click("#share")
        pg.wait_for_function("window.__teng.copied > 0", timeout=10000)
        clip = pg.evaluate("async () => { const it = await navigator.clipboard.read(); return it.flatMap(i => i.types); }")
        toast2 = pg.evaluate("document.querySelector('#toast').textContent")
        rep["I_desktop"] = {"save": {"name": d.suggested_filename, "bytes": Path(path).stat().st_size, "toast": toast1},
                            "share": {"clipboard": clip, "bytes": pg.evaluate("window.__teng.copied"), "toast": toast2}}
        say(f"I. 电脑：保存相册 → 直接下了 {d.suggested_filename}（{Path(path).stat().st_size} 字节）「{toast1}」；分享 → 剪贴板里有 {clip}「{toast2}」")
        ctx.close()

        # J. 第一次打开下载多大
        ctx = b.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=3, is_mobile=True, has_touch=True, user_agent=IPHONE_UA)
        pg = ctx.new_page()
        sizes = []
        pg.on("requestfinished", lambda r: sizes.append((r.url, r.sizes()["responseBodySize"])))
        pg.goto(URL, wait_until="networkidle")
        pg.wait_for_function("window.__teng && window.__teng.ready")
        pg.wait_for_timeout(1500)
        first = sum(s for _, s in sizes)
        rep["J_first_open_bytes"] = first
        n0 = len(sizes)
        pg.set_input_files("#pick-album", str(ROOT / "tests" / "hand" / "h2.jpg"))
        pg.wait_for_function("window.__teng.reading === false", timeout=300_000)
        ocr = sum(s for _, s in sizes[n0:])
        rep["J_first_ocr_bytes"] = ocr
        say(f"J. 第一次打开：{n0} 个文件，{first / 1024:.0f} KB（本机不压缩）；第一次认手写又下 {ocr / 1048576:.1f} MB")
        ctx.close()

        # K. 假键盘：弹着时底下那条收起来，收了键盘再出来
        ctx, pg = phone(b, init=SHARE_MOCK + FAKE_KB)
        look = "() => { const d = document.querySelector('#dock'); return { hidden: getComputedStyle(d).visibility === 'hidden', h: d.offsetHeight, share: !!document.querySelector('#share').offsetParent && getComputedStyle(document.querySelector('#share')).visibility !== 'hidden' }; }"
        idle = pg.evaluate(look)
        tap_paper(pg)
        pg.keyboard.insert_text(TEXT)
        up = pg.evaluate(look)
        taps = 0
        pg.evaluate("document.querySelector('#text').blur()"); taps += 1      # 点键盘上的 ✓ 收键盘
        down = pg.evaluate(look)
        pg.tap("#share"); taps += 1
        pg.wait_for_function("window.__shared.length === 1")
        ok = not idle["hidden"] and up["hidden"] and not up["share"] and not down["hidden"] and down["share"]
        rep["K_keyboard_hides_dock"] = {"idle": idle, "keyboard_up": up, "keyboard_down": down, "taps": taps, "ok": ok}
        say(f"K. 假键盘：没写字时底下那条{'在' if not idle['hidden'] else '不在'}；键盘弹着{'收起来了' if up['hidden'] else '还挡着'}；"
            f"点 ✓ 收键盘后{'又出来了' if not down['hidden'] else '还没出来'} · 打字 → ✓ → 分享：点了 {taps} 下")
        ctx.close()
        b.close()
    (ROOT / "tests" / "out").mkdir(parents=True, exist_ok=True)
    (ROOT / "tests" / "out" / "phone.json").write_text(json.dumps(rep, ensure_ascii=False, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
