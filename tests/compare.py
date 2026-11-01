"""边做边比：compare.py 轮次  → 9 个版式各出两段示范文字，跟对标的参照并排，存 docs/对比/<轮次>_<版式>_对<参照>.png
参照图只在本机（docs/参照/，不进仓库）。"""
import base64
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).parent))
from serve import serve  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
REF = ROOT / "docs" / "参照"
OUT = ROOT / "docs" / "对比"
TEXTS = {
    "产量": "11月1日 各线产量\nA线早班 1,280件\nB线早班 960件\nC线中班 1,105件\nD线晚班 87件\n合计 3,432件\n\n明天上午8点到12点停电检修，请各线提前把数据存好。",
    "通知": "【通知】下周六停电检修\n各车间：\n因供电线路改造，下周六全厂停电检修，请提前安排好生产。\n时间：11月8日 8:00-17:00\n地点：全厂\n联系人：设备科 老王\n1. 提前保存电脑里的数据\n2. 关掉不用的设备电源\n3. 冷库提前降温，检修期间少开门，别让货化了\n\n设备科\n2026年11月1日",
}
# 每个版式对标哪张参照
PAIRS = {"note": "R01_Things3_清单_ADA2017", "white": "R03_apple_iPad备忘录", "letter": "R06_TDC71_最佳奖", "kraft": "R05_RedDot2025_Chikaku",
         "night": "R04_ADA2026_页面排版", "mag": "R03_apple_iPad备忘录", "journal": "R02_Bear_笔记_ADA", "big": "R04_ADA2026_页面排版",
         "notice": "R07_RedDot_获奖列表排版"}
FONT = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 22)


def main():
    rnd = sys.argv[1]
    only = sys.argv[2:]
    srv, port = serve()
    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge")
        pg = b.new_page()
        pg.goto(f"http://127.0.0.1:{port}/tengchao/index.html")
        pg.wait_for_function("window.__teng && window.__teng.ready")
        for th, ref in PAIRS.items():
            if only and th not in only:
                continue
            ims = []
            for name, t in TEXTS.items():
                pg.evaluate("([th, t]) => window.__teng.ensureFonts(th, t)", [th, t])
                r = pg.evaluate("([t, th]) => window.__teng.render(t, th)", [t, th])
                tmp = OUT / f"_{th}_{name}.png"
                tmp.write_bytes(base64.b64decode(r["url"].split(",")[1]))
                ims.append(Image.open(tmp).convert("RGB"))
                tmp.unlink()
            H = 1100
            ims = [im.resize((round(im.width * H / im.height), H)) if im.height > H else im for im in ims]
            ref_im = Image.open(REF / f"{ref}.png").convert("RGB")
            ref_im = ref_im.resize((round(ref_im.width * H / ref_im.height), H)) if ref_im.height > H else ref_im
            g = Image.new("RGB", (sum(i.width for i in ims) + ref_im.width + 80, H + 50), "#E9E9EC")
            d = ImageDraw.Draw(g)
            x = 20
            for (name, _), im in zip(TEXTS.items(), ims):
                d.text((x, 10), f"誊抄僧 · {th} · {name}", fill="#1d1d1f", font=FONT)
                g.paste(im, (x, 44)); x += im.width + 20
            d.text((x, 10), f"参照 · {ref}", fill="#6e6e73", font=FONT)
            g.paste(ref_im, (x, 44))
            out = OUT / f"{rnd}_{th}_对{ref.split('_')[0]}.png"
            g.save(out, optimize=True)
            print(out.name, g.size)
        b.close()


if __name__ == "__main__":
    main()
