"""手写认字测试：tests/hand/hN.jpg 从「相册」喂进誊抄僧（不贴钥匙 = 本地认），写字框里的字跟 hN.txt 逐字比。
准确率 = 1 − 编辑距离 / 答案字数（不算空白）。另报：标黄的字里有几个真是错的、错字里有几个标了黄。
结果写 tests/out/ocr.json。"""
import json
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).parent))
from serve import serve  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
HAND = ROOT / "tests" / "hand"
OUT = ROOT / "tests" / "out"


def align(a, b):
    """编辑距离，外加 a 里每个字是不是「对上了」"""
    n, m = len(a), len(b)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        d[i][0] = i
    for j in range(m + 1):
        d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] != b[j - 1]))
    ok = [False] * n
    i, j = n, m
    while i > 0 and j > 0:
        if a[i - 1] == b[j - 1] and d[i][j] == d[i - 1][j - 1]:
            ok[i - 1] = True; i -= 1; j -= 1
        elif d[i][j] == d[i - 1][j - 1] + 1:
            i -= 1; j -= 1
        elif d[i][j] == d[i - 1][j] + 1:
            i -= 1
        else:
            j -= 1
    return d[n][m], ok


def main():
    want = sys.argv[1:]
    OUT.mkdir(parents=True, exist_ok=True)
    srv, port = serve()
    rep = {}
    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge")
        ctx = b.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=3, is_mobile=True, has_touch=True)
        for jpg in sorted(HAND.glob("h*.jpg")):
            if want and jpg.stem not in want:
                continue
            truth = (HAND / f"{jpg.stem}.txt").read_text(encoding="utf-8")
            pg = ctx.new_page()
            pg.goto(f"http://127.0.0.1:{port}/tengchao/index.html")
            pg.wait_for_function("window.__teng && window.__teng.ready")
            pg.evaluate("localStorage.clear(); document.querySelector('#text').value=''; document.querySelector('#text').dispatchEvent(new Event('input'))")
            t0 = time.time()
            pg.set_input_files("#pick-album", str(jpg))
            pg.wait_for_function("window.__teng.reading === false", timeout=300_000)
            secs = round(time.time() - t0, 1)
            got = pg.input_value("#text")
            marks = pg.evaluate("window.__teng.marks || []")
            info = pg.evaluate("window.__teng.ocr || {}")
            status = pg.inner_text("#status")
            # 逐字比（去掉空白），标黄的位置也换算到去空白以后
            keep = [i for i, ch in enumerate(got) if not ch.isspace()]
            g = "".join(got[i] for i in keep)
            t = "".join(ch for ch in truth if not ch.isspace())
            dist, ok = align(g, t)
            marked = set()
            for a, z in marks:
                marked.update(range(a, z))
            mk = [keep.index(i) for i in marked if i in keep]
            wrong = [k for k, v in enumerate(ok) if not v]
            rep[jpg.stem] = {"acc": round(1 - dist / max(1, len(t)), 3), "dist": dist, "chars": len(t), "seconds": secs,
                             "marked": len(mk), "marked_wrong": sum(1 for k in mk if not ok[k]), "wrong": len(wrong),
                             "wrong_marked": sum(1 for k in wrong if k in mk), "got": got, "truth": truth, "ocr": info, "status": status}
            r = rep[jpg.stem]
            print(f"{jpg.stem} 准 {r['acc']:.0%}（错 {dist}/{len(t)}）标黄 {r['marked']}（其中真错 {r['marked_wrong']}）错字里标了黄 {r['wrong_marked']}/{r['wrong']} · {secs}s", flush=True)
            print("   认出：", got.replace("\n", " / "))
            pg.close()
        b.close()
    tot_d = sum(r["dist"] for r in rep.values()); tot_c = sum(r["chars"] for r in rep.values())
    print(f"合计 准 {1 - tot_d / max(1, tot_c):.1%}（错 {tot_d}/{tot_c}）")
    (OUT / "ocr.json").write_text(json.dumps(rep, ensure_ascii=False, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
