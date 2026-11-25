#!/bin/bash
# 139 探路：iOS 26 SDK 里有没有锁屏起麦（AudioRecordingIntent、supportedModes）、蓝牙高音质收音、HFP 新名字、
# Live Activity、CallKit、SpeechTranscriber 认一段录音。只 grep SDK，不编东西。shots.sh 开头调，结果在 ios/shots/probe/sdk.txt
# （token 没有 workflow 权限，加不了单独的 workflow）。用完可以删。
set -u
SDK=$(xcrun --sdk iphoneos --show-sdk-path); echo "SDK=$SDK"
F="$SDK/System/Library/Frameworks"
si() { find "$F/$1.framework" -name "*.swiftinterface" 2>/dev/null | grep -E "arm64e?-apple-ios\.swiftinterface$" | head -1; }
echo "=== AVFAudio：CategoryOptions"
grep -rhn -i "BluetoothHighQualityRecording\|AllowBluetoothHFP\|AllowBluetooth \|AllowBluetoothA2DP\|AVAudioSessionCategoryOptionAllowBluetooth" "$F/AVFAudio.framework/Headers/AVAudioSessionTypes.h" | head -30
grep -n -B3 -A3 "BluetoothHighQualityRecording" "$F/AVFAudio.framework/Headers/AVAudioSessionTypes.h" | head -40
echo "=== AppIntents：AudioRecordingIntent / supportedModes / LiveActivityIntent"
A=$(si AppIntents); echo "$A"
grep -n "protocol AudioRecordingIntent\|protocol LiveActivityIntent\|protocol AudioPlaybackIntent\|protocol ForegroundContinuableIntent\|supportedModes\|struct IntentModes\|continueInForeground\|static var openAppWhenRun\|authenticationPolicy" "$A" | head -40
grep -n -B6 -A12 "protocol AudioRecordingIntent" "$A" | head -60
grep -n -A25 "struct IntentModes" "$A" | head -60
echo "=== ActivityKit：request"
K=$(si ActivityKit); echo "$K"
grep -n "static func request\|NSSupportsLiveActivities\|ActivityAuthorizationError\|case " "$K" | head -60
echo "=== CallKit"
ls "$F/CallKit.framework/Headers" | head
grep -rhn "API_AVAILABLE\|API_UNAVAILABLE" "$F/CallKit.framework/Headers/CXProvider.h" | head -8
grep -rhn "includesCallsInRecents\|supportsVideo\|maximumCallGroups" "$F/CallKit.framework/Headers/CXProviderConfiguration.h" | head
echo "=== Speech：SpeechTranscriber、analyzeSequence(from: AVAudioFile)"
S=$(si Speech); echo "$S"
grep -n "analyzeSequence\|public init(inputAudioFile\|func start(inputAudioFile\|class SpeechTranscriber\|class DictationTranscriber\|static var isAvailable\|func finalizeAndFinish" "$S" | head -40
echo "=== Info.plist：INAlternativeAppNames（Intents）"
grep -rln "INAlternativeAppNames\|AlternativeAppName" "$F/Intents.framework" "$F/AppIntents.framework" 2>/dev/null | head
grep -rhn "AlternativeAppName" "$F/Intents.framework/Headers" 2>/dev/null | head
