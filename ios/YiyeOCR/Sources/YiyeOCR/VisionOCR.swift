import Foundation
import CoreGraphics
import ImageIO
import Vision
import YiyeKit

/// 本机认字：RecognizeDocumentsRequest 给段落、清单、表格、行；每行带信心和候选。全在手机上跑，不上传。
public enum VisionOCR {
    public static let wanted = ["zh-Hans", "en-US"]

    /// 先用它报的支持语言核一遍：要的语言里它认得的那些（一个都对不上就用它支持的全部）
    public static func languages() -> (use: [Locale.Language], supported: [String]) {
        let req = RecognizeDocumentsRequest()
        let supported = req.supportedRecognitionLanguages
        var use: [Locale.Language] = []
        for w in wanted {
            let lw = Locale.Language(identifier: w)
            if let hit = supported.first(where: { s in
                s.languageCode == lw.languageCode && (lw.script == nil || s.script == nil || s.script == lw.script)
            }) {
                use.append(hit)
            }
        }
        return (use.isEmpty ? supported : use, supported.map { $0.maximalIdentifier })
    }

    public struct Result: Sendable {
        public var page: OCRPage
        public var transcript: String
        public var languages: [String]
    }

    public static func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation = .up) async throws -> Result {
        var req = RecognizeDocumentsRequest()
        let langs = languages()
        req.textRecognitionOptions.recognitionLanguages = langs.use
        req.textRecognitionOptions.useLanguageCorrection = true
        req.textRecognitionOptions.automaticallyDetectLanguage = false
        req.textRecognitionOptions.maximumCandidateCount = 3
        let observations = try await req.perform(on: image, orientation: orientation)
        guard let doc = observations.first?.document else {
            return Result(page: OCRPage(blocks: []), transcript: "", languages: langs.use.map { $0.maximalIdentifier })
        }
        var pg = page(from: doc)
        // 第二遍：RecognizeTextRequest、不开语言校正，逐行对。两遍对不上的字就是拿不准的（网页版也是认两遍对答案）
        var tr = RecognizeTextRequest()
        tr.recognitionLevel = .accurate
        tr.recognitionLanguages = langs.use
        tr.usesLanguageCorrection = false
        tr.automaticallyDetectsLanguage = false
        if let second = try? await tr.perform(on: image, orientation: orientation) {
            pg = crossCheck(pg, with: second)
        }
        return Result(page: pg, transcript: doc.text.transcript, languages: langs.use.map { $0.maximalIdentifier })
    }

    /// 每一行找第二遍里位置对得上的那行，字不一样就把第二遍的放进候选的第一个
    static func crossCheck(_ page: OCRPage, with second: [RecognizedTextObservation]) -> OCRPage {
        let others: [(text: String, top: Double, left: Double, h: Double, w: Double)] = second.compactMap { o in
            guard let t = o.topCandidates(1).first?.string else { return nil }
            let b = o.boundingBox.cgRect
            return (t, 1 - Double(b.maxY), Double(b.minX), Double(b.height), Double(b.width))
        }
        var out = page
        for bi in out.blocks.indices {
            for li in out.blocks[bi].lines.indices {
                let l = out.blocks[bi].lines[li]
                guard l.crossCheck, l.width > 0, l.height > 0 else { continue }
                var best: (score: Double, text: String)? = nil
                for o in others {
                    let v = max(0, min(l.top + l.height, o.top + o.h) - max(l.top, o.top)) / max(1e-6, min(l.height, o.h))
                    let hz = max(0, min(l.left + l.width, o.left + o.w) - max(l.left, o.left)) / max(1e-6, l.width)
                    guard v >= 0.5, hz >= 0.6 else { continue }
                    let score = v + hz
                    if best == nil || score > best!.score { best = (score, o.text) }
                }
                guard let b = best else { continue }
                let a = l.text.filter { !$0.isWhitespace }, c = b.text.filter { !$0.isWhitespace }
                if a != c { out.blocks[bi].lines[li].alternatives.insert(b.text, at: 0) }
            }
        }
        return out
    }

    // ---------------------------------------------------------------- Vision → 纯数据
    static func page(from doc: DocumentObservation.Container) -> OCRPage {
        var blocks: [OCRBlock] = []
        var used = Set<UUID>()       // 清单、表格里用过的行，段落里不再出现

        for list in doc.lists {
            for item in list.items {
                let ls = item.content.text.lines
                guard !ls.isEmpty else { continue }
                ls.forEach { used.insert($0.uuid) }
                blocks.append(OCRBlock(kind: .listItem(marker: item.markerString), lines: lines(ls, words: item.content.text.words)))
            }
        }
        for table in doc.tables {
            for row in table.rows {
                var cellTexts: [String] = []
                var conf: Float = 1
                var alts: [String] = []
                var top = 1.0, left = 1.0, height = 0.0
                for cell in row {
                    let ls = cell.content.text.lines
                    ls.forEach { used.insert($0.uuid) }
                    let t = cell.content.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty { continue }
                    cellTexts.append(t.replacingOccurrences(of: "\n", with: " "))
                    for l in ls {
                        conf = min(conf, l.confidence)
                        let b = l.boundingBox.cgRect
                        top = min(top, 1 - Double(b.maxY)); left = min(left, Double(b.minX)); height = max(height, Double(b.height))
                    }
                }
                guard !cellTexts.isEmpty else { continue }
                let text = cellTexts.joined(separator: " ")
                if conf < 0.5 { alts = [] }
                blocks.append(OCRBlock(kind: .paragraph, lines: [OCRLine(text: text, confidence: conf, alternatives: alts, wraps: false, top: top, left: left, height: height, crossCheck: false)]))
            }
        }
        if let title = doc.title {
            let ls = title.lines.filter { !used.contains($0.uuid) }
            ls.forEach { used.insert($0.uuid) }
            if !ls.isEmpty { blocks.append(OCRBlock(kind: .title, lines: lines(ls, words: title.words), centered: title.textAlignment == .center)) }
        }
        for p in doc.paragraphs {
            let ls = p.lines.filter { !used.contains($0.uuid) }
            guard !ls.isEmpty else { continue }
            blocks.append(OCRBlock(kind: .paragraph, lines: lines(ls, words: p.words), centered: p.textAlignment == .center))
        }
        // 段落里一行都没有（有的图 Vision 只给 text）：退回整页的行
        if blocks.isEmpty {
            let ls = doc.text.lines
            if !ls.isEmpty { blocks.append(OCRBlock(kind: .paragraph, lines: lines(ls, words: doc.text.words))) }
        }
        return OCRPage(blocks: blocks)
    }

    static func lines(_ obs: [RecognizedTextObservation], words: [RecognizedTextObservation]?) -> [OCRLine] {
        obs.map { o in
            let cands = o.topCandidates(3)
            let text = cands.first?.string ?? o.transcript
            let b = o.boundingBox.cgRect
            // 这一行里信心低的词（Vision 给了逐词结果才有）
            var weak: [String] = []
            for w in words ?? [] where w.confidence < 0.5 {
                let wb = w.boundingBox.cgRect
                let midY = wb.midY
                if midY >= b.minY && midY <= b.maxY, let s = w.topCandidates(1).first?.string, !s.isEmpty, text.contains(s) { weak.append(s) }
            }
            return OCRLine(text: text,
                           confidence: min(o.confidence, cands.first?.confidence ?? o.confidence),
                           alternatives: cands.dropFirst().map(\.string),
                           wraps: o.shouldWrapToNextLine,
                           isTitle: o.isTitle,
                           top: 1 - Double(b.maxY), left: Double(b.minX), height: Double(b.height), width: Double(b.width),
                           weakWords: weak)
        }
    }
}

/// 认字以后的整条路：图 → 草稿（标题、清单、名字＋数字各归各位，拿不准的记位置）
public enum PhotoToDraft {
    public static func run(_ image: CGImage, orientation: CGImagePropertyOrientation = .up) async throws -> (draft: OCRDraft, transcript: String, page: OCRPage) {
        let r = try await VisionOCR.recognize(image, orientation: orientation)
        let built = DraftBuilder.build(r.page)
        let tidy = IntakeFormatter.tidy(Intake(kind: .photo, markdown: built.markdown, unsure: built.unsure))
        return (OCRDraft(markdown: tidy.markdown, unsure: tidy.unsure), r.transcript, r.page)
    }
}
