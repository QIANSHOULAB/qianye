"""贴钥匙那条路（假谷歌）：认对、两遍不一样标黄、每分钟额度、当天额度、断网、钥匙无效、模型不存在、回来的不是 JSON。
喂的都是 tests/hand/h2.jpg。结果写 tests/out/gemini.json。"""
import json
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).parent))
import serve as SV  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
IMG = ROOT / "tests" / "hand" / "h2.jpg"
TRUTH = "采购清单\n1. 螺丝 200个\n2. 垫片 50个\n3. 胶带 12卷\n4. 手套 30双"
CASES = [
    ("认对", ["ok_1"], None, None),
    ("两遍不一样 → 标黄", ["split_1"], None, None),
    ("每分钟额度到顶 → 等一下再认", ["minute_1"], None, None),
    ("当天额度用完（两把都）→ 本地认", ["day_1", "day_2"], None, None),
    ("断网 → 本地认", ["ok_2"], None, "http://127.0.0.1:9/v1beta"),
    ("钥匙无效 → 本地认", ["bad_1"], None, None),
    ("模型不存在 → 本地认", ["ok_3"], "gemini-nope", None),
    ("回来的不是 JSON → 本地认", ["html_1"], None, None),
]


def main():
    SV.FAKE["text"] = TRUTH
    SV.FAKE["text2"] = TRUTH.replace("垫片", "垫斤").replace("30双", "38双")
    srv, port = SV.serve()
    rep = {}
    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge")
        ctx = b.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=2, is_mobile=True, has_touch=True)
        for name, keys, model, api in CASES:
            pg = ctx.new_page()
            init = f"localStorage.clear(); localStorage.setItem('tengchao.k1', {json.dumps(keys[0])});"
            if len(keys) > 1:
                init += f"localStorage.setItem('tengchao.k2', {json.dumps(keys[1])});"
            if model:
                init += f"localStorage.setItem('tengchao.model', {json.dumps(model)});"
            pg.add_init_script(init)
            pg.goto(f"http://127.0.0.1:{port}/tengchao/index.html?fast=1&api={api or f'http://127.0.0.1:{port}/v1beta'}")
            pg.wait_for_function("window.__teng && window.__teng.ready")
            pg.set_input_files("#pick-album", str(IMG))
            pg.wait_for_function("window.__teng.reading === false", timeout=300_000)
            r = {"via": pg.evaluate("window.__teng.via"), "status": pg.inner_text("#status"), "text": pg.input_value("#text"),
                 "marks": pg.evaluate("window.__teng.marks || []"), "log": pg.evaluate("window.__teng.log.slice(-4)")}
            r["text_ok"] = "".join(r["text"].split()) == "".join(TRUTH.split())
            rep[name] = r
            print(f"{name}：走 {r['via']} · 字{'对' if r['text_ok'] else '不对'} · 标黄 {len(r['marks'])} 段 · {r['status'][:120]!r}", flush=True)
            pg.close()
        b.close()
    (ROOT / "tests" / "out").mkdir(parents=True, exist_ok=True)
    (ROOT / "tests" / "out" / "gemini.json").write_text(json.dumps(rep, ensure_ascii=False, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
