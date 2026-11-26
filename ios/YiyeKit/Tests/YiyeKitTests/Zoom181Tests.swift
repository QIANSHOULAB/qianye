import XCTest
@testable import YiyeKit

/// 181 遥控放大：点哪儿就是哪儿、边贴住不露白、两指是缩放还是滚轮
final class Zoom181Tests: XCTestCase {
    func testWholeScreenMapsStraight() {
        let z = RemoteZoom()
        XCTAssertFalse(z.zoomed)
        let p = z.picture((0.25, 0.75))
        XCTAssertEqual(p.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0.75, accuracy: 1e-9)
        XCTAssertEqual(z.moved(dx: 0.4, dy: -0.4), z)                 // 没放大挪不动
    }

    func testPinchKeepsThePointUnderTheFingers() {
        let z = RemoteZoom().pinched(factor: 3, from: (0.5, 0.5), to: (0.5, 0.5))
        XCTAssertEqual(z.scale, 3, accuracy: 1e-9)
        XCTAssertEqual(z.x, -1, accuracy: 1e-9)
        XCTAssertEqual(z.picture((0.5, 0.5)).x, 0.5, accuracy: 1e-9)   // 中点下面还是那一点
        // 在偏一边的地方张开
        let c = RemoteZoom().pinched(factor: 2, from: (0.8, 0.2), to: (0.8, 0.2))
        XCTAssertEqual(c.picture((0.8, 0.2)).x, 0.8, accuracy: 1e-9)
        XCTAssertEqual(c.picture((0.8, 0.2)).y, 0.2, accuracy: 1e-9)
        // 张开的同时两指挪了：起手那一点跟着走
        let m = RemoteZoom().pinched(factor: 2, from: (0.5, 0.5), to: (0.6, 0.4))
        XCTAssertEqual(m.picture((0.6, 0.4)).x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(m.picture((0.6, 0.4)).y, 0.5, accuracy: 1e-9)
    }

    func testScaleStaysBetweenOneAndFive() {
        let big = RemoteZoom().pinched(factor: 40, from: (0.5, 0.5), to: (0.5, 0.5))
        XCTAssertEqual(big.scale, 5, accuracy: 1e-9)
        let back = big.pinched(factor: 0.01, from: (0.9, 0.9), to: (0.1, 0.1))
        XCTAssertEqual(back, RemoteZoom())                              // 合到底就是整屏
        XCTAssertEqual(big.pinched(factor: .nan, from: (0, 0), to: (0, 0)), big)
        XCTAssertEqual(big.pinched(factor: -1, from: (0, 0), to: (0, 0)), big)
    }

    func testPanStopsAtTheEdges() {
        let z = RemoteZoom().pinched(factor: 3, from: (0.5, 0.5), to: (0.5, 0.5))
        let right = z.moved(dx: -9, dy: 9)                              // 往左下拖到底：看到右上角
        XCTAssertEqual(right.x, -2, accuracy: 1e-9)
        XCTAssertEqual(right.y, 0, accuracy: 1e-9)
        let tr = right.picture((1, 0))
        XCTAssertEqual(tr.x, 1, accuracy: 1e-9)
        XCTAssertEqual(tr.y, 0, accuracy: 1e-9)
        let left = z.moved(dx: 9, dy: -9)
        XCTAssertEqual(left.x, 0, accuracy: 1e-9)
        XCTAssertEqual(left.y, -2, accuracy: 1e-9)
        // 一半一半
        let half = z.moved(dx: 0.3, dy: 0)
        XCTAssertEqual(half.x, -0.7, accuracy: 1e-9)
        XCTAssertEqual(half.picture((0.5, 0.5)).x, (0.5 + 0.7) / 3, accuracy: 1e-9)
    }

    // ------------------------------------------------------------ 两指
    func testParallelSlideIsScroll() {
        var t = TwoFingers((100, 200), (220, 200))
        XCTAssertEqual(t.move((100, 190), (220, 191)), .undecided)      // 才挪 10 点
        XCTAssertEqual(t.move((101, 175), (221, 175)), .scroll)
        XCTAssertEqual(t.move((40, 100), (300, 100)), .scroll)          // 认定了，后来张开也还是滚轮
        XCTAssertEqual(t.travelY, -100, accuracy: 1e-9)
        XCTAssertEqual(RemoteMap.notches(dragY: t.travelY), -3)
    }

    func testPinchIsZoomAndNeverScrolls() {
        var t = TwoFingers((150, 200), (250, 200))
        XCTAssertEqual(t.move((147, 200), (253, 200)), .undecided)      // 6%
        XCTAssertEqual(t.move((144, 200), (256, 200)), .zoom)           // 12%
        XCTAssertEqual(t.move((100, 120), (300, 120)), .zoom)           // 中点挪了 80 点也还是缩放
        XCTAssertEqual(t.factor, 2, accuracy: 1e-9)
        var close = TwoFingers((150, 200), (250, 200))
        XCTAssertEqual(close.move((160, 200), (240, 200)), .zoom)       // 合拢也是缩放
        XCTAssertEqual(close.factor, 0.8, accuracy: 1e-9)
    }

    func testOneThumbStillPinchCountsAsZoom() {
        var t = TwoFingers((100, 300), (200, 200))                      // 大拇指不动，食指往外划
        XCTAssertEqual(t.move((100, 300), (212, 188)), .zoom)
    }

    func testJitterBetweenCloseFingersDecidesNothing() {
        var t = TwoFingers((100, 100), (140, 100))
        XCTAssertEqual(t.move((98, 100), (142, 100)), .undecided)       // 10%，但只有 4 点
        XCTAssertEqual(t.move((98, 99), (142, 101)), .undecided)
        XCTAssertEqual(t.move((98, 70), (142, 70)), .scroll)
    }
}
