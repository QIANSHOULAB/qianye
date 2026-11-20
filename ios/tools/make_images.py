#!/usr/bin/env python3
"""一叶笺 iPhone 版要用的图，全部自己画（不用锤子的图标、纸纹、字体）：
  1. app 图标：ios/Yiye/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png（同一张拷到 ios/icon.png 给 SideStore 源用）
  2. 认字样张 10 张：ios/tools/ocr-samples/p1–p5（印刷：通知、清单、名字＋数字、中英混排、表格）、h1–h5（手写体字体生成，歪着、带阴影）
     每张配 .txt 标准答案。手写体用 Google Fonts 的开源字体（龙藏、马善政、智莽行、流江毛草、站酷快乐体）
  3. 截图用的图：ios/Yiye/Demo/ocr-demo-zh.jpg、ocr-demo-en.jpg、handover.jpg
用法：python3 ios/tools/make_images.py <字体目录>   （字体目录里放上面几个 .ttf；Noto CJK 用系统里的）"""
import math, random, sys, pathlib
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = pathlib.Path(__file__).resolve().parents[1]
FONTS = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/fonts")
NOTO = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"
NOTO_B = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"
NOTO_SERIF = "/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc"


def cjk(path, size):
    """Noto CJK 的 .ttc 里挑简体中文那一套"""
    for i in range(10):
        try:
            f = ImageFont.truetype(path, size, index=i)
        except OSError:
            break
        if "SC" in " ".join(f.getname()):
            return f
    return ImageFont.truetype(path, size)


# ================================================================ 拍照效果（跟网页版 tests/make_hand.py 一样的办法）
def solve(a, b):
    n = len(b)
    m = [row[:] + [b[i]] for i, row in enumerate(a)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(m[r][c]))
        m[c], m[p] = m[p], m[c]
        for r in range(n):
            if r != c:
                f = m[r][c] / m[c][c]
                m[r] = [x - f * y for x, y in zip(m[r], m[c])]
    return [m[i][n] / m[i][i] for i in range(n)]


def persp_coeffs(src, dst):
    a, b = [], []
    for (x, y), (u, v) in zip(dst, src):
        a.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); b.append(u)
        a.append([0, 0, 0, x, y, 1, -v * x, -v * y]); b.append(v)
    return solve(a, b)


def photo(paper, seed, tilt, shade=0.32, W=1200, H=1600):
    rnd = random.Random(seed)
    desk = Image.new("RGB", (W, H), (rnd.randint(120, 150), rnd.randint(100, 118), rnd.randint(80, 95)))
    dd = ImageDraw.Draw(desk)
    for i in range(0, H, 7):
        c = rnd.randint(-14, 14)
        dd.line([(0, i), (W, i + rnd.randint(-20, 20))], fill=(130 + c, 108 + c, 86 + c), width=3)
    pw, ph = paper.size
    k = 0.82 * W / pw
    paper = paper.resize((int(pw * k), int(ph * k)), Image.LANCZOS)
    pw, ph = paper.size
    ox, oy = (W - pw) // 2, (H - ph) // 2
    tx, ty = tilt
    dst = [(ox + pw * tx, oy + ph * ty * 0.5), (ox + pw * (1 - tx * 0.3), oy), (ox + pw * (1 + tx * 0.2), oy + ph * (1 - ty * 0.2)), (ox - pw * tx * 0.4, oy + ph)]
    src = [(0, 0), (pw, 0), (pw, ph), (0, ph)]
    co = persp_coeffs(src, dst)
    mask = Image.new("L", paper.size, 255)
    warped = paper.transform((W, H), Image.PERSPECTIVE, co, Image.BICUBIC, fillcolor=(0, 0, 0))
    wmask = mask.transform((W, H), Image.PERSPECTIVE, co, Image.BICUBIC, fillcolor=0)
    shadow = wmask.filter(ImageFilter.GaussianBlur(16)).point(lambda v: int(v * 0.45))
    desk.paste((40, 30, 20), (12, 16), shadow)
    desk.paste(warped, (0, 0), wmask)
    # 一侧暗一点（手机挡了光）
    g = Image.linear_gradient("L").resize((W, H)).rotate(rnd.choice([30, 120, 210]), expand=False)
    dark = Image.new("RGB", (W, H), (0, 0, 0))
    desk = Image.composite(dark, desk, g.point(lambda v: int(v * shade)))
    desk = desk.filter(ImageFilter.GaussianBlur(1.0))
    noise = Image.effect_noise((W, H), 18).convert("RGB")
    return Image.blend(desk, noise, 0.06)


# ================================================================ 纸
def printed_page(lines, title_size=58, size=40, table=False, seed=0):
    """印刷体：白纸，标题粗一点。table=True 画成两列的表格"""
    W, H = 900, 1180
    pg = Image.new("RGB", (W, H), (250, 249, 245))
    d = ImageDraw.Draw(pg)
    ft, fb = cjk(NOTO_B, title_size), cjk(NOTO, size)
    y = 90
    d.text((80, y), lines[0], font=ft, fill=(25, 25, 25))
    y += title_size + 48
    if table:
        rows = [l.split(" ", 1) for l in lines[1:]]
        x0, x1, xm, rh = 80, W - 80, 430, size + 34
        d.rectangle([x0, y, x1, y + rh * len(rows)], outline=(60, 60, 60), width=3)
        for i, (a, b) in enumerate(rows):
            if i:
                d.line([(x0, y + rh * i), (x1, y + rh * i)], fill=(90, 90, 90), width=2)
            d.text((x0 + 24, y + rh * i + 14), a, font=fb, fill=(30, 30, 30))
            d.text((xm + 24, y + rh * i + 14), b, font=fb, fill=(30, 30, 30))
        d.line([(xm, y), (xm, y + rh * len(rows))], fill=(90, 90, 90), width=2)
        return pg
    for l in lines[1:]:
        # 长句按宽度折行
        cur = ""
        for ch in l:
            if d.textlength(cur + ch, font=fb) > W - 160:
                d.text((80, y), cur, font=fb, fill=(35, 35, 35)); y += size + 26; cur = ""
            cur += ch
        d.text((80, y), cur, font=fb, fill=(35, 35, 35))
        y += size + 30
    return pg


def hand_page(lines, font_path, ink, seed, size=58, title=66):
    """手写体：横线本（蓝线、红边线），每行歪一点、挪一点"""
    rnd = random.Random(seed)
    W, H = 900, 1150
    pg = Image.new("RGB", (W, H), (251, 250, 244))
    d = ImageDraw.Draw(pg)
    for y in range(92, H, 94):
        d.rectangle([0, y, W, y + 2], fill=(185, 200, 224))
    d.rectangle([84, 0, 86, H], fill=(232, 162, 162))
    y = 120 - 94
    for i, l in enumerate(lines):
        fs = title if i == 0 else int(rnd.uniform(size - 4, size + 4))
        f = ImageFont.truetype(str(font_path), fs)
        tw = int(d.textlength(l, font=f)) + 40
        layer = Image.new("RGBA", (max(tw, 10), 120), (0, 0, 0, 0))
        ImageDraw.Draw(layer).text((10, 10), l, font=f, fill=ink + (255,))
        layer = layer.rotate(rnd.uniform(-1.8, 1.8), resample=Image.BICUBIC, expand=True)
        pg.paste(layer, (int(110 + rnd.uniform(-6, 12)), int(y + rnd.uniform(-4, 6))), layer)
        y += 94
    return pg


PRINTED = [
    ("p1", "通知\n各车间：\n明天上午8点在二楼会议室开安全生产会议，请各车间主任准时参加。\n请带上本月的安全检查记录。\n行政部\n11月20日", {}, (0.03, 0.02)),
    ("p2", "周末采购\n□ 牛奶 2盒\n□ 鸡蛋 1盒\n□ 洗衣液 1瓶\n□ 猫粮 3袋\n□ 卫生纸 2提", {}, (0.05, 0.03)),
    ("p3", "11月18日产量\nA线早班 1,280件\nB线早班 960件\nC线早班 1,105件\nD线早班 870件\n合计 4,215件", {}, (0.04, 0.05)),
    ("p4", "Q4 发货计划\nSKU-2041 蓝色款 320 pcs\nSKU-2042 灰色款 180 pcs\nSKU-3107 礼盒装 75 pcs\n交期：12月5日\n联系人：Lisa Wang", {}, (0.06, 0.02)),
    ("p5", "本月出勤\n张师傅 22天\n李师傅 20天\n王师傅 21天\n赵师傅 19天\n刘师傅 22天", {"table": True}, (0.03, 0.04)),
]
HAND = [
    ("h1", "LongCang-Regular.ttf", (28, 47, 110), "11月2日产量\nA线 1280件\nB线 960件\nC线 1105件\n合计 3345件", (0.06, 0.03)),
    ("h2", "MaShanZheng-Regular.ttf", (17, 17, 17), "采购清单\n1. 螺丝 200个\n2. 垫片 50个\n3. 胶带 12卷\n4. 手套 30双", (0.04, 0.05)),
    ("h3", "ZhiMangXing-Regular.ttf", (17, 17, 17), "明天早上8点开会\n地点：二楼会议室\n带上本周的报表", (0.05, 0.02)),
    ("h4", "LiuJianMaoCao-Regular.ttf", (28, 47, 110), "交接班\n3号机换了刀\n冷却液快没了\n晚班记得加", (0.08, 0.06)),
    ("h5", "ZCOOLKuaiLe-Regular.ttf", (34, 34, 34), "不良品统计\n划伤 12个\n尺寸超差 5个\n毛刺 8个\n合计 25个", (0.10, 0.07)),
]


def icon():
    S = 1024
    im = Image.new("RGB", (S, S))
    top, bot = (233, 216, 186), (214, 191, 152)
    for y in range(S):
        t = y / S
        ImageDraw.Draw(im).line([(0, y), (S, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bot)))
    d = ImageDraw.Draw(im)
    rnd = random.Random(3)
    for _ in range(46):                                      # 木纹
        x0 = rnd.uniform(0, S); amp = rnd.uniform(4, 14); ph = rnd.uniform(0, 6.28)
        pts = [(x0 + amp * math.sin(ph + y / S * 6.28), y) for y in range(0, S + 8, 8)]
        d.line(pts, fill=(214, 193, 158), width=rnd.choice([1, 2, 2]))
    # 纸：带一点影子，微微转个角度
    paper = Image.new("RGBA", (640, 720), (0, 0, 0, 0))
    pd = ImageDraw.Draw(paper)
    pd.rounded_rectangle([0, 0, 639, 719], radius=28, fill=(251, 248, 241, 255))
    for i, y in enumerate([250, 350, 450, 550, 650]):
        pd.line([(60, y), (580, y)], fill=(226, 214, 196, 255), width=6)
    pd.rounded_rectangle([60, 150, 330, 182], radius=16, fill=(74, 63, 54, 255))     # 一行「标题」
    pd.rounded_rectangle([60, 290, 440, 312], radius=11, fill=(150, 138, 124, 255))
    pd.rounded_rectangle([60, 390, 380, 412], radius=11, fill=(150, 138, 124, 255))
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sp = paper.rotate(-4, resample=Image.BICUBIC, expand=True)
    sh = Image.new("RGBA", sp.size, (60, 36, 12, 0))
    sh.putalpha(sp.split()[3].point(lambda v: int(v * 0.45)))
    shadow.paste(sh, (S // 2 - sp.width // 2 + 10, S // 2 - sp.height // 2 + 22), sh)
    shadow = shadow.filter(ImageFilter.GaussianBlur(22))
    im.paste(shadow, (0, 0), shadow)
    im.paste(sp, (S // 2 - sp.width // 2 - 10, S // 2 - sp.height // 2 - 6), sp)
    # 一片叶子（一叶）：两段弧围成，中间一道叶脉
    leaf = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(leaf)
    cx, cy, L, Wd = 0, 0, 330, 150
    pts = []
    for i in range(0, 101):
        t = i / 100
        pts.append((t * L, -math.sin(t * math.pi) * Wd / 2 * (1 - 0.25 * t)))
    for i in range(100, -1, -1):
        t = i / 100
        pts.append((t * L, math.sin(t * math.pi) * Wd / 2 * (1 - 0.25 * t)))
    ang = math.radians(-38)
    ox, oy = 560, 860
    def tr(p):
        x, y = p
        return (ox + x * math.cos(ang) - y * math.sin(ang), oy + x * math.sin(ang) + y * math.cos(ang))
    ld.polygon([tr(p) for p in pts], fill=(194, 65, 12, 255))
    ld.line([tr((-40, 0)), tr((L * 0.92, 0))], fill=(245, 170, 120, 255), width=8)
    for t in (0.3, 0.5, 0.7):
        ld.line([tr((L * t, 0)), tr((L * t + 50, -Wd * 0.28))], fill=(236, 140, 90, 255), width=5)
        ld.line([tr((L * t, 0)), tr((L * t + 50, Wd * 0.28))], fill=(236, 140, 90, 255), width=5)
    lsh = leaf.filter(ImageFilter.GaussianBlur(10))
    lsh_a = lsh.split()[3].point(lambda v: int(v * 0.35))
    dark = Image.new("RGBA", (S, S), (60, 30, 10, 0)); dark.putalpha(lsh_a)
    im.paste(dark, (8, 14), dark)
    im.paste(leaf, (0, 0), leaf)
    return im


def main():
    out = ROOT / "tools/ocr-samples"
    out.mkdir(parents=True, exist_ok=True)
    for name, text, kw, tilt in PRINTED:
        pg = printed_page(text.split("\n"), seed=name, **kw)
        photo(pg, name, tilt, shade=0.28).save(out / f"{name}.jpg", quality=84)
        (out / f"{name}.txt").write_text(text + "\n", encoding="utf-8")
        print(name)
    for name, font, ink, text, tilt in HAND:
        pg = hand_page(text.split("\n"), FONTS / font, ink, name)
        photo(pg, name, tilt, shade=0.34).save(out / f"{name}.jpg", quality=84)
        (out / f"{name}.txt").write_text(text + "\n", encoding="utf-8")
        print(name)

    demo = ROOT / "Yiye/Demo"
    demo.mkdir(parents=True, exist_ok=True)
    # 截图里的「拍照认字结果」用手写的：能看到拿不准的字标黄
    zh = "11月18日产量\nA线早班 1280件\nB线早班 960件\nC线早班 1105件\n冷却液快没了，晚班记得加"
    photo(hand_page(zh.split("\n"), FONTS / "LongCang-Regular.ttf", (28, 47, 110), "demo-zh", size=52), "demo-zh", (0.05, 0.03)).save(demo / "ocr-demo-zh.jpg", quality=80)
    en = "Shift report Nov 18\nLine A 1280 pcs\nLine B 960 pcs\nLine C 1105 pcs\nCoolant is low, top it up"
    photo(hand_page(en.split("\n"), FONTS / "PatrickHand-Regular.ttf", (28, 47, 110), "demo-en", size=56), "demo-en", (0.05, 0.03)).save(demo / "ocr-demo-en.jpg", quality=80)
    hand = "11月3日交接\nA线早班 1280件\nB线早班 960件\n早班交接完毕，3号机换了刀\n冷却液快没了，晚班记得加"
    photo(hand_page(hand.split("\n"), FONTS / "MaShanZheng-Regular.ttf", (28, 47, 110), "demo-hand", size=48), "demo-hand", (0.05, 0.03)).save(demo / "handover.jpg", quality=78)

    ic = icon()
    iconset = ROOT / "Yiye/Resources/Assets.xcassets/AppIcon.appiconset"
    iconset.mkdir(parents=True, exist_ok=True)
    ic.save(iconset / "icon-1024.png")
    ic.resize((512, 512), Image.LANCZOS).save(ROOT / "icon.png")
    print("icon ok")


if __name__ == "__main__":
    main()
