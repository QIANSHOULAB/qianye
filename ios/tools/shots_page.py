#!/usr/bin/env python3
"""给 Song 在手机上看最新样子的网页：ios/shots/index.html（CI 每次截完图顺手重写）。
网址 https://qianshoulab.github.io/qianye/ios/shots/ ：版本号、哪次提交、改了啥、认字的数，下面是全部截图，能切中英、浅深。
用法：shots_page.py <提交短号> <提交说明第一行> <提交时间 ISO>"""
import datetime, html, json, pathlib, re, sys

root = pathlib.Path(__file__).resolve().parents[1]
shots = root / "shots"
sha, subject, when = (sys.argv[1:4] + ["", "", ""])[:3]

proj = (root / "project.yml").read_text(encoding="utf-8")
m = re.search(r'MARKETING_VERSION:\s*"?([0-9.]+)"?', proj)
version = m.group(1) if m else "?"

try:
    t = datetime.datetime.fromisoformat(when).astimezone(datetime.timezone(datetime.timedelta(hours=8)))
    stamp = t.strftime("%m-%d %H:%M")
except Exception:
    stamp = ""

subject = re.sub(r"^iOS\s*", "", subject).strip()

# 认字的数：印刷、手写各认对几成
ocr = ""
try:
    rows = [r for r in json.loads((shots / "ocr" / "report.json").read_text(encoding="utf-8")) if not r.get("error")]
    parts = []
    for k in ["印刷", "手写"]:
        rs = [r for r in rows if r["kind"] == k]
        chars = sum(r["truthChars"] for r in rs)
        ed = sum(r["editDistance"] for r in rs)
        if chars:
            parts.append(f"{k} {round(100 * max(0, 1 - ed / chars))}%")
    if parts:
        ocr = "拍照认字认对：" + "，".join(parts)
except Exception:
    pass

names = {
    "list": "列表", "editor": "写字页", "markdown": "Markdown 五招", "ocr": "拍照认字", "share-note": "分享成图 · 便签",
    "share-white": "分享成图 · 白纸", "settings": "设置", "butler": "大管家", "voice": "录一段", "voice-note": "录音笔记", "listen": "听力列表", "listen-text": "听力 · 原文", "toolbox": "工具箱（点开）",
}
sets = {}
for d in ["zh-light", "zh-dark", "en-light", "en-dark"]:
    files = sorted(p.name for p in (shots / d).glob("*.jpg")) if (shots / d).is_dir() else []
    sets[d] = files

def figure(d, f):
    key = re.sub(r"^\d+-", "", f[:-4])
    cap = names.get(key, key)
    return (f'<figure><img src="{d}/{f}?v={html.escape(sha)}" alt="{html.escape(cap)}" loading="lazy" width="402" height="874">'
            f'<figcaption>{html.escape(cap)}</figcaption></figure>')

blocks = "\n".join(
    f'<section class="set" data-set="{d}"{"" if d == "zh-light" else " hidden"}>' + "".join(figure(d, f) for f in fs) + "</section>"
    for d, fs in sets.items())
count = sum(len(v) for v in sets.values())

page = f"""<!doctype html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>一叶笺 iPhone · 最新样子</title>
<style>
:root {{ --bg:#f6f2ea; --card:#fffcf6; --ink:#4a3f36; --ink2:#8a7e70; --line:#e3d9c8; --accent:#c2410c; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#1c1814; --card:#2a2622; --ink:#e9e1d4; --ink2:#a99f92; --line:#3a332c; --accent:#f0915e; }} }}
* {{ box-sizing:border-box; }}
body {{ margin:0; background:var(--bg); color:var(--ink); font:16px/1.5 -apple-system, "PingFang SC", "Helvetica Neue", sans-serif; }}
header {{ padding:20px 16px 8px; max-width:880px; margin:0 auto; }}
h1 {{ font-size:22px; margin:0 0 6px; }}
.meta {{ color:var(--ink2); font-size:14px; margin:2px 0; }}
.changed {{ margin:10px 0 4px; padding:10px 12px; background:var(--card); border:1px solid var(--line); border-radius:10px; font-size:15px; }}
nav {{ position:sticky; top:0; z-index:2; background:var(--bg); padding:8px 16px; display:flex; gap:8px; max-width:880px; margin:0 auto; }}
nav button {{ flex:1; min-height:44px; border-radius:9px; border:1px solid var(--line); background:var(--card); color:var(--ink2); font:inherit; font-size:15px; }}
nav button[aria-pressed="true"] {{ color:#fff; background:var(--accent); border-color:var(--accent); }}
.set {{ display:grid; grid-template-columns:repeat(auto-fill, minmax(240px, 1fr)); gap:16px; padding:8px 16px 40px; max-width:880px; margin:0 auto; }}
.set[hidden] {{ display:none; }}
figure {{ margin:0; }}
img {{ width:100%; height:auto; border-radius:14px; border:1px solid var(--line); display:block; background:var(--card); }}
figcaption {{ text-align:center; color:var(--ink2); font-size:14px; margin-top:6px; }}
</style>
</head>
<body>
<header>
<h1>一叶笺 iPhone · 最新样子</h1>
<p class="meta">{html.escape(version)} · 提交 {html.escape(sha)}{(" · " + stamp + "（新加坡时间）") if stamp else ""}</p>
<p class="changed">这次改了：{html.escape(subject) or "—"}</p>
<p class="meta">{html.escape(ocr)}{" · " if ocr else ""}{count} 张截图，CI 每次自动换</p>
</header>
<nav>
<button data-lang="zh" aria-pressed="true">中文</button><button data-lang="en" aria-pressed="false">English</button>
<button data-look="light" aria-pressed="true">浅色</button><button data-look="dark" aria-pressed="false">深色</button>
</nav>
{blocks}
<script>
let lang = "zh", look = "light";
function show() {{
  document.querySelectorAll(".set").forEach(s => s.hidden = s.dataset.set !== lang + "-" + look);
  document.querySelectorAll("nav button").forEach(b => b.setAttribute("aria-pressed", String(b.dataset.lang === lang || b.dataset.look === look)));
}}
document.querySelectorAll("nav button").forEach(b => b.addEventListener("click", () => {{
  if (b.dataset.lang) lang = b.dataset.lang; else look = b.dataset.look;
  show();
}}));
</script>
</body>
</html>
"""
(shots / "index.html").write_text(page, encoding="utf-8")
print(f"ios/shots/index.html：{version}，{count} 张")
