import XCTest
@testable import YiyeKit

final class Theme132Tests: XCTestCase {
    // ---- 纸：跟整体 / 钉住
    func testOldWhiteFollows() {
        XCTAssertNil(PaperMark.pinned("white"))
        XCTAssertNil(PaperMark.pinned(""))
        XCTAssertNil(PaperMark.pinned("whatever"))
    }

    func testPickedColorsPin() {
        for c in ["yellow", "green", "blue", "pink"] {
            XCTAssertEqual(PaperMark.pinned(PaperMark.store(pick: c)), c)
        }
    }

    func testPickedWhiteIsPinnedToo() {
        let s = PaperMark.store(pick: "white")
        XCTAssertNotEqual(s, "white")                  // 不能跟老的默认白混
        XCTAssertEqual(PaperMark.pinned(s), "white")
    }

    func testMirrorRoundTrip() {
        // 跟整体：镜像里不写死颜色，读回来还是跟整体
        XCTAssertEqual(PaperMark.toMirror("white"), "follow")
        XCTAssertEqual(PaperMark.fromMirror("follow"), "white")
        // 老镜像里的 color: white 也是跟整体
        XCTAssertEqual(PaperMark.fromMirror("white"), "white")
        XCTAssertNil(PaperMark.pinned(PaperMark.fromMirror("white")))
        // 钉住的：原样往返，钉住的白也分得清
        for stored in ["yellow", "green", "blue", "pink", PaperMark.pinnedWhite] {
            XCTAssertEqual(PaperMark.fromMirror(PaperMark.toMirror(stored)), stored)
            XCTAssertNotNil(PaperMark.pinned(PaperMark.fromMirror(PaperMark.toMirror(stored))))
        }
    }

    // ---- 颜色换算
    func testHexHSLRoundTrip() {
        for h in [UInt32(0xFBF8F1), 0xC2410C, 0x1C1814, 0xE9F2DC, 0x4A3F36, 0xFFFFFF, 0x000000, 0x808080] {
            let back = ThemeMath.hex(ThemeMath.hsl(h))
            for shift in [16, 8, 0] {
                let a = Int((h >> UInt32(shift)) & 0xFF), b = Int((back >> UInt32(shift)) & 0xFF)
                XCTAssertLessThanOrEqual(abs(a - b), 1, String(h, radix: 16))
            }
        }
    }

    func testRecolorKeepsLightnessAndMovesHue() {
        let src: UInt32 = 0xD9C19A
        let out = ThemeMath.recolor(src, hue: 120, satScale: 1)
        XCTAssertEqual(ThemeMath.hsl(out).l, ThemeMath.hsl(src).l, accuracy: 0.01)
        XCTAssertEqual(ThemeMath.hsl(out).h, 120, accuracy: 2)
    }

    func testRecolorKeepsGrayGray() {
        let out = ThemeMath.recolor(0x808080, hue: 200, satScale: 2)
        XCTAssertEqual(out, 0x808080)
    }

    func testContrastBlackWhite() {
        XCTAssertEqual(ThemeMath.contrast(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
    }
}
