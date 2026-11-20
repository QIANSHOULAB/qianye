#!/usr/bin/env python3
"""一叶笺 iPhone 版界面文字：中英两套都在这里，生成 String Catalog（Localizable.xcstrings、InfoPlist.xcstrings），
再导出一行一条的 zh.txt、en.txt 给人过目（文案规范「交货前自查」）。改字只改这里，然后跑：python3 ios/tools/strings.py
英文不是翻译，是照英文用户的习惯重写的。按钮照直写。"""
import json, pathlib, re, sys

S = {
 # key: (中文, English)
 "app.name": ("一叶笺", "Yiye"),
 "busy.ocr": ("认字中，你去摸会儿鱼…", "Squinting at your handwriting…"),
 "busy.import": ("从文件夹往回搬…", "Bringing your notes home…"),
 "list.all": ("全部便签", "All Notes"),
 "list.new": ("写一条", "New note"),
 "list.search": ("搜索", "Search"),
 "list.empty": ("一张纸都还没有。写一条，或者拍一页。", "A blank desk. Write a note or scan a page."),
 "list.noHit": ("没搜到", "No matches"),
 "time.yesterday": ("昨天", "Yesterday"),
 "note.untitled": ("无题", "Untitled"),
 "note.delete": ("删除", "Delete"),
 "note.pin": ("置顶", "Pin"),
 "note.unpin": ("取消置顶", "Unpin"),
 "note.move": ("挪到文件夹", "Move to folder"),
 "toast.deleted": ("删了「%@」", "Deleted “%@”"),
 "toast.undo": ("撤销", "Undo"),
 "capture.camera": ("拍照认字", "Scan page"),
 "capture.library": ("从相册认字", "Scan a photo"),
 "capture.libraryInto": ("从相册认字", "Scan a photo"),
 "capture.shoot": ("拍", "Shoot"),
 "ocr.nothing": ("这张图上没找到字。拍正一点、亮一点再来。", "No text in that one. Try a straighter, brighter shot."),
 "ocr.failed": ("没认出来：%@", "Couldn’t read it: %@"),
 "editor.back": ("便签", "Notes"),
 "editor.more": ("更多", "More"),
 "editor.paper": ("换纸", "Paper"),
 "editor.original": ("看原图", "Original photo"),
 "editor.originalMissing": ("原图不在这台手机上", "The original photo isn’t on this phone."),
 "editor.toButler": ("交给大管家", "Send to the butler"),
 "paper.white": ("素白", "White"),
 "paper.yellow": ("米黄", "Cream"),
 "paper.green": ("豆青", "Sage"),
 "paper.blue": ("天青", "Sky"),
 "paper.pink": ("藕粉", "Blush"),
 "md.heading": ("标题", "Heading"),
 "md.list": ("列表", "List"),
 "md.bold": ("粗体", "Bold"),
 "md.quote": ("引用", "Quote"),
 "md.center": ("居中", "Center"),
 "md.image": ("插图片", "Insert photo"),
 "md.done": ("收起键盘", "Hide keyboard"),
 "share.title": ("分享成图", "Share as image"),
 "share.save": ("保存相册", "Save"),
 "share.share": ("分享", "Share"),
 "share.saved": ("存进相册了", "Saved to Photos"),
 "share.saveFailed": ("没存上：%@", "Didn’t save: %@"),
 "share.noPermission": ("没有存照片的权限：设置 > 隐私与安全性 > 照片 里给一叶笺开一下。", "No access to Photos. Turn it on in Settings > Privacy & Security > Photos."),
 "share.mark": ("一叶笺", "Yiye"),
 "theme.note": ("便签", "Note"),
 "theme.white": ("白纸", "Plain"),
 "common.close": ("关", "Close"),
 "common.done": ("好了", "Done"),
 "common.cancel": ("取消", "Cancel"),
 "folders.title": ("文件夹", "Folders"),
 "folders.new": ("新建文件夹", "New folder"),
 "folders.add": ("建", "Add"),
 "folders.namePlaceholder": ("起个名", "Folder name"),
 "folders.delete": ("删掉文件夹", "Delete folder"),
 "folders.deleted": ("文件夹「%@」删了，里面的笔记回到全部便签", "Deleted “%@”. Its notes are back in All Notes."),
 "sort.title": ("排序", "Sort"),
 "sort.new": ("新改的在前", "Newest edits"),
 "sort.old": ("老的在前", "Oldest edits"),
 "sort.created": ("按新建", "Date created"),
 "settings.title": ("设置", "Settings"),
 "settings.mirror": ("镜像文件夹", "Mirror folder"),
 "settings.mirrorChange": ("换一个", "Change"),
 "settings.mirrorNote": ("每存一次往里写一个 .md，图片进「附件」，删掉的进「废纸篓」。以后换正式版，从这儿一条不落搬回来。", "Every save writes a .md file here. Photos go in 附件, deleted notes in 废纸篓. Switch to another build later and everything moves back from here."),
 "settings.import": ("从文件夹导入", "Import from folder"),
 "settings.fontSize": ("字号", "Text size"),
 "font.small": ("小", "Small"),
 "font.medium": ("中", "Medium"),
 "font.large": ("大", "Large"),
 "settings.butler": ("大管家", "Butler"),
 "settings.butlerAuto": ("拍照的自动交给大管家", "Auto-send scans"),
 "settings.butlerNote": ("手写认不准的字，掌机上的大管家对着原图理顺再送回来。走的就是镜像文件夹，手机上不存任何 AI 钥匙。", "The butler on your PC checks scans against the photo and sends back a clean copy, all through the mirror folder. No AI keys on this phone."),
 "settings.language": ("语言", "Language"),
 "lang.system": ("跟系统", "System"),
 "settings.version": ("版本", "Version"),
 "mirror.ask": ("每条笔记在 iCloud 云盘也存一份：换手机不丢，大管家也从那儿拿活。", "Keep a copy of every note in iCloud Drive. Survives new phones, and the butler works from there."),
 "mirror.choose": ("选文件夹", "Choose folder"),
 "mirror.skip": ("先不用", "Not now"),
 "mirror.off": ("没开", "Off"),
 "mirror.icloud": ("iCloud 云盘", "iCloud Drive"),
 "mirror.on": ("镜像好了：%@", "Mirroring to %@"),
 "mirror.failed": ("这个文件夹用不了：%@", "Can’t use that folder: %@"),
 "import.done": ("搬回来 %lld 条，更新 %lld 条。", "Imported %lld, updated %lld."),
 "import.pending": ("还有 %lld 条在 iCloud 里没下完，过会儿再导一次。", " %lld still coming down from iCloud. Try again in a bit."),
 "butler.waiting": ("大管家在理", "The butler’s on it"),
 "butler.short.waiting": ("在理", "Tidying"),
 "butler.short.offer": ("理好了", "Ready"),
 "butler.absent": ("大管家没来，回来接着理", "Butler’s not around. It’ll pick this up later."),
 "butler.seen": ("大管家 %lld 分钟前来过", "Butler last seen %lld min ago"),
 "butler.online": ("大管家在线", "Butler is online"),
 "butler.needMirror": ("大管家从镜像文件夹拿活，先在设置里选一个文件夹。", "The butler works out of your mirror folder. Pick one in Settings first."),
 "butler.needMirrorShort": ("先选镜像文件夹", "Pick a mirror folder first"),
 "butler.applied": ("大管家改了 %lld 处", "The butler fixed %lld spots"),
 "butler.offer": ("大管家理好了，点一下换上", "Butler’s copy is ready. Tap to swap it in."),
 "butler.no": ("不要", "Skip"),
 "butler.failed": ("大管家这回没理成", "The butler hit a snag"),
 "butler.retry": ("再交一次", "Try again"),
 "butler.revert": ("换回原文", "Restore original"),
 "butler.ok": ("知道了", "Got it"),
 "butler.unchanged": ("大管家看过了，一个字没改", "The butler read it. Nothing to fix."),
 "butler.more": ("还有 %lld 处", "%lld more"),
}

INFO = {
 "CFBundleDisplayName": ("一叶笺", "Yiye"),
 "CFBundleName": ("一叶笺", "Yiye"),
 "NSCameraUsageDescription": ("拍一页纸，一叶笺在手机上把字认出来。", "Snap a page and Yiye turns the writing into text, right on your phone."),
 "NSPhotoLibraryAddUsageDescription": ("把笔记做成的图存进相册。", "Saves the pictures you make from notes to your Photos."),
}

def catalog(d):
    out = {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
    for k, (zh, en) in sorted(d.items()):
        out["strings"][k] = {"extractionState": "manual", "localizations": {
            "en": {"stringUnit": {"state": "translated", "value": en}},
            "zh-Hans": {"stringUnit": {"state": "translated", "value": zh}},
        }}
    return json.dumps(out, ensure_ascii=False, indent=2, sort_keys=True) + "\n"

root = pathlib.Path(__file__).resolve().parents[1]
(root / "Yiye/Resources/Localizable.xcstrings").write_text(catalog(S), encoding="utf-8")
(root / "Yiye/Resources/InfoPlist.xcstrings").write_text(catalog(INFO), encoding="utf-8")
(root / "docs/strings/zh.txt").write_text("\n".join(f"{k}\t{v[0]}" for k, v in sorted({**S, **INFO}.items())) + "\n", encoding="utf-8")
(root / "docs/strings/en.txt").write_text("\n".join(f"{k}\t{v[1]}" for k, v in sorted({**S, **INFO}.items())) + "\n", encoding="utf-8")

# 代码里用到的 key 都得有；两套的占位符要一样
used = set()
for f in (root / "Yiye").rglob("*.swift"):
    used |= set(re.findall(r'\.(?:t|f)\("([a-zA-Z][a-zA-Z0-9_.]+)"', f.read_text(encoding="utf-8")))
used |= {f"paper.{p}" for p in ["white", "yellow", "green", "blue", "pink"]} | {"theme.note", "theme.white"}
missing = sorted(used - set(S))
bad = [k for k, (zh, en) in S.items() if sorted(re.findall(r"%(?:lld|@)", zh)) != sorted(re.findall(r"%(?:lld|@)", en))]
if missing or bad:
    print("缺的 key：", missing, "\n占位符对不上：", bad)
    sys.exit(1)
print(f"{len(S)} 条界面字 + {len(INFO)} 条 Info.plist 字，两套齐。没用上的：{sorted(set(S) - used)}")
