#!/bin/bash
# XcodeGen 按 lproj 文件夹认语言；中文只在 String Catalog 里，knownRegions 得手动补上 zh-Hans，不然可能不编进包
f="$1"
if ! grep -q 'zh-Hans' "$f"; then
  perl -0pi -e 's/knownRegions = \(\n/knownRegions = (\n\t\t\t\t"zh-Hans",\n/' "$f"
fi
grep -A5 'knownRegions' "$f"
