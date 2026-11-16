import SwiftUI
import UserNotifications

@main
struct SoundcheckCompanionApp: App {
    @UIApplicationDelegateAdaptor(CompanionAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .onChange(of: phase) { _, phase in
            switch phase {
            case .active:
                // Looking for the Mac (which asks for the local network) waits for Get Started.
                if WelcomeView.hasStarted { MacLink.shared.activate() }
                SpeakerPlayer.shared.appBecameActive()
                MicStreamer.shared.appBecameActive()
                Notifications.clear()
                VolumeButtons.shared.update()
            case .background:
                VolumeButtons.shared.update()
                // Playing or listening keeps the app (and its link) running; otherwise iOS stops it.
                if !SpeakerPlayer.shared.isPlaying && !MicStreamer.shared.isRunning { MacLink.shared.deactivate() }
            default:
                break
            }
        }
    }
}

final class CompanionAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Notifications.setUp(delegate: self)
        _ = CallWatcher.shared
        // Relaunched for Bluetooth (the Mac woke it): the beacon picks up where it was.
        BeaconCentral.shared.start()
        return true
    }

    /// The notification asking to play or listen was tapped: the app is open now, which starts it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            MacLink.shared.activate()
            SpeakerPlayer.shared.appBecameActive()
            MicStreamer.shared.appBecameActive()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
