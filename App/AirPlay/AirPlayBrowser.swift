// AirPlay audio sender for Soundcheck.
//
// Finds AirPlay speakers: browses _airplay._tcp and _raop._tcp with NWBrowser, resolves each
// service's host and port with DNS-SD (without connecting to it) and merges the two services by
// device ID, as pyatv's scanner does (pyatv/protocols/raop/__init__.py and airplay/__init__.py):
// https://github.com/postlund/pyatv, MIT License, © Pierre Ståhl.

import Darwin
import Foundation
import Network
import Observation
import SystemConfiguration
import dnssd

@MainActor @Observable final class AirPlayBrowser {
    static let shared = AirPlayBrowser()

    /// Speakers found so far, by name. Excludes this Mac itself.
    private(set) var speakers: [AirPlaySpeaker] = []
    /// Set when browsing can't work, e.g. "Local Network access is off for this app".
    private(set) var problem: String?
    /// macOS's Local Network permission is off for Soundcheck.
    private(set) var isDenied = false

    private struct ServiceKey: Hashable {
        let name: String
        let type: String
        let domain: String
    }

    private struct Found {
        let key: ServiceKey
        let txt: [String: String]
        let interfaceIndex: UInt32
    }

    private static let types = ["_airplay._tcp", "_raop._tcp"]

    @ObservationIgnored private var browsers: [NWBrowser] = []
    @ObservationIgnored private var found: [String: [ServiceKey: Found]] = [:]
    @ObservationIgnored private var addresses: [ServiceKey: (host: String, port: UInt16)] = [:]
    @ObservationIgnored private var resolvers: [ServiceKey: AirPlayResolver] = [:]
    @ObservationIgnored private var failedResolves: Set<ServiceKey> = []
    @ObservationIgnored private let localMACs: Set<String>
    @ObservationIgnored private let localHostName: String?

    init() {
        localMACs = Self.localMACAddresses()
        localHostName = (SCDynamicStoreCopyLocalHostName(nil) as String?)?.lowercased()
    }

    var isBrowsing: Bool { !browsers.isEmpty }

    func start() {
        guard browsers.isEmpty else { return }
        problem = nil
        for type in Self.types {
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: parameters)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                MainActor.assumeIsolated { self?.update(type: type, results: results) }
            }
            browser.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.browser(type: type, changedTo: state) }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
        found.removeAll()
        addresses.removeAll()
        failedResolves.removeAll()
        if !speakers.isEmpty { speakers = [] }
    }

    private func browser(type: String, changedTo state: NWBrowser.State) {
        switch state {
        case .ready:
            if problem != nil { problem = nil }
            if isDenied { isDenied = false }
        case .waiting(let error), .failed(let error):
            if case .dns(let code) = error, code == kDNSServiceErr_PolicyDenied {
                isDenied = true
                problem = "Turn on Local Network for Soundcheck to find AirPlay speakers (System Settings › Privacy & Security › Local Network)."
            } else {
                problem = "Can't browse for \(type): \(error)"
            }
            AirPlayLog.error("AirPlay browser (\(type)): \(error)")
            if case .failed = state {
                // Try again in a few seconds (e.g. after the network comes back).
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, !self.browsers.isEmpty else { return }
                        self.stop()
                        self.start()
                    }
                }
            }
        default:
            break
        }
    }

    private func update(type: String, results: Set<NWBrowser.Result>) {
        var current: [ServiceKey: Found] = [:]
        for result in results {
            guard case let .service(name, serviceType, domain, interface) = result.endpoint else { continue }
            var txt: [String: String] = [:]
            if case let .bonjour(record) = result.metadata { txt = record.dictionary }
            let key = ServiceKey(name: name, type: serviceType, domain: domain)
            current[key] = Found(key: key, txt: txt, interfaceIndex: interface.map { UInt32($0.index) } ?? 0)
        }
        let previous = found[type] ?? [:]
        found[type] = current
        for key in previous.keys where current[key] == nil {
            addresses[key] = nil
            resolvers.removeValue(forKey: key)?.cancel()
            failedResolves.remove(key)
        }
        for (key, service) in current where addresses[key] == nil && resolvers[key] == nil && !failedResolves.contains(key) {
            resolve(service)
        }
        rebuild()
    }

    private func resolve(_ service: Found) {
        let key = service.key
        let resolver = AirPlayResolver(name: key.name, type: key.type, domain: key.domain) { [weak self] result in
            guard let self else { return }
            self.resolvers[key] = nil
            if let result {
                self.addresses[key] = result
                self.failedResolves.remove(key)
            } else {
                self.failedResolves.insert(key)
                // Try again later; speakers that just woke up sometimes take a while.
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let again = self.found[key.type]?[key],
                              self.addresses[key] == nil, self.resolvers[key] == nil else { return }
                        self.failedResolves.remove(key)
                        self.resolve(again)
                    }
                }
            }
            self.rebuild()
        }
        if resolver.start() { resolvers[key] = resolver }
    }

    private func rebuild() {
        var byID: [String: (airplay: Found?, raop: Found?)] = [:]
        for service in (found["_airplay._tcp"] ?? [:]).values {
            guard let id = Self.deviceID(service.txt["deviceid"] ?? "") else { continue }
            byID[id, default: (nil, nil)].airplay = service
        }
        for service in (found["_raop._tcp"] ?? [:]).values {
            let prefix = service.key.name.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
            guard let id = Self.deviceID(prefix) else { continue }
            byID[id, default: (nil, nil)].raop = service
        }

        var list: [AirPlaySpeaker] = []
        for (id, entry) in byID where !localMACs.contains(id) {
            let raopAddress = entry.raop.flatMap { addresses[$0.key] }
            let airplayAddress = entry.airplay.flatMap { addresses[$0.key] }
            guard let address = raopAddress ?? airplayAddress, !isThisMac(address.host) else { continue }
            let raopName = entry.raop.map { service -> String in
                let parts = service.key.name.split(separator: "@", maxSplits: 1)
                return parts.count == 2 ? String(parts[1]) : service.key.name
            }
            let name = entry.airplay?.key.name ?? raopName ?? id
            let model = entry.airplay?.txt["model"] ?? entry.raop?.txt["am"] ?? entry.airplay?.txt["manufacturer"] ?? "Unknown"
            list.append(AirPlaySpeaker(
                id: id, name: name, model: model, host: address.host, port: address.port,
                raopProperties: entry.raop?.txt ?? [:], airplayProperties: entry.airplay?.txt ?? [:],
                raopServiceName: entry.raop?.key.name, airplayServiceName: entry.airplay?.key.name))
        }
        list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if list != speakers { speakers = list }
    }

    private func isThisMac(_ host: String) -> Bool {
        guard let localHostName else { return false }
        let name = host.lowercased()
        return name == localHostName + ".local." || name == localHostName + ".local"
    }

    /// "AA:BB:CC:11:22:33" from "aa:bb:cc:11:22:33" or "AABBCC112233"; other IDs pass through.
    static func deviceID(_ raw: String) -> String? {
        let hex = raw.uppercased().filter { $0 != ":" && $0 != "-" }
        guard !hex.isEmpty else { return nil }
        guard hex.count == 12, hex.allSatisfy(\.isHexDigit) else { return raw.uppercased() }
        var parts: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            parts.append(String(hex[index..<next]))
            index = next
        }
        return parts.joined(separator: ":")
    }

    /// This Mac's hardware addresses, to leave out its own AirPlay receiver.
    private static func localMACAddresses() -> Set<String> {
        var result: Set<String> = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let mac: String? = address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link in
                let length = Int(link.pointee.sdl_alen)
                guard length == 6 else { return nil }
                let offset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data)! + Int(link.pointee.sdl_nlen)
                let bytes = UnsafeRawPointer(link).advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                let octets = (0..<6).map { bytes[$0] }
                guard octets.contains(where: { $0 != 0 }) else { return nil }
                return octets.map { String(format: "%02X", $0) }.joined(separator: ":")
            }
            if let mac { result.insert(mac) }
        }
        return result
    }
}

/// Resolves one Bonjour service to host name and port with DNSServiceResolve, on the main queue.
@MainActor private final class AirPlayResolver {
    private let name: String
    private let type: String
    private let domain: String
    private let completion: ((host: String, port: UInt16)?) -> Void
    private var ref: DNSServiceRef?
    private var timeout: DispatchWorkItem?

    init(name: String, type: String, domain: String, completion: @escaping ((host: String, port: UInt16)?) -> Void) {
        self.name = name
        self.type = type
        self.domain = domain
        self.completion = completion
    }

    func start() -> Bool {
        var ref: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let error = DNSServiceResolve(&ref, 0, 0, name, type, domain, airPlayResolveReply, context)
        guard error == kDNSServiceErr_NoError, let ref else {
            AirPlayLog.error("Couldn't resolve \(name) (\(error))")
            return false
        }
        DNSServiceSetDispatchQueue(ref, .main)
        self.ref = ref
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish(nil) }
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
        return true
    }

    func finish(_ result: (host: String, port: UInt16)?) {
        guard ref != nil else { return }
        cancel()
        completion(result)
    }

    func cancel() {
        timeout?.cancel()
        timeout = nil
        if let ref { DNSServiceRefDeallocate(ref) }
        ref = nil
    }
}

private let airPlayResolveReply: DNSServiceResolveReply = { _, _, _, error, _, hostTarget, port, _, _, context in
    guard let context else { return }
    let host = hostTarget.map { String(cString: $0) }
    let resolvedPort = UInt16(bigEndian: port)
    let resolver = Unmanaged<AirPlayResolver>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated {
        if error == kDNSServiceErr_NoError, let host, !host.isEmpty {
            resolver.finish((host, resolvedPort))
        } else {
            resolver.finish(nil)
        }
    }
}
