#!/bin/bash
# 模拟器里把主要界面走一遍截图：30 个界面 × 浅色深色 × 中文英文 = 120 张，存成 ios/shots/<语言>-<深浅>/NN-界面.jpg
# 用法：shots.sh <模拟器 UDID> <Yiye.app> <输出目录>
set -uo pipefail
SIM="$1"; APP="$2"; OUT="$3"
BID=lab.qianshou.yiye
SCREENS="list editor markdown ocr share-note share-white settings butler voice voice-note listen listen-text toolbox batch trash folders-tall listen-loop article article-wait article-done original original-focus markdown-focus dove dove-done secret shutong shutong-confirm shutong-slip spoken call shutong-tell swipe-in swipe-out shutong-links link-note"
echo "包里的语言：$(ls -d "$APP"/*.lproj 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null
xcrun simctl status_bar "$SIM" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 || true

# ---- UI 测试（133）：截图之前先在这台模拟器上真点、真滑、真长按一遍（ios/YiyeUITests）。
# 不过就停在这儿：不截图、这一步失败、不发版。结果写进 $OUT/uitest/（结果.txt + 出错那一刻的截图），CI 照样提交回仓库。
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DD="${APP%%/Build/Products/*}"
UIT="$OUT/uitest"
rm -rf "$UIT" "$DD/uitest.xcresult" "$DD/uitest-att"; mkdir -p "$UIT"
UIT_ABS="$(cd "$UIT" && pwd)"
BEAUTY=cat; command -v xcbeautify >/dev/null && BEAUTY="xcbeautify --renderer github-actions"
TEST_RUNNER_YIYE_UITEST_SHOTS="$UIT_ABS" xcodebuild test -project "$ROOT/Yiye.xcodeproj" -scheme Yiye \
  -destination "id=$SIM" -derivedDataPath "$DD" -resultBundlePath "$DD/uitest.xcresult" \
  -only-testing:YiyeUITests -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 180 2>&1 | tee "$DD/uitest.log" | $BEAUTY
urc=${PIPESTATUS[0]}
# 测试自己没存下图：从结果包里把挂的截图倒出来
if ! ls "$UIT"/*.png >/dev/null 2>&1; then
  xcrun xcresulttool export attachments --path "$DD/uitest.xcresult" --output-path "$DD/uitest-att" >/dev/null 2>&1 || true
  find "$DD/uitest-att" -name "*.png" 2>/dev/null | head -20 | while read -r p; do cp "$p" "$UIT/"; done
fi
for p in "$UIT"/*.png; do
  [ -e "$p" ] || continue
  sips --resampleWidth 600 -s format jpeg -s formatOptions 80 "$p" --out "${p%.png}.jpg" >/dev/null && rm "$p"
done
{
  if [ "$urc" = 0 ]; then echo "# UI 测试：全绿"; else echo "# UI 测试：有红的（xcodebuild 退出码 ${urc}）"; fi
  echo
  grep -E "Test [Cc]ase .*(passed|failed)" "$DD/uitest.log" | sed -E "s/^.*Test [Cc]ase '//" || true
  echo
  grep -E "error: |: error" "$DD/uitest.log" | sed -E "s#^.*/YiyeUITests/##" | sort -u | head -40 || true
  echo
  grep -E "Executed [0-9]+ test|\*\* TEST" "$DD/uitest.log" | tail -3 || true
} > "$UIT/结果.txt"
cat "$UIT/结果.txt"
echo "::notice title=UI 测试（133）::$(awk 'BEGIN{ORS="%0A"}1' "$UIT/结果.txt")"
ls "$UIT"
if [ -n "${UITEST_ONLY:-}" ]; then echo "只跑 UI 测试（133 复现），不截图"; exit 0; fi
if [ "$urc" != 0 ]; then echo "::error::UI 测试没过（ios/shots/uitest/结果.txt），不截图、不发版"; exit 1; fi

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
# 整体配色（132）：四种新配色 × 浅深，列表、写字页、文件夹面板、设置（中文一套；素白就是默认，主套图里已有）
xcrun simctl status_bar "$SIM" override --time "9:41" >/dev/null 2>&1 || true
for tid in yellow green blue pink; do
  for ap in light dark; do
    xcrun simctl ui "$SIM" appearance "$ap"
    dir="$OUT/zh-theme-$tid-$ap"
    rm -rf "$dir"; mkdir -p "$dir"
    i=1
    for s in list editor folders settings-theme; do
      xcrun simctl terminate "$SIM" "$BID" >/dev/null 2>&1 || true
      SIMCTL_CHILD_TZ=Asia/Singapore xcrun simctl launch "$SIM" "$BID" -YiyeDemo YES -YiyeScreen "$s" -YiyeLang zh-Hans -YiyeAppearance "$ap" -YiyeTheme "$tid"         -AppleLanguages "(zh-Hans)" -AppleLocale "zh_CN" >/dev/null
      sleep 5
      png="$dir/$(printf %02d $i)-$s.png"
      if xcrun simctl io "$SIM" screenshot --type=png "$png" >/dev/null 2>&1; then
        sips --resampleWidth 804 -s format jpeg -s formatOptions 84 "$png" --out "${png%.png}.jpg" >/dev/null && rm "$png"
      else
        echo "截图失败：$s $tid $ap"; fail=1
      fi
      i=$((i+1))
    done
  done
done
# 小屏（157）：Xcode 26 的模拟器里已经没有 375 点宽的（SE、mini 都没了）：同一台模拟器上整个画面限宽 375（-YiyeNarrow），
# 顶栏照窄屏排（按钮左右留白收一点），看「全部便签 ▾」有没有被挤成省略号。列表、工具箱，中英 × 浅深
for lang in zh-Hans en; do
  short=$([ "$lang" = zh-Hans ] && echo zh || echo en)
  locale=$([ "$lang" = zh-Hans ] && echo zh_CN || echo en_US)
  for ap in light dark; do
    xcrun simctl ui "$SIM" appearance "$ap"
    dir="$OUT/small-$short-$ap"
    rm -rf "$dir"; mkdir -p "$dir"
    i=1
    for s in list toolbox; do
      xcrun simctl terminate "$SIM" "$BID" >/dev/null 2>&1 || true
      SIMCTL_CHILD_TZ=Asia/Singapore xcrun simctl launch "$SIM" "$BID" -YiyeDemo YES -YiyeScreen "$s" -YiyeLang "$lang" -YiyeAppearance "$ap" -YiyeNarrow YES \
        -AppleLanguages "($lang)" -AppleLocale "$locale" >/dev/null || true
      sleep 5
      png="$dir/$(printf %02d $i)-$s.png"
      if xcrun simctl io "$SIM" screenshot --type=png "$png" >/dev/null 2>&1; then
        sips --resampleWidth 804 -s format jpeg -s formatOptions 84 "$png" --out "${png%.png}.jpg" >/dev/null && rm "$png"
      fi
      i=$((i+1))
    done
  done
done
exit $fail
