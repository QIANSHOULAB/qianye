import Foundation

// 图片上下的空行（Song 11-22 11:44：「插入图片默认空一个，一个字没打插入图片后直接顶到上面的。图片之间隔开一格，
// 我认为做成按键吧一个是靠拢一个是空一个。因为有时候打字不好点。默认是空一格的位置」）。
// 写字页里一张图 = 独占一行的一个附件字符（DisplayMap.attachmentChar）。这里只算换行，图和字一个不碰。

public enum ImageSpacing {
    public struct Plan: Equatable, Sendable {
        /// 图前补几个换行、图后补几个换行
        public var prefix: Int
        public var suffix: Int
        /// 插完光标从插入点往后挪几个 UTF-16：落在图下面那一行的开头（空一格时是空行下面那一行）
        public var caret: Int
    }

    /// 插一张图。before / after：光标前、后的字（选中的字会被换掉，不算在里面）。
    /// gap：图跟上面、下面的字或图都隔一个空行；一个字都没有时上面也空一行（好在图上面写标题）。
    /// 不 gap（靠拢）：只保证图独占一行。已经有的空行不删。
    public static func insertion(before: String, after: String, gap: Bool) -> Plan {
        let need = gap ? 2 : 1
        let prefix: Int
        if before.allSatisfy({ $0 == "\n" }) {
            prefix = gap && before.isEmpty ? 1 : 0
        } else {
            let k = before.reversed().prefix(while: { $0 == "\n" }).count
            prefix = max(0, need - k)
        }
        let m = after.prefix(while: { $0 == "\n" }).count
        let suffix = max(0, need - m)
        return Plan(prefix: prefix, suffix: suffix, caret: prefix + 1 + need)
    }

    static func isBlank(_ s: String) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }
    static func isImage(_ s: String) -> Bool { s == String(DisplayMap.attachmentChar) }

    /// 整条重排：每张图跟上下的字、图之间正好一个空行（gap），或者一个都不留（靠拢）。
    /// 图在最上面：gap 上面空一行，靠拢顶到头。只动挨着图的空行；字跟字之间的、最后面的空行都不动
    public static func respace(_ text: String, gap: Bool) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.firstIndex(where: { !isBlank($0) }) else { return text }
        let want = gap ? 1 : 0
        func run(_ blanks: ArraySlice<String>) -> [String] { blanks.count == want ? Array(blanks) : Array(repeating: "", count: want) }
        var out: [String] = isImage(lines[first]) ? run(lines[0..<first]) : Array(lines[0..<first])
        var i = first
        while i < lines.count {
            out.append(lines[i])
            var j = i + 1
            while j < lines.count && isBlank(lines[j]) { j += 1 }
            if j >= lines.count {
                out += lines[(i + 1)...]
                break
            }
            out += isImage(lines[i]) || isImage(lines[j]) ? run(lines[(i + 1)..<j]) : Array(lines[(i + 1)..<j])
            i = j
        }
        return out.joined(separator: "\n")
    }

    /// 两段字只差在换行、空格上（图、字一个没动）：可以放心照差异一处一处改
    public static func onlyBlanksDiffer(_ old: String, _ new: String) -> Bool {
        TextDiff.ops(old, new).allSatisfy {
            switch $0 {
            case .same: return true
            case .del(let c), .ins(let c): return c == "\n" || c == " " || c == "\t"
            }
        }
    }

    /// 改完以后光标该在哪（UTF-16）：跟着它前面的字走；正好在新加的空行前面的，挪到空行后面
    public static func caret(_ pos: Int, from old: String, to new: String) -> Int {
        var o = 0
        var n = 0
        for op in TextDiff.ops(old, new) {
            switch op {
            case .ins(let c):
                if o <= pos { n += String(c).utf16.count }
            case .del(let c):
                if o >= pos { return n }
                o += String(c).utf16.count
            case .same(let c):
                if o >= pos { return n }
                let w = String(c).utf16.count
                o += w
                n += w
            }
        }
        return n
    }
}
