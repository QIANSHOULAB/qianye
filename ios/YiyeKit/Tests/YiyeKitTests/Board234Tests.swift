import Foundation
import XCTest
@testable import YiyeKit

/// 234 看板：信认得出、不当听力稿也不当待办；新建；同一个 board 原地换标题和正文；扔掉以后另建；回执长什么样
final class Board234Tests: XCTestCase {
    let raw = ##"{"v":2,"kind":"delivery","kind2":"board","id":"board-game-log~1","at":"2026-11-27T20:30:00+08:00","data":{"v":1,"id":"board-game-log~1","kind":"board","kind2":"board","board":"game-log","title":"游戏记录","text":"# 游戏记录\n\n本周 **12 小时 30 分**。\n\n## 本周\n- **Soulframe**：**6 小时 10 分**","folder":"游戏","at":"2026-11-27T20:30:00+08:00"}}"##

    /// 手机上的便签（假的）
    private struct Phone {
        var notes: [UUID: BoardNow] = [:]
        mutating func apply(_ step: BoardBook.Step) {
            switch step {
            case .create(let id, let md):
                XCTAssertNil(notes[id], "新建不能占别人的号")
                notes[id] = BoardNow(trashed: false, markdown: md)
            case .update(let id, let md):
                notes[id]?.markdown = md
            case .none:
                break
            }
        }
        var live: [BoardNow] { notes.values.filter { !$0.trashed } }
    }

    private func send(_ book: inout BoardBook, _ phone: inout Phone, _ md: String, at: String? = nil, board: String = "game-log") -> BoardBook.Step {
        let snapshot = phone.notes
        let step = book.receive(board: board, markdown: md, at: at) { snapshot[$0] }
        phone.apply(step)
        return step
    }

    /// 先走完这一步（要改本子和手机，别写在 XCTAssert 的自动闭包里），再对答案
    private func expect(_ got: BoardBook.Step, _ want: BoardBook.Step, line: UInt = #line) {
        XCTAssertEqual(got, want, line: line)
    }

    func testDecodeBoardLetter() throws {
        let env = try MailEnvelope.decode(Data(raw.utf8))
        let d = try XCTUnwrap(env.delivery)
        XCTAssertEqual(MailAction.decide(env, waiting: [:], dubbing: [:]), .board(d))
        XCTAssertEqual(Board.id(of: d), "game-log")
        XCTAssertEqual(d.folder, "游戏")
        XCTAssertEqual(Board.markdown(title: d.title, text: d.text),
                       "# 游戏记录\n\n本周 **12 小时 30 分**。\n\n## 本周\n- **Soulframe**：**6 小时 10 分**")
    }

    func testBoardIsNeitherTodoNorListening() throws {
        let env = try MailEnvelope.decode(Data(raw.utf8))
        switch MailAction.decide(env, waiting: [:], dubbing: [:]) {
        case .board: break
        default: XCTFail("看板信被认成别的")
        }
        let todo = #"{"v":2,"kind":"delivery","kind2":"todo","id":"t~1","data":{"v":1,"id":"t~1","kind":"todo","kind2":"todo","todo":"t","text":"x"}}"#
        let todoEnv = try MailEnvelope.decode(Data(todo.utf8))
        if case .board = MailAction.decide(todoEnv, waiting: [:], dubbing: [:]) { XCTFail("待办被认成看板") }
        XCTAssertNotEqual(Board.noteID("t"), Todo.noteID("t"))
        // 看板便签不进待办的本子：扔它认不出是哪个待办 = 不寄 todo-done
        var todos = TodoBook()
        _ = todos.receive(todo: "game-log", markdown: "x", now: nil)
        XCTAssertNil(todos.todo(of: Board.noteID("game-log")))
    }

    func testTitleWinsAndHeadingNotDoubled() {
        XCTAssertEqual(Board.markdown(title: "游戏记录", text: "本周 **1 小时**。"), "# 游戏记录\n\n本周 **1 小时**。")
        XCTAssertEqual(Board.markdown(title: "新标题", text: "# 旧标题\n\n正文"), "# 新标题\n\n正文")
        XCTAssertEqual(Board.markdown(title: "标题", text: "## 本周\n- a"), "# 标题\n\n## 本周\n- a")
        XCTAssertEqual(Board.markdown(title: "标题", text: "# 标题"), "# 标题")
        XCTAssertEqual(Board.markdown(title: "", text: "# 自带\n\n正文"), "# 自带\n\n正文")
        XCTAssertEqual(Board.markdown(title: nil, text: "光正文"), "光正文")
    }

    func testCreateThenUpdateInPlace() {
        var book = BoardBook(), phone = Phone()
        let first = send(&book, &phone, "# 游戏记录\n\n1 小时", at: "2026-11-27T20:00:00+08:00")
        XCTAssertEqual(first, .create(Board.noteID("game-log"), "# 游戏记录\n\n1 小时"))
        // 标题、正文都换，还是那一条
        let second = send(&book, &phone, "# 新标题\n\n2 小时", at: "2026-11-27T21:00:00+08:00")
        XCTAssertEqual(second, .update(Board.noteID("game-log"), "# 新标题\n\n2 小时"))
        XCTAssertEqual(phone.notes.count, 1)
        XCTAssertEqual(phone.live.first?.markdown, "# 新标题\n\n2 小时")
    }

    func testOverwritesWhatHeTyped() {
        var book = BoardBook(), phone = Phone()
        _ = send(&book, &phone, "a", at: "2026-11-27T20:00:00+08:00")
        phone.notes[Board.noteID("game-log")]?.markdown = "a 我手记的"
        expect(send(&book, &phone, "b", at: "2026-11-27T21:00:00+08:00"), .update(Board.noteID("game-log"), "b"))
        // 内容跟上回一样、但他改过：照样盖回去
        phone.notes[Board.noteID("game-log")]?.markdown = "b 又手记"
        expect(send(&book, &phone, "b", at: "2026-11-27T21:30:00+08:00"), .update(Board.noteID("game-log"), "b"))
    }

    func testSameContentResendDoesNothing() {
        var book = BoardBook(), phone = Phone()
        _ = send(&book, &phone, "a", at: "2026-11-27T20:00:00+08:00")
        expect(send(&book, &phone, "a", at: "2026-11-27T20:30:00+08:00"), .none("一样"))
        XCTAssertEqual(phone.notes.count, 1)
    }

    func testLateOlderLetterDoesNotRollBack() {
        var book = BoardBook(), phone = Phone()
        _ = send(&book, &phone, "新", at: "2026-11-27T21:00:00+08:00")
        expect(send(&book, &phone, "旧", at: "2026-11-27T20:00:00+08:00"), .none("迟到的"))
        XCTAssertEqual(phone.live.first?.markdown, "新")
        // 时区写法不同也按真时间比
        expect(send(&book, &phone, "更新", at: "2026-11-27T14:00:00+00:00"), .update(Board.noteID("game-log"), "更新"))
        // 没写时间的照收
        expect(send(&book, &phone, "没时间", at: nil), .update(Board.noteID("game-log"), "没时间"))
    }

    func testRebuiltAfterHeThrowsItAway() {
        var book = BoardBook(), phone = Phone()
        _ = send(&book, &phone, "a", at: "2026-11-27T20:00:00+08:00")
        let old = Board.noteID("game-log")
        phone.notes[old]?.trashed = true
        // 内容一样也重建一条新的，废纸篓里那条不动
        let next = Board.noteID("game-log", generation: 1)
        expect(send(&book, &phone, "a", at: "2026-11-27T21:00:00+08:00"), .create(next, "a"))
        XCTAssertEqual(phone.notes[old]?.trashed, true)
        XCTAssertEqual(phone.live.count, 1)
        // 新的这条接着原地更新
        expect(send(&book, &phone, "b", at: "2026-11-27T22:00:00+08:00"), .update(next, "b"))
        // 废纸篓里那条 3 天到了真删：不影响
        phone.notes[old] = nil
        expect(send(&book, &phone, "c", at: "2026-11-27T23:00:00+08:00"), .update(next, "c"))
        // 新的也真删了：再建，用空出来的号
        phone.notes[next] = nil
        expect(send(&book, &phone, "d", at: "2026-11-28T00:00:00+08:00"), .create(old, "d"))
    }

    func testRebuiltAfterPurgeNow() {
        var book = BoardBook(), phone = Phone()
        _ = send(&book, &phone, "a")
        phone.notes = [:]
        expect(send(&book, &phone, "a"), .create(Board.noteID("game-log"), "a"))
    }

    func testPutBackOldOneIsAdoptedWhenNothingElseLives() {
        var book = BoardBook(), phone = Phone()
        _ = send(&book, &phone, "a")
        let old = Board.noteID("game-log")
        phone.notes[old]?.trashed = true
        phone.notes[old]?.trashed = false          // 撤销放回来
        expect(send(&book, &phone, "b"), .update(old, "b"))
        XCTAssertEqual(phone.notes.count, 1)
    }

    func testBookLostStillFindsTheNote() {
        var book = BoardBook(), phone = Phone()
        _ = send(&book, &phone, "a")
        phone.notes[Board.noteID("game-log")]?.trashed = true
        _ = send(&book, &phone, "b")
        var fresh = BoardBook()                     // 重装：本子没了，便签从镜像导回来了
        expect(send(&fresh, &phone, "c"), .update(Board.noteID("game-log", generation: 1), "c"))
        XCTAssertEqual(phone.notes.count, 2)
    }

    func testTwoBoardsTwoNotes() {
        var book = BoardBook(), phone = Phone()
        _ = send(&book, &phone, "a", board: "game-log")
        _ = send(&book, &phone, "b", board: "other")
        XCTAssertEqual(phone.live.count, 2)
        XCTAssertTrue(book.owns(Board.noteID("game-log")))
        XCTAssertTrue(book.owns(Board.noteID("other")))
        XCTAssertFalse(book.owns(UUID()))
    }

    func testBookRoundTrip() {
        var book = BoardBook(), phone = Phone()
        _ = send(&book, &phone, "a", at: "2026-11-27T20:00:00+08:00")
        XCTAssertEqual(BoardBook.load(book.data()), book)
        XCTAssertEqual(BoardBook.load(nil), BoardBook())
        XCTAssertEqual(Board.noteID("game-log"), Board.noteID("game-log"))
        XCTAssertNotEqual(Board.noteID("game-log"), Board.noteID("game-log", generation: 1))
    }

    func testNoBoardIDIsNotABoard() {
        XCTAssertNil(Board.id(of: ButlerDelivery(id: "x", kind: Board.kind, text: "t", audio: nil, marks: nil)))
    }

    func testReceipt() {
        let ok = ButlerRequest.boardOK(id: "r1", of: "board-game-log~1", at: "2026-11-27T20:30:01+08:00", app: "0.7.42")
        XCTAssertEqual(ok.ask, "board-ok")
        XCTAssertEqual(ok.note, "board-game-log~1")
        XCTAssertEqual(ok.app, "0.7.42")
    }
}
