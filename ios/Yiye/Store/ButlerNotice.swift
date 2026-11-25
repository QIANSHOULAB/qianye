import Foundation
import UserNotifications

/// 158：大管家的话来了、一叶笺在后台醒着（放听力、陪玩开着）：弹一条本地通知。第一次来的时候问一次通知权限
enum ButlerNotice {
    static func post(title: String, body: String, id: String) {
        let c = UNUserNotificationCenter.current()
        c.getNotificationSettings { s in
            if s.authorizationStatus == .notDetermined {
                c.requestAuthorization(options: [.alert, .sound]) { ok, _ in if ok { add(c, title, body, id) } }
            } else if s.authorizationStatus == .authorized || s.authorizationStatus == .provisional {
                add(c, title, body, id)
            }
        }
    }

    private static func add(_ c: UNUserNotificationCenter, _ title: String, _ body: String, _ id: String) {
        let n = UNMutableNotificationContent()
        n.title = title
        n.body = body
        n.sound = .default
        c.add(UNNotificationRequest(identifier: id, content: n, trigger: nil))
    }
}
