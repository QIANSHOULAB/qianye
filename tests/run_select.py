"""选字、复制、粘贴（0.3.6，Song 11-07：「无法选中复制」）。iPhone 尺寸触屏真点，电脑尺寸真鼠标。
L1 双击一个数：选中这个数，把手两个、上面「复制 / 全选」一条；点「复制」，剪贴板里就是这个数
L2 三击一行：选中整行（不带换行）；点「全选」再「复制」，剪贴板里是全文
L3 拖结尾的把手到最后一行：选区跟着变长，开头不动；放手后那一条又出来
L4 点一下光标在的地方：弹「全选 / 粘贴」；点「粘贴」，剪贴板里的字插在光标那儿
L5 选中以后打字：那一条和把手收起，选中的字被换掉
L6 长按一行照旧是「这行当标题」，不弹那一条
L7 电脑：双击选词、三击选行；右键按下时看不见的写字框在鼠标底下（弹的是浏览器自己的剪切 / 复制 / 粘贴），选区不丢；菜单关了写字框回光标那儿
结果写 tests/out/select.json。"""
import json
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).parent))
from serve import serve, browser, LANG_JS  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
IPHONE_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
TEXT = "今日产量\nA线 1280件\nB线 960件\n合计 2240件"


def open_page(b, url, phone=True):
    if phone:
        ctx = b.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=3, is_mobile=True, has_touch=True, user_agent=IPHONE_UA)
    else:
        ctx = b.new_context(viewport={"width": 1280, "height": 900})
    ctx.grant_permissions(["clipboard-read", "clipboard-write"], origin=url.split("/qianye/")[0])
    ctx.add_init_script("localStorage.clear();" + LANG_JS)
    pg = ctx.new_page()
    errors = []
    pg.on("pageerror", lambda e: errors.append(str(e)))
    pg.goto(url)
    pg.wait_for_function("window.__teng && window.__teng.ready")
    return ctx, pg, errors


def at(pg, i):
    return pg.evaluate("i => window.__teng.at(i)", i)


def taps(pg, i, n):
    p = at(pg, i)
    for _ in range(n):
        pg.touchscreen.tap(p["x"] + 2, p["y"])
        pg.wait_for_timeout(60)
    pg.wait_for_timeout(150)


def state(pg):
    return pg.evaluate("""() => { const t = document.querySelector('#text'); const vis = (id) => { const e = document.getElementById(id); return !!e && !e.hidden && e.offsetParent !== null; };
      return { sel: [t.selectionStart, t.selectionEnd], s: t.value.slice(t.selectionStart, t.selectionEnd), ebar: window.__teng.ebar,
               copy: vis('eb-copy'), all: vis('eb-all'), paste: vis('eb-paste'), knobs: vis('kn-a') && vis('kn-b'), focused: document.activeElement === t,
               barBox: (() => { const r = document.getElementById('ebar').getBoundingClientRect(); return [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)]; })(),
               paper: (() => { const r = document.getElementById('paper').getBoundingClientRect(); return [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)]; })() }; }""")


def clip(pg):
    return pg.evaluate("navigator.clipboard.readText()")


def touch_drag(pg, x0, y0, x1, y1, steps=8):
    cdp = pg.context.new_cdp_session(pg)
    pts = lambda x, y: [{"x": x, "y": y, "id": 1}]
    cdp.send("Input.dispatchTouchEvent", {"type": "touchStart", "touchPoints": pts(x0, y0)})
    for k in range(1, steps + 1):
        cdp.send("Input.dispatchTouchEvent", {"type": "touchMove", "touchPoints": pts(x0 + (x1 - x0) * k / steps, y0 + (y1 - y0) * k / steps)})
        pg.wait_for_timeout(16)
    cdp.send("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []})
    pg.wait_for_timeout(200)


def long_press(pg, x, y, ms=700):
    cdp = pg.context.new_cdp_session(pg)
    cdp.send("Input.dispatchTouchEvent", {"type": "touchStart", "touchPoints": [{"x": x, "y": y, "id": 1}]})
    pg.wait_for_timeout(ms)
    cdp.send("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []})
    pg.wait_for_timeout(250)


def main():
    srv, port = serve()
    url = f"http://127.0.0.1:{port}/qianye/index.html"
    rep, ok = {}, {}
    say = lambda *a: print(*a, flush=True)
    i1280 = TEXT.index("1280")
    iB = TEXT.index("B线")
    with sync_playwright() as p:
        b = browser(p)

        ctx, pg, errs = open_page(b, url)
        bb = pg.locator("#paper-cv").bounding_box()
        pg.touchscreen.tap(bb["x"] + bb["width"] / 2, bb["y"] + bb["height"] * 0.6)
        pg.keyboard.insert_text(TEXT)
        pg.wait_for_timeout(400)

        # L1 双击一个数
        taps(pg, i1280 + 1, 2)
        st = state(pg)
        bar_ok = st["paper"][0] <= st["barBox"][0] and st["barBox"][0] + st["barBox"][2] <= st["paper"][0] + st["paper"][2]
        pg.tap("#eb-copy")
        pg.wait_for_timeout(250)
        st2 = state(pg)
        c = clip(pg)
        msg = pg.text_content("#eb-msg")
        ok["L1"] = st["s"] == "1280" and st["ebar"] == "sel" and st["copy"] and st["knobs"] and bar_ok and c == "1280" and st2["sel"] == st["sel"] and st2["focused"]
        rep["L1_double_tap"] = {"selected": st["s"], "bar": st["ebar"], "knobs": st["knobs"], "bar_inside_paper": bar_ok, "clipboard": c, "msg": msg, "sel_kept": st2["sel"] == st["sel"]}
        say(f"L1 双击「1280」：选中「{st['s']}」 · 那一条 {st['ebar']} · 把手 {'在' if st['knobs'] else '没有'} · 点复制后剪贴板「{c}」· 提示「{msg}」 → {'过' if ok['L1'] else '没过'}")

        # L2 三击一行，再全选、复制
        pg.wait_for_timeout(1000)
        taps(pg, iB + 1, 3)
        st = state(pg)
        line_ok = st["s"] == "B线 960件"
        pg.tap("#eb-all")
        pg.wait_for_timeout(150)
        sa = state(pg)
        pg.tap("#eb-copy")
        pg.wait_for_timeout(250)
        c = clip(pg)
        ok["L2"] = line_ok and sa["sel"] == [0, len(TEXT)] and not sa["all"] and c == TEXT
        rep["L2_triple_tap"] = {"selected": st["s"], "after_select_all": sa["sel"], "select_all_hidden_when_all": not sa["all"], "clipboard_is_all": c == TEXT}
        say(f"L2 三击第三行：选中「{st['s']}」 · 全选后 {sa['sel']} · 复制后剪贴板是全文：{c == TEXT} → {'过' if ok['L2'] else '没过'}")

        # L3 拖结尾的把手
        pg.wait_for_timeout(1000)
        taps(pg, TEXT.index("960") + 1, 2)
        st = state(pg)
        kb = pg.evaluate("window.__teng.knob('b')")
        last = at(pg, len(TEXT))
        p_end = pg.evaluate("i => { const p = window.__teng.at(i); return p; }", len(TEXT))
        # 手指按在圆点上往下拖，拖到最后一行行尾下面一点（圆点在字下面）
        dy = kb["y"] - at(pg, st["sel"][1])["y"]
        touch_drag(pg, kb["x"], kb["y"], last["x"] + 4, p_end["y"] + dy)
        sd = state(pg)
        ok["L3"] = st["s"] == "960" and sd["sel"][0] == st["sel"][0] and sd["sel"][1] == len(TEXT) and sd["ebar"] == "sel"
        rep["L3_drag_end_knob"] = {"before": st["s"], "after": sd["s"], "start_kept": sd["sel"][0] == st["sel"][0], "bar_back": sd["ebar"]}
        say(f"L3 拖结尾把手：「{st['s']}」→「{sd['s']}」 · 开头不动：{sd['sel'][0] == st['sel'][0]} · 放手后那一条 {sd['ebar']} → {'过' if ok['L3'] else '没过'}")

        # L4 点光标 → 粘贴
        pg.evaluate("navigator.clipboard.writeText('（已核）')")
        pg.wait_for_timeout(500)
        end4 = TEXT.index("\n合计")
        tap = at(pg, end4)
        pg.touchscreen.tap(tap["x"] + 1, tap["y"])
        pg.wait_for_timeout(600)
        c1 = state(pg)
        pg.touchscreen.tap(tap["x"] + 1, tap["y"])
        pg.wait_for_timeout(200)
        st = state(pg)
        pg.tap("#eb-paste")
        pg.wait_for_timeout(400)
        v = pg.evaluate("document.querySelector('#text').value")
        ok["L4"] = c1["sel"] == [end4, end4] and st["ebar"] == "caret" and st["paste"] and st["all"] and not st["copy"] and v == TEXT[:end4] + "（已核）" + TEXT[end4:]
        rep["L4_caret_paste"] = {"caret": c1["sel"], "bar": st["ebar"], "buttons": {"paste": st["paste"], "all": st["all"], "copy": st["copy"]}, "pasted_right_place": v == TEXT[:end4] + "（已核）" + TEXT[end4:]}
        say(f"L4 点光标：那一条 {st['ebar']}（粘贴 {st['paste']}、全选 {st['all']}、复制 {st['copy']}） · 粘贴进光标那儿：{rep['L4_caret_paste']['pasted_right_place']} → {'过' if ok['L4'] else '没过'}")

        # L5 选中以后打字
        pg.wait_for_timeout(600)
        v0 = pg.evaluate("document.querySelector('#text').value")
        j = v0.index("2240")
        taps(pg, j + 1, 2)
        pg.keyboard.insert_text("2241")
        pg.wait_for_timeout(200)
        st = state(pg)
        v = pg.evaluate("document.querySelector('#text').value")
        ok["L5"] = st["ebar"] is None and not st["knobs"] and v == v0.replace("2240", "2241")
        rep["L5_type_over"] = {"bar": st["ebar"], "knobs": st["knobs"], "replaced": v == v0.replace("2240", "2241")}
        say(f"L5 选中「2240」打 2241：那一条 {st['ebar']} · 把手 {st['knobs']} · 换掉了：{rep['L5_type_over']['replaced']} → {'过' if ok['L5'] else '没过'}")

        # L6 长按一行照旧当标题
        pg.wait_for_timeout(600)
        q = at(pg, iB + 1)
        long_press(pg, q["x"], q["y"])
        st = state(pg)
        title = pg.evaluate("window.__teng.model && window.__teng.model.title")
        log = pg.evaluate("window.__teng.log.slice(-1)[0]")
        ok["L6"] = st["ebar"] is None and log in ("好，这行当标题", "OK, that’s the title now.") or (st["ebar"] is None and "标题" in (log or ""))
        rep["L6_long_press_title"] = {"bar": st["ebar"], "status": log, "title": title}
        say(f"L6 长按第三行：那一条 {st['ebar']} · 提示「{log}」 → {'过' if ok['L6'] else '没过'}")
        rep["phone_page_errors"] = errs
        ctx.close()

        # L7 电脑
        ctx, pg, errs = open_page(b, url, phone=False)
        bb = pg.locator("#paper-cv").bounding_box()
        pg.mouse.click(bb["x"] + bb["width"] / 2, bb["y"] + 60)
        pg.keyboard.insert_text(TEXT)
        pg.wait_for_timeout(300)
        q = at(pg, i1280 + 1)
        pg.mouse.dblclick(q["x"], q["y"])
        pg.wait_for_timeout(150)
        dbl = state(pg)
        q3 = at(pg, iB + 1)
        pg.mouse.click(q3["x"], q3["y"], click_count=3)
        pg.wait_for_timeout(150)
        tri = state(pg)
        pg.evaluate("""() => { window.__ctx = null; document.addEventListener('contextmenu', (e) => {
          const t = document.querySelector('#text'), u = document.elementFromPoint(e.clientX, e.clientY);
          window.__ctx = { target: e.target.id, under: u && u.id, prevented: null, sel: [t.selectionStart, t.selectionEnd] };
          setTimeout(() => { window.__ctx.prevented = e.defaultPrevented; }, 0); }, true); }""")
        q4 = at(pg, iB + 3)
        pg.mouse.click(q4["x"], q4["y"], button="right")
        pg.wait_for_timeout(30)
        cm = pg.evaluate("window.__ctx")
        pg.wait_for_timeout(200)
        back = pg.evaluate("() => { const t = document.querySelector('#text'); return { ctx: t.classList.contains('ctx'), pe: getComputedStyle(t).pointerEvents }; }")
        pg.keyboard.press("Control+c")
        pg.wait_for_timeout(150)
        c = clip(pg)
        ok["L7"] = dbl["s"] == "1280" and dbl["ebar"] is None and tri["s"] == "B线 960件" and cm and cm["under"] == "text" and cm["prevented"] is False and cm["sel"] == tri["sel"] and not back["ctx"] and back["pe"] == "none" and c == "B线 960件"
        rep["L7_desktop"] = {"dblclick": dbl["s"], "no_bar_on_desktop": dbl["ebar"] is None, "triple_click": tri["s"], "contextmenu": cm, "after_menu": back, "ctrl_c": c}
        say(f"L7 电脑：双击「{dbl['s']}」、三击「{tri['s']}」 · 右键时鼠标底下是 {cm and cm['under']}，没拦浏览器菜单：{cm and cm['prevented'] is False} · 选区不丢：{cm and cm['sel'] == tri['sel']} · 菜单后写字框回原处：{not back['ctx']} · Ctrl+C「{c}」 → {'过' if ok['L7'] else '没过'}")
        rep["desktop_page_errors"] = errs
        ctx.close()
        b.close()
    srv.shutdown()
    rep["pass"] = ok
    out = ROOT / "tests" / "out"
    out.mkdir(exist_ok=True)
    (out / "select.json").write_text(json.dumps(rep, ensure_ascii=False, indent=1), encoding="utf-8")
    n = sum(ok.values())
    say(f"选字 {n}/{len(ok)} 过" + ("" if n == len(ok) else f"，没过：{[k for k, v in ok.items() if not v]}") + f" · 页面报错 {len(rep['phone_page_errors']) + len(rep['desktop_page_errors'])} 条")
    sys.exit(0 if n == len(ok) else 1)


if __name__ == "__main__":
    main()
