import Foundation

/// 123：写字页藏 Markdown 记号。记号照旧留在字里（存的、镜像的、交大管家的、抄到电脑的都不变），只是写字页不显示：
/// 光标不在的行藏起来，光标所在的行（选了一段的话，选区碰到的每一行）露出来。这里是「这一行露不露」的规则，不碰界面。
public enum MarkerVisibility {
    /// line：这一行的整段（含行尾换行）在全文里的 UTF-16 位置；selection：光标 / 选区；total：全文长度。
    /// 光标在这一行里、或者选区碰到这一行，就露。光标落在行尾换行后面（下一行的行首）算下一行，不算这一行；文章最后一行光标在文末也算在里面。
    public static func reveals(line: NSRange, selection: NSRange, total: Int) -> Bool {
        let lo = selection.location, hi = selection.location + selection.length
        let end = line.location + line.length
        if lo >= line.location && lo <= total && (lo < end || end >= total) { return true }
        if selection.length > 0 && hi > line.location && lo < end { return true }
        return false
    }

    /// 光标 / 选区变了，要不要重新染一遍：露出来的那几行变了才要（同一行里挪光标不用）
    public static func needsRestyle(oldKey: NSRange?, newKey: NSRange?) -> Bool { oldKey != newKey }
}
