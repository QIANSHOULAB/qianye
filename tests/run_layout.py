"""排版测试：tests/texts.json 里 20 段打字的字，逐段比：
- 标题认对没有（答案写的是原文那一行，【】算对）；
- 「名字＋数字」几行、键值几行、带序号/圆点的清单几条、落款有没有；
- 对齐：每组「名字＋数字」的数，个位（小数点）是不是在同一条竖线上，单位是不是左齐；9 个版式都查；
- 出图用时：按 3 倍屏画、转 PNG，每段每个版式一次。
结果写 tests/out/layout.json，打印一张表。"""
import json
import statistics
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).parent))
from serve import serve  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
CASES = json.loads((ROOT / "tests" / "texts.json").read_text(encoding="utf-8"))

JS = """async ([text, themes]) => {
  const T = window.__teng, m = T.parse(text);
  const k = (n) => m.blocks.filter((b) => b.k === n);
  const rows = k('rows').flatMap((b) => b.items), kvs = k('kvs').flatMap((b) => b.items);
  const out = { title: (m.blocks.find((b) => b.k === 'title') || {}).id ?? null,
    titleText: (m.blocks.find((b) => b.k === 'title') || {}).s ?? null,
    rows: rows.filter((r) => r.num).length + rows.filter((r) => !r.num && r.marker).length, kv: kvs.length,
    list: rows.filter((r) => r.marker).length, sign: k('sign').length > 0, align: {}, ms: {} };
  for (const th of themes) {
    await T.ensureFonts(th, text);
    const L = T.layout(m, T.THEMES.find((t) => t.id === th));
    // 每组「名字＋数字」：数的整数部分右对齐的 x 应该全一样；单位左对齐的 x 也一样
    let ok = true, groups = 0;
    for (const b of k('rows')) {
      const nums = b.items.filter((it) => it.num);
      if (!nums.length) continue;
      groups++;
      const xs = L.ops.filter((o) => o.k === 'text' && o.align === 'right' && nums.some((it) => it.num.int === o.s)).map((o) => o.x);
      const us = L.ops.filter((o) => o.k === 'text' && o.align === 'left' && nums.some((it) => it.unit && it.unit === o.s)).map((o) => o.x);
      if (xs.length < nums.length || Math.max(...xs) - Math.min(...xs) > 0.01) ok = false;
      if (us.length && Math.max(...us) - Math.min(...us) > 0.01) ok = false;
    }
    out.align[th] = groups ? ok : null;
    const t0 = performance.now();
    const cv = document.createElement('canvas');
    const R = T.render(text, th, 'auto', 3);
    out.ms[th] = Math.round(performance.now() - t0);
    out.h = R.H;
  }
  return out;
}"""


def main():
    srv, port = serve()
    rep, n_title, n_struct, n_align, n_align_all = {}, 0, 0, 0, 0
    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge")
        pg = b.new_page(viewport={"width": 390, "height": 844}, device_scale_factor=3)
        pg.goto(f"http://127.0.0.1:{port}/qianye/index.html")
        pg.wait_for_function("window.__teng && window.__teng.ready")
        themes = pg.evaluate("window.__teng.THEMES.map((t) => t.id)")
        for c in CASES:
            r = pg.evaluate(JS, [c["text"], themes])
            lines = c["text"].split("\n")
            want_title = c["title"]
            got_title = r["titleText"]
            norm = lambda x: x.strip("：:").strip("【】[]")
            t_ok = (want_title is None and got_title is None) or (want_title is not None and got_title is not None and norm(got_title) == norm(want_title))
            s_ok = r["rows"] == c["rows"] and r["kv"] == c["kv"] and r["list"] == c["list"] and r["sign"] == c["sign"]
            al = [v for v in r["align"].values() if v is not None]
            a_ok = all(al) if al else None
            n_title += t_ok; n_struct += s_ok
            if a_ok is not None:
                n_align += 1; n_align_all += a_ok
            rep[c["id"]] = {**r, "title_ok": t_ok, "struct_ok": s_ok, "align_ok": a_ok, "want": {k: c[k] for k in ("title", "rows", "kv", "list", "sign")}, "got_title": got_title}
            print(f"{c['id']:<12} 标题{'✓' if t_ok else '✗'}（{got_title!r}）结构{'✓' if s_ok else '✗'}（行{r['rows']}/{c['rows']} 键值{r['kv']}/{c['kv']} 清单{r['list']}/{c['list']} 落款{r['sign']}）"
                  f" 对齐{'—' if a_ok is None else ('✓' if a_ok else '✗')} · 出图 {statistics.median(r['ms'].values())}ms", flush=True)
        b.close()
    ms = [v for r in rep.values() for v in r["ms"].values()]
    print(f"\n标题认对 {n_title}/{len(CASES)}；结构全对 {n_struct}/{len(CASES)}；有「名字＋数字」的 {n_align} 段里，9 个版式都对齐的 {n_align_all} 段")
    print(f"出图（3 倍屏，{len(ms)} 张）：中位 {statistics.median(ms)}ms，最慢 {max(ms)}ms")
    (ROOT / "tests" / "out").mkdir(parents=True, exist_ok=True)
    (ROOT / "tests" / "out" / "layout.json").write_text(json.dumps(rep, ensure_ascii=False, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
