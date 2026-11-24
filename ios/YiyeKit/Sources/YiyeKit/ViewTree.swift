/// 在一棵树里找第一个对得上的节点（先自己，再按顺序往里一层层找，深度优先）。
/// 一叶笺用它到苹果的直播选择器（RPSystemBroadcastPickerView）里找那颗 UIButton：
/// 按钮有时在直接一层，有时套两三层，有时 layoutSubviews 之后才建出来；找不到就明确回 nil，由界面弹提示。
/// 写成泛型是为了不碰 UIKit，Linux 上也能测。
public func findFirst<N>(in root: N, children: (N) -> [N], where match: (N) -> Bool) -> N? {
    if match(root) { return root }
    for c in children(root) {
        if let hit = findFirst(in: c, children: children, where: match) { return hit }
    }
    return nil
}
