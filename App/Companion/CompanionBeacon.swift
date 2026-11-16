import CoreBluetooth
import CryptoKit
import Foundation
import os

private let beaconLog = Logger(subsystem: "com.mylesdean.Soundcheck", category: "companion")

/// A small Bluetooth service, so Soundcheck can wake its companions. iOS puts an app to sleep
/// soon after it leaves the screen, which closes its Wi-Fi link, but it keeps a Bluetooth
/// connection for it and wakes it for a few seconds when the other end sends something. That's
/// how a companion hears that it was picked as a speaker or a microphone on the Mac, or is asked
/// whether a phone call is on. Only started once a companion is paired (macOS asks for Bluetooth
/// then).
final class CompanionBeacon: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    static let shared = CompanionBeacon()

    private let queue = DispatchQueue(label: "com.mylesdean.Soundcheck.beacon")
    private var manager: CBPeripheralManager?
    private var events: CBMutableCharacteristic?
    /// Which companion each connected central is (from its signed hello).
    private var centrals: [UUID: (central: CBCentral, device: String, pairing: String)] = [:]
    private var subscribed: Set<UUID> = []
    private var counter: UInt32 = UInt32(Date().timeIntervalSince1970) & 0x3FFF_FFFF
    private var lastHello: [String: UInt32] = [:]
    /// Events for companions that aren't connected yet: sent when they are (briefly kept).
    private var waiting: [String: (event: CompanionBeaconFormat.Event, until: Date)] = [:]

    /// The pairing keys and this Mac's ID (thread-safe; set from the main actor).
    private var keys: PairingKeys?
    private var macID = ""

    @MainActor func start() {
        let keys = CompanionHub.shared.keys, macID = CompanionHub.shared.macID
        queue.async { [self] in
            self.keys = keys
            self.macID = macID
            guard manager == nil else { return }
            manager = CBPeripheralManager(delegate: self, queue: queue)
        }
    }

    @MainActor func stop() {
        queue.async { [self] in
            manager?.stopAdvertising()
            manager?.removeAllServices()
            manager = nil
            centrals = [:]
            subscribed = []
        }
    }

    /// Wakes a companion with an event (or sends it as soon as it connects).
    @MainActor func send(_ event: CompanionBeaconFormat.Event, to device: String) {
        guard let pairing = CompanionHub.shared.devices.first(where: { $0.id == device })?.pairing,
              let key = CompanionHub.shared.keys.key(pairing) else { return }
        queue.async { [self] in
            guard manager != nil else { return }
            if let entry = centrals.first(where: { $0.value.device == device && subscribed.contains($0.key) }) {
                notify(entry.value.central, event, key: key, device: device)
            } else {
                // Kept longer than a speaker waits to start (90 s) before trying again, so a
                // companion coming back in range is always woken while the Mac still wants it.
                waiting[device] = (event, Date().addingTimeInterval(120))
            }
        }
    }

    private func notify(_ central: CBCentral, _ event: CompanionBeaconFormat.Event, key: SymmetricKey, device: String) {
        guard let manager, let events else { return }
        counter &+= 1
        let data = CompanionBeaconFormat.sign(event, counter: counter, key: key, device: device)
        if !manager.updateValue(data, for: events, onSubscribedCentrals: [central]) {
            // The queue's full: try again when it has room.
            pendingNotify.append((central, data))
        }
    }
    private var pendingNotify: [(CBCentral, Data)] = []

    // MARK: CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            if peripheral.state == .unauthorized { beaconLog.notice("Bluetooth isn't allowed for Soundcheck: companions can't be woken") }
            return
        }
        let info = CBMutableCharacteristic(type: CBUUID(string: CompanionBeaconFormat.info), properties: [.read],
                                           value: UUID(uuidString: macID)?.data,
                                           permissions: [.readable])
        let events = CBMutableCharacteristic(type: CBUUID(string: CompanionBeaconFormat.events), properties: [.notify],
                                             value: nil, permissions: [.readable])
        let replies = CBMutableCharacteristic(type: CBUUID(string: CompanionBeaconFormat.replies),
                                              properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeable])
        let service = CBMutableService(type: CBUUID(string: CompanionBeaconFormat.service), primary: true)
        service.characteristics = [info, events, replies]
        self.events = events
        peripheral.removeAllServices()
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { beaconLog.error("Bluetooth service: \(error.localizedDescription, privacy: .public)"); return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: CompanionBeaconFormat.service)],
                                     CBAdvertisementDataLocalNameKey: "Soundcheck"])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        subscribed.insert(central.identifier)
        peripheral.setDesiredConnectionLatency(.low, for: central)
        flushWaiting(for: central)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribed.remove(central.identifier)
        centrals[central.identifier] = nil
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard let events else { return }
        while let (central, data) = pendingNotify.first {
            guard peripheral.updateValue(data, for: events, onSubscribedCentrals: [central]) else { return }
            pendingNotify.removeFirst()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard let value = request.value else { continue }
            receive(value, from: request.central)
        }
        if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
    }

    private func receive(_ value: Data, from central: CBCentral) {
        if let hello = CompanionBeaconFormat.readHello(value) {
            let device = hello.device.uuidString, pairing = hello.pairing.uuidString
            guard let key = keys?.key(pairing),
                  CompanionBeaconFormat.signature(hello.signed, key: key, device: device) == hello.signature,
                  hello.counter > (lastHello[device] ?? 0) || hello.counter < 16 else { return }
            lastHello[device] = hello.counter
            centrals[central.identifier] = (central, device, pairing)
            flushWaiting(for: central)
            return
        }
        guard let entry = centrals[central.identifier],
              let key = keys?.key(entry.pairing),
              let message = CompanionBeaconFormat.read(value, key: key, device: entry.device) else { return }
        if message.event == .callState {
            let device = entry.device, state = message.value
            DispatchQueue.main.async { MainActor.assumeIsolated { CompanionHub.shared.beaconCallState(device, value: state) } }
        }
    }

    private func flushWaiting(for central: CBCentral) {
        guard subscribed.contains(central.identifier), let entry = centrals[central.identifier],
              let waiting = waiting.removeValue(forKey: entry.device), waiting.until > Date(),
              let key = keys?.key(entry.pairing) else { return }
        notify(central, waiting.event, key: key, device: entry.device)
    }
}
