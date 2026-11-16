import CallKit
import Foundation

/// Phone calls on this iPhone, for Quiet Apps in Calls on the Mac: a call answered here keeps
/// the Mac's apps down until it ends (the Mac only knows it rang). Told to the Mac as calls
/// change while the app's awake, and whenever the Mac asks (over Wi-Fi, or Bluetooth when the
/// app's asleep in the background).
@MainActor
final class CallWatcher: NSObject, CXCallObserverDelegate {
    static let shared = CallWatcher()
    private let observer = CXCallObserver()

    override init() {
        super.init()
        observer.setDelegate(self, queue: .main)
    }

    /// (on a call, ringing)
    var current: (active: Bool, ringing: Bool) {
        let calls = observer.calls.filter { !$0.hasEnded }
        return (calls.contains { $0.hasConnected }, calls.contains { !$0.hasConnected && !$0.isOutgoing })
    }

    /// Tells the Mac (over Wi-Fi if connected).
    func report() {
        let now = current
        MacLink.shared.send(.callState(active: now.active, ringing: now.ringing))
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        MainActor.assumeIsolated {
            report()
            BeaconCentral.shared.reportCall()
        }
    }
}
