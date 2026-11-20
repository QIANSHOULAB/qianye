#!/usr/bin/env python3
"""发版后更新 SideStore / AltStore 源（ios/sidestore.json）：版本、日期、大小、下载地址。
用法：update_source.py <版本> <ipa 字节数> <下载地址>。新版本放 versions 第一个（AltStore 把第一个当最新）。"""
import datetime, json, pathlib, sys

v, size, url = sys.argv[1], int(sys.argv[2]), sys.argv[3]
p = pathlib.Path(__file__).resolve().parents[1] / "sidestore.json"
src = json.loads(p.read_text(encoding="utf-8"))
app = src["apps"][0]
import re
proj = (pathlib.Path(__file__).resolve().parents[1] / "project.yml").read_text(encoding="utf-8")
m = re.search(r'CURRENT_PROJECT_VERSION:\s*"?(\d+)"?', proj)
build = m.group(1) if m else "1"
today = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).strftime("%Y-%m-%d")
notes = (pathlib.Path(__file__).resolve().parents[1] / "release-notes.md").read_text(encoding="utf-8").strip()
entry = {
    "version": v,
    "buildVersion": build,
    "date": today,
    "localizedDescription": notes,
    "downloadURL": url,
    "size": size,
    "minOSVersion": "26.0",
}
app["versions"] = [entry] + [x for x in app.get("versions", []) if x.get("version") != v]
# 老版 AltStore / SideStore 认的旧字段，一起写上
app.update({"version": v, "versionDate": today, "versionDescription": notes, "downloadURL": url, "size": size})
p.write_text(json.dumps(src, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(entry, ensure_ascii=False, indent=2))
