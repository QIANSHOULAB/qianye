import Foundation
import XCTest
@testable import YiyeKit

/// 160：右滑扔——过七成松手就扔；线内弹回；过线、回线各轻震一下；垃圾桶过线后跟着纸条走
final class Swipe160Tests: XCTestCase {
    let w = 370.0

    func testReleaseAt80And55() {
        let s = SwipeTrash(width: w)
        XCTAssertTrue(s.release(w * 0.8))           // 拖到 80% 松手：扔
        XCTAssertFalse(s.release(w * 0.55))         // 55%：弹回
        XCTAssertTrue(s.release(w * 0.7))           // 正好七成：扔
    }

    func testOutThenBackStays() {
        var s = SwipeTrash(width: w)
        XCTAssertEqual(s.move(w * 0.3), .none)
        XCTAssertEqual(s.move(w * 0.8), .crossed)   // 过线：震
        XCTAssertEqual(s.move(w * 0.85), .none)     // 还在线外：不再震
        XCTAssertEqual(s.move(w * 0.5), .back)      // 拖回线内：再震一下
        XCTAssertFalse(s.release(w * 0.5))          // 拖到 80% 再拖回 50% 松手：还在
        XCTAssertFalse(s.past)
    }

    func testBegins() {
        XCTAssertTrue(SwipeTrash.begins(dx: 12, dy: 3, selecting: false, swipeOpen: false))
        XCTAssertFalse(SwipeTrash.begins(dx: 30, dy: 200, selecting: false, swipeOpen: false))   // 斜着往下：滚列表
        XCTAssertFalse(SwipeTrash.begins(dx: -20, dy: 0, selecting: false, swipeOpen: false))    // 往左：系统的左滑
        XCTAssertFalse(SwipeTrash.begins(dx: 3, dy: 0, selecting: false, swipeOpen: false))      // 还没走够
        XCTAssertFalse(SwipeTrash.begins(dx: 40, dy: 0, selecting: true, swipeOpen: false))      // 批量选里不扔
        XCTAssertFalse(SwipeTrash.begins(dx: 40, dy: 0, selecting: false, swipeOpen: true))      // 左滑开着：是收回去
    }

    func testIconFollowsAfterLine() {
        let s = SwipeTrash(width: w)
        XCTAssertEqual(s.iconX(w * 0.4, iconWidth: 60), 18)                    // 线内：停在最左边
        XCTAssertEqual(s.iconX(w * 0.8, iconWidth: 60), w * 0.8 - 60 - 18)     // 线外：跟着纸条左边走
    }
}
