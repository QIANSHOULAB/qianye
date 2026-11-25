"""117 一个嗓子：手机自己念的固定句子，全部用微软晓晓（zh-CN-XiaoxiaoNeural，+5%，跟大管家配回答的同一个嗓子）预先配好，
放进 ios/Yiye/Voice/，随 App 带。

句子从 Swift 里读（YiyeKit/Sources/YiyeKit/Companion.swift：CompanionTrouble.words 的每一句、Deep.says*；137 起还有
Talk137.swift 的 TalkSays），跟
VoiceLines.all 一样；文件名 v-<FNV-1a 32 位>.mp3（跟 VoiceLines.fnv1a 一个算法）。写 lines.json（名字 -> 字），缺的配上，
不再用的删掉。单测 Companion117Tests 查 lines.json 和录音齐不齐：字改了没重配，CI 就红。
英文的句子（以后有了）写成 "en:" 开头，用 en-US-AvaNeural（同档的微软神经嗓）。现在手机念的都是中文。

python ios/tools/voice_lines.py [--check]     （要 edge-tts；pc-butler 的 .venv 里有）"""
import asyncio
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
IOS = os.path.dirname(HERE)
SWIFT = os.path.join(IOS, "YiyeKit", "Sources", "YiyeKit", "Companion.swift")
OUT = os.path.join(IOS, "Yiye", "Voice")
ZH = ("zh-CN-XiaoxiaoNeural", "+5%")
EN = ("en-US-AvaNeural", "+0%")


def fnv1a(text):
    h = 0x811C9DC5
    for b in text.encode("utf-8"):
        h ^= b
        h = (h * 0x01000193) & 0xFFFFFFFF
    return f"{h:08x}"


def name(text):
    return "v-" + fnv1a(text)


def lines():
    src = open(SWIFT, encoding="utf-8").read()
    i = src.index("public var words: String {")
    j = src.index("\n    }\n", i)
    out = re.findall(r'case \.\w+: return "([^"]+)"', src[i:j])
    for key in ("saysGot", "saysEnd", "saysTopic"):
        m = re.search(r"public static let " + key + r' = "([^"]+)"', src)
        out.append(m.group(1))
    # 137 书童开口说：Talk137.swift 的 TalkSays（顺序照 TalkSays.all）
    talk = open(os.path.join(os.path.dirname(SWIFT), "Talk137.swift"), encoding="utf-8").read()
    i = talk.index("public enum TalkSays {")
    j = talk.index("public static let all", i)
    out += re.findall(r'public static let \w+ = "([^"]+)"', talk[i:j])
    seen, uniq = set(), []
    for t in out:
        if t not in seen:
            seen.add(t)
            uniq.append(t)
    return uniq


async def voice(text, path):
    import edge_tts
    v, rate = EN if text.startswith("en:") else ZH
    com = edge_tts.Communicate(text[3:] if text.startswith("en:") else text, v, rate=rate)
    audio = bytearray()
    async for ch in com.stream():
        if ch["type"] == "audio":
            audio += ch["data"]
    if len(audio) < 2000:
        raise RuntimeError(f"没配出来：{text}")
    with open(path, "wb") as f:
        f.write(audio)


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    ls = lines()
    table = {name(t): t for t in ls}
    os.makedirs(OUT, exist_ok=True)
    have = {f[:-4] for f in os.listdir(OUT) if f.startswith("v-") and f.endswith(".mp3")}
    need = [k for k in table if k not in have]
    stale = [k for k in have if k not in table]
    if "--check" in sys.argv:
        print(f"{len(ls)} 句；缺 {len(need)}，多 {len(stale)}")
        return 1 if need or stale else 0
    for k in need:
        asyncio.run(voice(table[k], os.path.join(OUT, k + ".mp3")))
        print("配了", k, table[k])
    for k in stale:
        os.remove(os.path.join(OUT, k + ".mp3"))
        print("删了", k)
    with open(os.path.join(OUT, "lines.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(table, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write("\n")
    print(f"{len(ls)} 句，全是晓晓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
