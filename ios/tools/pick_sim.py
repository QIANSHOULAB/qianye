#!/usr/bin/env python3
"""临时分支 luru-163-ios：借 iOS 工作流的 macOS 机器，在 iOS 模拟器的 Safari 里跑录入僧 163 的画法测试（luru163.py）。
跑完故意失败，后面编译、截图都不跑；ios/shots 里的图在这个分支删了，「截图提交回仓库」那步会直接说没有截图、不提交。
这个分支不合进 main。"""
import json, os, subprocess, sys

data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
runtimes = sorted([r for r in data["devices"] if ".iOS-" in r], key=lambda r: [int(x) for x in r.split("iOS-")[1].split("-")])
want = ["iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro", "iPhone Air", "iPhone 16"]
udid = None
for rt in reversed(runtimes):
    devs = [d for d in data["devices"][rt] if d["name"].startswith("iPhone")]
    if devs:
        devs.sort(key=lambda d: want.index(d["name"]) if d["name"] in want else 99)
        udid, name = devs[0]["udid"], f'{devs[0]["name"]} / {rt.split(".")[-1]}'
        break
print(f"挑了 {name}", file=sys.stderr, flush=True)
here = os.path.dirname(os.path.abspath(__file__))
subprocess.run(["python3", "-m", "venv", "/tmp/v"], check=True)
subprocess.run(["/tmp/v/bin/pip", "install", "-q", "pillow"], check=True)
rc = subprocess.run(["/tmp/v/bin/python", os.path.join(here, "luru163.py"), udid, name], stdout=sys.stderr).returncode
print(f"luru163 退出码 {rc}；故意停在这一步", file=sys.stderr)
sys.exit(1)
