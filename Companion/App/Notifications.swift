import UserNotifications

/// When the Mac picks this device as a speaker or microphone while the app's asleep, iOS won't
/// let it start sound on its own: a notification asks, and tapping it opens the app, which starts
/// straight away (and can go back to the background).
enum Notifications {
    static let playCategory = "play"
    static let listenCategory = "listen"

    static func setUp(delegate: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        let play = UNNotificationAction(identifier: "play", title: "Play Here", options: [.foreground])
        let listen = UNNotificationAction(identifier: "listen", title: "Use Microphone", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: playCategory, actions: [play], intentIdentifiers: []),
            UNNotificationCategory(identifier: listenCategory, actions: [listen], intentIdentifiers: []),
        ])
    }

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func askToPlay(mac: String) {
        post(id: "play", category: playCategory, title: "Play \(mac) here?", body: "Tap to play your Mac's sound on this \(PairingStore.deviceKind).")
    }

    static func askToListen(mac: String) {
        post(id: "listen", category: listenCategory, title: "Use this \(PairingStore.deviceKind) as \(mac)'s microphone?",
             body: "Tap to turn on the microphone.")
    }

    static func clear() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["play", "listen"])
    }

    private static func post(id: String, category: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.interruptionLevel = .timeSensitive
        content.sound = nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
