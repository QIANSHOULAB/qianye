import XCTest
@testable import YiyeKit

/// 104：苹果直播选择器里的按钮，各种层级下都找得到，没建出来就明确回 nil
final class ViewTreeTests: XCTestCase {
    final class Node {
        let name: String
        let kids: [Node]
        init(_ name: String, _ kids: [Node] = []) { self.name = name; self.kids = kids }
    }

    private func button(in root: Node) -> Node? {
        findFirst(in: root, children: { $0.kids }, where: { $0.name == "button" })
    }

    func testDirectChild() {
        let picker = Node("picker", [Node("label"), Node("button")])
        XCTAssertEqual(button(in: picker)?.name, "button")
    }

    func testNestedTwoLevels() {
        let picker = Node("picker", [Node("wrap", [Node("inner", [Node("button")])])])
        XCTAssertEqual(button(in: picker)?.name, "button")
    }

    func testNestedInLaterSibling() {
        let picker = Node("picker", [Node("a", [Node("x")]), Node("b", [Node("y", [Node("button")])])])
        XCTAssertEqual(button(in: picker)?.name, "button")
    }

    func testNotBuiltYet() {
        XCTAssertNil(button(in: Node("picker")))
        XCTAssertNil(button(in: Node("picker", [Node("label", [Node("image")])])))
    }

    func testRootItselfMatches() {
        XCTAssertEqual(button(in: Node("button"))?.name, "button")
    }

    func testFirstInOrderWins() {
        let first = Node("button"), second = Node("button")
        let picker = Node("picker", [Node("a", [first]), second])
        XCTAssertTrue(button(in: picker) === first)
    }
}
