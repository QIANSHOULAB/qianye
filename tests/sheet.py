"""把一个目录里 9 个版式的图拼成 3×3 对比图：sheet.py 目录 输出.png [每张宽]"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ORDER = [("note", "便签（默认）"), ("white", "白纸"), ("letter", "信笺"), ("kraft", "牛皮纸"), ("night", "夜读"),
         ("mag", "杂志"), ("journal", "手账"), ("big", "大字"), ("notice", "公告")]
src, dst = Path(sys.argv[1]), sys.argv[2]
cw = int(sys.argv[3]) if len(sys.argv) > 3 else 520
font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 26)
ims = []
for k, name in ORDER:
    im = Image.open(src / f"{k}.png").convert("RGB")
    im = im.resize((cw, round(im.height * cw / im.width)), Image.LANCZOS)
    ims.append((name, im))
gap, top = 36, 54
ch = max(im.height for _, im in ims)
g = Image.new("RGB", (3 * cw + 4 * gap, 3 * (ch + top) + 4 * gap - top + top), "#E9E9EC")
d = ImageDraw.Draw(g)
for i, (name, im) in enumerate(ims):
    x = gap + (i % 3) * (cw + gap)
    y = gap + (i // 3) * (ch + top + gap)
    d.text((x, y), f"{i + 1}  {name}", fill="#1d1d1f", font=font)
    g.paste(im, (x, y + top))
g.save(dst, optimize=True)
print(dst, g.size)
