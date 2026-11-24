#!/bin/bash
# 模拟器里把主要界面走一遍截图：17 个界面 × 浅色深色 × 中文英文 = 68 张，存成 ios/shots/<语言>-<深浅>/NN-界面.jpg
# 用法：shots.sh <模拟器 UDID> <Yiye.app> <输出目录>
set -uo pipefail
SIM="$1"; APP="$2"; OUT="$3"
BID=lab.qianshou.yiye
SCREENS="list editor markdown ocr share-note share-white settings butler voice voice-note listen listen-text toolbox batch trash folders-tall listen-loop"
echo "包里的语言：$(ls -d "$APP"/*.lproj 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null
xcrun simctl status_bar "$SIM" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 || true
xcrun simctl install "$SIM" "$APP"
mkdir -p "$OUT"
fail=0
for lang in zh-Hans en; do
  short=$([ "$lang" = zh-Hans ] && echo zh || echo en)
  locale=$([ "$lang" = zh-Hans ] && echo zh_CN || echo en_US)
  for ap in light dark; do
    xcrun simctl ui "$SIM" appearance "$ap"
    dir="$OUT/$short-$ap"
    rm -rf "$dir"; mkdir -p "$dir"
    i=1
    for s in $SCREENS; do
      xcrun simctl terminate "$SIM" "$BID" >/dev/null 2>&1 || true
      SIMCTL_CHILD_TZ=Asia/Singapore xcrun simctl launch "$SIM" "$BID" -YiyeDemo YES -YiyeScreen "$s" -YiyeLang "$lang" -YiyeAppearance "$ap" \
        -AppleLanguages "($lang)" -AppleLocale "$locale" >/dev/null
      if [ "$s" = ocr ]; then sleep 14; else sleep 5; fi
      png="$dir/$(printf %02d $i)-$s.png"
      if xcrun simctl io "$SIM" screenshot --type=png "$png" >/dev/null 2>&1; then
        sips --resampleWidth 804 -s format jpeg -s formatOptions 84 "$png" --out "${png%.png}.jpg" >/dev/null && rm "$png"
      else
        echo "截图失败：$s $lang $ap"; fail=1
      fi
      i=$((i+1))
    done
  done
done
ls -R "$OUT" | head -60
# 外观设置：系统深色 + 选「纸」、系统浅色 + 选「深色」（109）
for lang in zh-Hans en; do
  short=$([ "$lang" = zh-Hans ] && echo zh || echo en)
  locale=$([ "$lang" = zh-Hans ] && echo zh_CN || echo en_US)
  for combo in "dark paper" "light dark"; do
    set -- $combo; sys=$1; pref=$2
    xcrun simctl ui "$SIM" appearance "$sys"
    dir="$OUT/$short-sys$sys-$pref"
    rm -rf "$dir"; mkdir -p "$dir"
    i=1
    for s in list settings toolbox folders; do
      xcrun simctl terminate "$SIM" "$BID" >/dev/null 2>&1 || true
      SIMCTL_CHILD_TZ=Asia/Singapore xcrun simctl launch "$SIM" "$BID" -YiyeDemo YES -YiyeScreen "$s" -YiyeLang "$lang" -YiyeAppearancePref "$pref"         -AppleLanguages "($lang)" -AppleLocale "$locale" >/dev/null
      sleep 5
      png="$dir/$(printf %02d $i)-$s.png"
      if xcrun simctl io "$SIM" screenshot --type=png "$png" >/dev/null 2>&1; then
        sips --resampleWidth 804 -s format jpeg -s formatOptions 84 "$png" --out "${png%.png}.jpg" >/dev/null && rm "$png"
      else
        echo "截图失败：$s $lang $sys+$pref"; fail=1
      fi
      i=$((i+1))
    done
  done
done
exit $fail
