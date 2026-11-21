import AVFoundation
import YiyeKit

/// 「念出来」：手机自己用苹果的语音把稿子念成一段录音，一句一句念，记下每句从第几秒开始（单句循环要用）。
/// 大管家配的音（ElevenLabs）更像真人；它没来之前，这个先顶上。
@MainActor
final class PhoneVoice {
    private let synth = AVSpeechSynthesizer()

    struct Out {
        var marks: [ListenMark]
        var voiceName: String
        var premium: Bool
    }

    enum Failure: LocalizedError {
        case empty, noAudio
        var errorDescription: String? {
            switch self {
            case .empty: return "nothing to read"
            case .noAudio: return "no audio came out"
            }
        }
    }

    /// 稿子里汉字多就用中文嗓子，不然英文
    static func language(of text: String) -> String {
        let cjk = text.filter { isWide($0) }.count
        let latin = text.filter { $0.isLetter && $0.isASCII }.count
        return cjk > latin ? "zh-CN" : "en-US"
    }

    /// 挑最好的嗓子：Premium > Enhanced > 普通；同档先美音；不要怪声音
    static func bestVoice(_ lang: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(lang.prefix(2))
        let all = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(prefix) && !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        return all.max { a, b in
            if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue < b.quality.rawValue }
            return (a.language == lang ? 1 : 0) < (b.language == lang ? 1 : 0)
        } ?? AVSpeechSynthesisVoice(language: lang)
    }

    func render(_ markdown: String, to url: URL) async throws -> Out {
        let sentences = Listen.sentences(markdown)
        guard !sentences.isEmpty else { throw Failure.empty }
        let lang = Self.language(of: sentences.joined(separator: " "))
        let voice = Self.bestVoice(lang)
        try? FileManager.default.removeItem(at: url)
        var file: AVAudioFile?
        var frames: AVAudioFramePosition = 0
        var marks: [ListenMark] = []
        for s in sentences {
            let start = file.map { Double(frames) / $0.processingFormat.sampleRate } ?? 0
            marks.append(ListenMark(t: start, s: s))
            let u = AVSpeechUtterance(string: s)
            u.voice = voice
            u.rate = AVSpeechUtteranceDefaultSpeechRate
            for b in await buffers(u) {
                if file == nil {
                    file = try AVAudioFile(forWriting: url, settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: b.format.sampleRate,
                        AVNumberOfChannelsKey: b.format.channelCount,
                        AVEncoderBitRateKey: 64_000,
                    ], commonFormat: b.format.commonFormat, interleaved: b.format.isInterleaved)
                }
                try file?.write(from: b)
                frames += AVAudioFramePosition(b.frameLength)
            }
            // 句子之间停 0.4 秒，单句循环听着不赶
            if let f = file, let gap = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.processingFormat.sampleRate * 0.4)) {
                gap.frameLength = gap.frameCapacity
                for b in UnsafeMutableAudioBufferListPointer(gap.mutableAudioBufferList) {
                    if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
                }
                try f.write(from: gap)
                frames += AVAudioFramePosition(gap.frameLength)
            }
        }
        guard file != nil, frames > 0 else { throw Failure.noAudio }
        file = nil   // 写完收口
        return Out(marks: marks, voiceName: voice?.name ?? "", premium: (voice?.quality ?? .default) != .default)
    }

    /// 一句念成几块 PCM（念完给一块空的收尾）
    private func buffers(_ u: AVSpeechUtterance) async -> [AVAudioPCMBuffer] {
        await withCheckedContinuation { (c: CheckedContinuation<[AVAudioPCMBuffer], Never>) in
            let box = Collect()
            synth.write(u) { buf in
                guard let pcm = buf as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    if box.finish() { c.resume(returning: box.items) }
                } else {
                    box.add(pcm)
                }
            }
        }
    }

    private final class Collect: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var items: [AVAudioPCMBuffer] = []
        private var done = false
        func add(_ b: AVAudioPCMBuffer) { lock.lock(); items.append(b); lock.unlock() }
        /// 只认第一次收尾
        func finish() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }
}
