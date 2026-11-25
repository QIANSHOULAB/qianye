import AVFoundation
import Speech
import YiyeKit

/// 139 打电话式：电话里短的一句（≤ 3.5 秒）先在手机上认一遍字，只为认挂断词（「挂掉」「好，挂了」「拜拜」「不聊了」）。
/// iOS 26 的 SpeechTranscriber，手机本机认，不上传、不过信箱：信箱断了、电脑关着也挂得掉。
/// 这台手机没装中文的认字模型：后台下，这通电话先照旧交大管家认（大管家那头 deep.hangup 兜底）。
@MainActor
final class ClipReader {
    private var locale: Locale?
    private var format: AVAudioFormat?
    private var preparing = false
    private(set) var ready = false

    /// 接通时叫一下（已经好了就不再弄）
    func prepare() async {
        guard !ready, !preparing else { return }
        preparing = true
        defer { preparing = false }
        let auth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard auth == .authorized, SpeechTranscriber.isAvailable,
              let loc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else { return }
        let m = SpeechTranscriber(locale: loc, preset: .progressiveTranscription)
        do {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [m]) {
                Task { try? await req.downloadAndInstall() }      // 第一次：后台下，下回接通就能用
                return
            }
            format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [m])
            locale = loc
            ready = format != nil
        } catch {
            ready = false
        }
    }

    /// 一句（16 kHz 单声道浮点样本）→ 认出来的字。认不了、超时（timeout 秒）回 nil：照旧交大管家
    func read(_ samples: [Float], timeout: Double = 2.0) async -> String? {
        guard ready, let locale, let format, !samples.isEmpty,
              let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(ClipCutter.rate), channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buf.floatChannelData else { return nil }
        for (i, v) in samples.enumerated() { ch[0][i] = v }
        buf.frameLength = AVAudioFrameCount(samples.count)
        guard let input = Ear.convert(buf, to: format) else { return nil }
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [module])
        let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
        let collect = Task { () -> String in
            var s = ""
            do {
                for try await r in module.results where r.isFinal { s += String(r.text.characters) }
            } catch {}
            return s
        }
        feed.yield(AnalyzerInput(buffer: input))
        feed.finish()
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await analyzer.cancelAndFinishNow()
        }
        if let last = try? await analyzer.analyzeSequence(stream) {
            try? await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let text = await collect.value
        timer.cancel()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
