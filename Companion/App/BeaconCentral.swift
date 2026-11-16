import CoreBluetooth
import UIKit

/// Keeps a Bluetooth connection to each paired Mac's Soundcheck, so it can wake this app while
/// it's in the background: iOS keeps the connection for the app (and even relaunches it for it)
/// and gives it a few seconds whenever the Mac sends an event. Soundcheck uses that to say it
/// was picked as a speaker or microphone, or to ask whether a phone call is on (the answer goes
/// straight back over Bluetooth).
final class BeaconCentral: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    static let shared = BeaconCentral()

    private let queue = DispatchQueue(label: "com.mylesdean.Soundcheck.Companion.beacon")
    private var manager: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    /// Which Mac each one is, and its replies characteristic.
    private var macs: [UUID: String] = [:]
    private var replies: [UUID: CBCharacteristic] = [:]
    private var counter = UInt32(Date().timeIntervalSince1970) & 0x3FFF_FFFF
    private var lastEvent: [String: UInt32] = [:]
    private let service = CBUUID(string: CompanionBeaconFormat.service)

    /// Starts (once something's paired: iOS asks for Bluetooth then).
    func start() {
        queue.async { [self] in
            guard manager == nil, !PairingStore.all.isEmpty else { return }
            manager = CBCentralManager(delegate: self, queue: queue, options: [
                CBCentralManagerOptionRestoreIdentifierKey: "SoundcheckBeacon",
                CBCentralManagerOptionShowPowerAlertKey: false,
            ])
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManager(_ central: CBCentralManager, willRestoreState state: [String: Any]) {
        for peripheral in state[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? [] {
            peripheral.delegate = self
            peripherals[peripheral.identifier] = peripheral
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        // Ones known from before: connect (iOS waits for them for as long as it takes).
        for peripheral in peripherals.values where peripheral.state != .connected { central.connect(peripheral) }
        for peripheral in central.retrieveConnectedPeripherals(withServices: [service]) where peripherals[peripheral.identifier] == nil {
            peripheral.delegate = self
            peripherals[peripheral.identifier] = peripheral
            central.connect(peripheral)
        }
        central.scanForPeripherals(withServices: [service], options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripherals[peripheral.identifier] == nil else { return }
        peripheral.delegate = self
        peripherals[peripheral.identifier] = peripheral
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([service])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        replies[peripheral.identifier] = nil
        // Not ours (no pairing): let it go. Ours: wait for it to come back.
        if macs[peripheral.identifier] != nil { central.connect(peripheral) } else { peripherals[peripheral.identifier] = nil }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        peripherals[peripheral.identifier] = nil
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == self.service }) else { return }
        peripheral.discoverCharacteristics([CBUUID(string: CompanionBeaconFormat.info), CBUUID(string: CompanionBeaconFormat.events),
                                            CBUUID(string: CompanionBeaconFormat.replies)], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid.uuidString {
            case CompanionBeaconFormat.info: peripheral.readValue(for: characteristic)
            case CompanionBeaconFormat.replies: replies[peripheral.identifier] = characteristic
            default: break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        if characteristic.uuid.uuidString == CompanionBeaconFormat.info {
            guard let mac = UUID(data: value)?.uuidString, let pairing = PairingStore.pairing(for: mac) else {
                // A Mac this device isn't paired with.
                macs[peripheral.identifier] = nil
                manager?.cancelPeripheralConnection(peripheral)
                return
            }
            macs[peripheral.identifier] = mac
            sayHello(peripheral, pairing)
            if let events = characteristic.service?.characteristics?.first(where: { $0.uuid.uuidString == CompanionBeaconFormat.events }) {
                peripheral.setNotifyValue(true, for: events)
            }
            return
        }
        guard characteristic.uuid.uuidString == CompanionBeaconFormat.events, let mac = macs[peripheral.identifier],
              let pairing = PairingStore.pairing(for: mac),
              let event = CompanionBeaconFormat.read(value, key: pairing.symmetricKey, device: PairingStore.deviceID),
              event.counter != lastEvent[mac] else { return }
        lastEvent[mac] = event.counter
        handle(event.event, mac: mac, peripheral: peripheral)
    }

    private func sayHello(_ peripheral: CBPeripheral, _ pairing: PairingStore.Pairing) {
        guard let replies = replies[peripheral.identifier], let pairingID = UUID(uuidString: pairing.pairing),
              let device = UUID(uuidString: PairingStore.deviceID) else { return }
        counter &+= 1
        peripheral.writeValue(CompanionBeaconFormat.hello(pairing: pairingID, device: device, counter: counter, key: pairing.symmetricKey),
                              for: replies, type: .withResponse)
    }

    // MARK: Events

    private func handle(_ event: CompanionBeaconFormat.Event, mac: String, peripheral: CBPeripheral) {
        switch event {
        case .askCall:
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let now = CallWatcher.shared.current
                    BeaconCentral.shared.sendCallState(active: now.active, ringing: now.ringing, to: mac)
                }
            }
        case .speaker, .microphone, .connect:
            // Connect over Wi-Fi (the Mac then asks for what it wants), with the few seconds iOS gives.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let task = UIApplication.shared.beginBackgroundTask(withName: "Soundcheck") {}
                    MacLink.shared.activate()
                    MacLink.shared.whenConnected(timeout: 20) { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            if UIApplication.shared.applicationState != .active && !SpeakerPlayer.shared.isPlaying && !MicStreamer.shared.isRunning {
                                MacLink.shared.deactivate()
                            }
                            UIApplication.shared.endBackgroundTask(task)
                        }
                    }
                }
            }
        default:
            break
        }
    }

    /// A call started or ended: told to every paired Mac nearby (for ones not on Wi-Fi with us).
    @MainActor func reportCall() {
        let now = CallWatcher.shared.current
        queue.async { [self] in
            for mac in Set(macs.values) { sendCallState(active: now.active, ringing: now.ringing, to: mac) }
        }
    }

    nonisolated func sendCallState(active: Bool, ringing: Bool, to mac: String) {
        queue.async { [self] in
            guard let pairing = PairingStore.pairing(for: mac),
                  let entry = macs.first(where: { $0.value == mac }), let peripheral = peripherals[entry.key],
                  let replies = replies[entry.key] else { return }
            counter &+= 1
            let data = CompanionBeaconFormat.sign(.callState, value: active ? 1 : (ringing ? 2 : 0), counter: counter,
                                                  key: pairing.symmetricKey, device: PairingStore.deviceID)
            peripheral.writeValue(data, for: replies, type: .withResponse)
        }
    }
}
