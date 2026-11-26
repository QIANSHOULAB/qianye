import Foundation
import XCTest
@testable import YiyeKit

/// 162 项目待办：信认得出、不当听力稿；同一个 id 只一条便签；他没改过才更新；办完进废纸篓；请求长什么样
final class Todo162Tests: XCTestCase {
    let raw = #"{"v":2,"kind":"delivery","kind2":"todo","id":"todo-1125-01~a1b2c3~1","at":"2026-11-26T09:00:00+08:00","data":{"v":1,"id":"todo-1125-01~a1b2c3~1","kind":"todo","kind2":"todo","todo":"1125-01-一叶笺0.7.22真机试","title":"一叶笺 0.7.22 真机试","text":"1. 打开\n2. 点一下","folder":"项目待办","at":"2026-11-26T09:00:00+08:00"}}"#

    func testDecodeTodoLetter() throws {
        let env = try MailEnvelope.decode(Data(raw.utf8))
        let d = try XCTUnwrap(env.delivery)
        XCTAssertEqual(MailAction.decide(env, waiting: [:], dubbing: [:]), .todo(d))
        XCTAssertEqual(Todo.id(of: d), "1125-01-一叶笺0.7.22真机试")
        XCTAssertEqual(d.folder, Todo.folder)
        XCTAssertEqual(Todo.markdown(title: d.title, text: d.text), "# 一叶笺 0.7.22 真机试\n\n1. 打开\n2. 点一下")
    }

    func testDoneLetterIsTodoToo() throws {
        let r = #"{"v":2,"kind":"delivery","kind2":"todo-done","id":"todo-done-x~1","data":{"v":1,"id":"todo-done-x~1","kind":"todo-done","kind2":"todo-done","todo":"x","text":""}}"#
        let env = try MailEnvelope.decode(Data(r.utf8))
        let d = try XCTUnwrap(env.delivery)
        XCTAssertEqual(MailAction.decide(env, waiting: [:], dubbing: [:]), .todo(d))
        XCTAssertEqual(d.kind, Todo.kindDone)
    }

    func testOldLetterWithoutTodoFieldUsesID() {
        let d = ButlerDelivery(id: "abc", kind: "todo", text: "t", audio: nil, marks: nil)
        XCTAssertEqual(Todo.id(of: d), "abc")
    }

    func testListeningStillListening() throws {
        let r = #"{"v":2,"kind":"delivery","id":"l-1","data":{"v":1,"id":"l-1","kind":"listen","text":"Hi"}}"#
        let env = try MailEnvelope.decode(Data(r.utf8))
        if case .todo = MailAction.decide(env, waiting: [:], dubbing: [:]) { XCTFail("听力稿被当成待办") }
    }

    func testSameIDSameNote() {
        XCTAssertEqual(Todo.noteID("1125-01"), Todo.noteID("1125-01"))
        XCTAssertNotEqual(Todo.noteID("1125-01"), Todo.noteID("1125-02"))
        XCTAssertEqual(Todo.noteID("a").uuidString.count, 36)
    }

    func testCreateOnceThenUpdateOnlyWhenUntouched() {
        var b = TodoBook()
        let id = Todo.noteID("t1")
        XCTAssertEqual(b.receive(todo: "t1", markdown: "# A\n\n1", now: nil), .create(id, "# A\n\n1"))
        // 同一封又来（30 分钟没回执补寄的）：一样，不动
        XCTAssertEqual(b.receive(todo: "t1", markdown: "# A\n\n1", now: TodoNow(trashed: false, markdown: "# A\n\n1")), .none("一样"))
        // 那边改了内容，他没动过：换
        XCTAssertEqual(b.receive(todo: "t1", markdown: "# A\n\n2", now: TodoNow(trashed: false, markdown: "# A\n\n1")), .update(id, "# A\n\n2"))
        // 他自己改过：不换
        XCTAssertEqual(b.receive(todo: "t1", markdown: "# A\n\n3", now: TodoNow(trashed: false, markdown: "# A\n\n2 我加的")), .none("他改过"))
        // 他扔了：不再建
        XCTAssertEqual(b.receive(todo: "t1", markdown: "# A\n\n3", now: TodoNow(trashed: true, markdown: "# A\n\n2")), .none("他扔了"))
    }

    func testDoneTrashesOnce() {
        let b = TodoBook()
        XCTAssertEqual(b.done(todo: "t1", now: TodoNow(trashed: false, markdown: "x")), .trash(Todo.noteID("t1")))
        XCTAssertEqual(b.done(todo: "t1", now: TodoNow(trashed: true, markdown: "x")), .none("已经在废纸篓"))
        XCTAssertEqual(b.done(todo: "t1", now: nil), .none("手机上没有"))
    }

    func testBookRoundTripAndReverseLookup() {
        var b = TodoBook()
        _ = b.receive(todo: "t9", markdown: "x", now: nil)
        let back = TodoBook.load(b.data())
        XCTAssertEqual(back, b)
        XCTAssertEqual(back.todo(of: Todo.noteID("t9")), "t9")
        XCTAssertNil(back.todo(of: UUID()))
        XCTAssertEqual(TodoBook.load(nil), TodoBook())
    }

    func testRequests() {
        let ok = ButlerRequest.todoOK(id: "r1", of: "todo-x~1", at: "2026-11-26T09:00:01+08:00", app: "0.7.29")
        XCTAssertEqual(ok.ask, "todo-ok")
        XCTAssertEqual(ok.note, "todo-x~1")
        let done = ButlerRequest.todoDone(id: "r2", todo: "1125-01", at: "2026-11-26T09:00:01+08:00", app: "0.7.29")
        XCTAssertEqual(done.ask, "todo-done")
        XCTAssertEqual(done.note, "1125-01")
        XCTAssertEqual(ButlerRequest.todoUndo(id: "r3", todo: "1125-01", at: "", app: "").ask, "todo-undo")
    }
}
