import AppKit
import AudioToolbox
import AVFoundation
import CoreAudioKit
import Foundation
import Observation
import Synchronization
import os

private let effectsLog = Logger(subsystem: "com.mylesdean.Soundcheck", category: "effects")

// Effects (FX): each app and each microphone can have a few, one after the other, after its EQ:
// Soundcheck's own (Apple's audio effects, with plain controls), or any Audio Unit effect
// installed on the Mac. Apple's run inside Soundcheck; everyone else's run in a process of their
// own, so one that crashes only goes quiet, and Soundcheck never loads anyone else's code.

// MARK: The audio threads' side

/// One app's or microphone's effects, for the audio threads: the effects' render blocks in order,
/// which are on, and the buffers the sound goes back and forth between. `process` doesn't
/// allocate or wait; while the main thread changes the chain (or sets it up for another sample
/// rate), the sound passes through untouched.
final class EffectControl: @unchecked Sendable {
    static let maxEffects = 4
    /// The most frames an effect is handed at once (longer buffers go through in pieces).
    static let chunk = 1024

    // Changed only while paused (main thread); read by the audio thread holding the lock.
    fileprivate var count = 0
    fileprivate let blocks: UnsafeMutablePointer<AURenderBlock?>
    /// 2, or 1 for an effect that only takes mono (it gets both sides mixed, and fills both).
    fileprivate let channels: UnsafeMutablePointer<Int>
    fileprivate var sampleRate: Double = 0
    /// Each effect on (1) or off (0); changed any time.
    fileprivate let on: UnsafeMutablePointer<Int32>

    private let lock = Atomic<Int32>(0)
    private let paused = Atomic<Bool>(false)
    /// Two stereo pairs (left, then right, `chunk` frames each), passed back and forth.
    private let buffers: UnsafeMutablePointer<Float>
    private let input: UnsafeMutableAudioBufferListPointer
    private let output: UnsafeMutableAudioBufferListPointer
    private var pullSource: UnsafeMutablePointer<AudioBufferList>
    private var sampleTime: Double = 0
    private var pull: AURenderPullInputBlock?
    /// Told (on the main thread) the sample rate of a stream that's starting with these effects.
    fileprivate var onSampleRate: ((Double) -> Void)?

    init() {
        blocks = .allocate(capacity: Self.maxEffects)
        blocks.initialize(repeating: nil, count: Self.maxEffects)
        channels = .allocate(capacity: Self.maxEffects)
        channels.initialize(repeating: 2, count: Self.maxEffects)
        on = .allocate(capacity: Self.maxEffects)
        on.initialize(repeating: 0, count: Self.maxEffects)
        buffers = .allocate(capacity: 4 * Self.chunk)
        buffers.initialize(repeating: 0, count: 4 * Self.chunk)
        input = AudioBufferList.allocate(maximumBuffers: 2)
        output = AudioBufferList.allocate(maximumBuffers: 2)
        pullSource = input.unsafeMutablePointer
        // An effect asks for its input: what came out of the one before it.
        pull = { [unowned(unsafe) self] _, _, frameCount, _, inputData in
            let source = UnsafeMutableAudioBufferListPointer(self.pullSource)
            let target = UnsafeMutableAudioBufferListPointer(inputData)
            let bytes = UInt32(Int(frameCount) * MemoryLayout<Float>.size)
            for index in 0..<min(source.count, target.count) {
                guard let from = source[index].mData else { continue }
                if let to = target[index].mData {
                    if to != from { memcpy(to, from, Int(bytes)) }
                } else {
                    target[index].mData = from
                }
                target[index].mDataByteSize = bytes
            }
            return noErr
        }
    }

    deinit {
        blocks.deinitialize(count: Self.maxEffects)
        blocks.deallocate()
        channels.deallocate()
        on.deallocate()
        buffers.deallocate()
        free(input.unsafeMutablePointer)
        free(output.unsafeMutablePointer)
    }

    /// A stream with these effects is starting (any thread): they're set up for its sample rate.
    func prepare(sampleRate: Double) {
        guard let report = onSampleRate else { return }
        DispatchQueue.main.async { report(sampleRate) }
    }

    /// Audio thread: `samples` (interleaved stereo, at `rate`) through the effects that are on,
    /// in place.
    func process(_ samples: UnsafeMutablePointer<Float>, frames: Int, sampleRate rate: Double) {
        guard frames > 0, lock.compareExchange(expected: 0, desired: 1, ordering: .sequentiallyConsistent).exchanged else { return }
        defer { lock.store(0, ordering: .releasing) }
        guard !paused.load(ordering: .sequentiallyConsistent), count > 0, abs(sampleRate - rate) < 0.5 else { return }
        var anyOn = false
        for index in 0..<count where on[index] != 0 && blocks[index] != nil { anyOn = true }
        guard anyOn, let pull else { return }

        var offset = 0
        while offset < frames {
            let length = min(frames - offset, Self.chunk)
            let block = samples + offset * 2
            var current = 0
            let first = pair(0)
            for frame in 0..<length {
                first.left[frame] = block[frame * 2]
                first.right[frame] = block[frame * 2 + 1]
            }
            for index in 0..<count where on[index] != 0 {
                guard let render = blocks[index] else { continue }
                let from = pair(current), to = pair(1 - current)
                let mono = channels[index] == 1
                if mono {
                    for frame in 0..<length { from.left[frame] = (from.left[frame] + from.right[frame]) * 0.5 }
                }
                fill(input, from, mono: mono, frames: length)
                fill(output, to, mono: mono, frames: length)
                pullSource = input.unsafeMutablePointer
                var flags = AudioUnitRenderActionFlags()
                var stamp = AudioTimeStamp()
                stamp.mSampleTime = sampleTime
                stamp.mFlags = .sampleTimeValid
                let status = render(&flags, &stamp, AUAudioFrameCount(length), 0, output.unsafeMutablePointer, pull)
                guard status == noErr else {
                    // It couldn't: the sound goes on without it.
                    if mono { memcpy(from.right, from.left, length * MemoryLayout<Float>.size) }
                    continue
                }
                // An effect may hand back buffers of its own instead of filling ours.
                if let rendered = output[0].mData?.assumingMemoryBound(to: Float.self), rendered != to.left {
                    memcpy(to.left, rendered, length * MemoryLayout<Float>.size)
                }
                if mono {
                    memcpy(to.right, to.left, length * MemoryLayout<Float>.size)
                } else if let rendered = output[1].mData?.assumingMemoryBound(to: Float.self), rendered != to.right {
                    memcpy(to.right, rendered, length * MemoryLayout<Float>.size)
                }
                current = 1 - current
            }
            let last = pair(current)
            for frame in 0..<length {
                let left = last.left[frame], right = last.right[frame]
                block[frame * 2] = left.isFinite ? left : 0
                block[frame * 2 + 1] = right.isFinite ? right : 0
            }
            sampleTime += Double(length)
            offset += length
        }
    }

    private func pair(_ index: Int) -> (left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let left = buffers + index * 2 * Self.chunk
        return (left, left + Self.chunk)
    }

    private func fill(_ list: UnsafeMutableAudioBufferListPointer, _ pair: (left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>),
                      mono: Bool, frames: Int) {
        let bytes = UInt32(frames * MemoryLayout<Float>.size)
        list.count = mono ? 1 : 2
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: pair.left)
        if !mono { list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: pair.right) }
    }

    /// Main thread: the audio thread stops using the chain (once it's done with the piece it's on).
    fileprivate func pause() {
        paused.store(true, ordering: .sequentiallyConsistent)
        var waited = 0
        while lock.load(ordering: .sequentiallyConsistent) != 0 && waited < 10_000 {
            usleep(50)
            waited += 1
        }
    }

    fileprivate func resume() {
        paused.store(false, ordering: .sequentiallyConsistent)
    }
}

// MARK: What can go in a chain

/// Which Audio Unit an effect is (kept with each app's and microphone's effects).
struct EffectKind: Codable, Hashable, Sendable {
    var type: UInt32
    var subType: UInt32
    var manufacturer: UInt32

    init(type: UInt32, subType: UInt32, manufacturer: UInt32) {
        self.type = type
        self.subType = subType
        self.manufacturer = manufacturer
    }

    init(_ description: AudioComponentDescription) {
        self.init(type: description.componentType, subType: description.componentSubType, manufacturer: description.componentManufacturer)
    }

    init?(id: String) {
        guard id.count == 24, let type = UInt32(id.prefix(8), radix: 16),
              let subType = UInt32(id.dropFirst(8).prefix(8), radix: 16),
              let manufacturer = UInt32(id.suffix(8), radix: 16) else { return nil }
        self.init(type: type, subType: subType, manufacturer: manufacturer)
    }

    var id: String { String(format: "%08x%08x%08x", type, subType, manufacturer) }
    var isApple: Bool { manufacturer == kAudioUnitManufacturer_Apple }
    var description: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subType, componentManufacturer: manufacturer,
                                  componentFlags: 0, componentFlagsMask: 0)
    }

    static func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
}

/// One of Soundcheck's own effects: one of Apple's, with a name that says what it does and only
/// the controls that matter (its full set is in its window).
struct BuiltInEffect: Identifiable, Sendable {
    struct Control: Sendable {
        let address: AUParameterAddress
        let name: String
        let style: EffectValueStyle
        var range: ClosedRange<AUValue>?
        var step: AUValue?
    }

    let id: String
    let name: String
    let symbol: String
    let subType: String
    let help: String
    let controls: [Control]
    /// Where it starts (where Apple's own defaults suit a studio more than a Mac).
    var start: [AUParameterAddress: AUValue] = [:]
    /// Controls a preset doesn't change (Reverb's amount stays where you put it as you try rooms).
    var keptByPresets: [AUParameterAddress] = []

    var kind: EffectKind {
        EffectKind(type: kAudioUnitType_Effect, subType: EffectKind.code(subType), manufacturer: kAudioUnitManufacturer_Apple)
    }

    static func named(_ id: String?) -> BuiltInEffect? { all.first { $0.id == id } }

    static let all: [BuiltInEffect] = [
        BuiltInEffect(id: "reverb", name: "Reverb", symbol: "building.columns", subType: "mrev",
                      help: "A room, hall or plate around the sound",
                      controls: [.init(address: 0, name: "Amount", style: .percent),
                                 .init(address: 1, name: "Size", style: .percent)],
                      start: [0: 30], keptByPresets: [0]),
        BuiltInEffect(id: "echo", name: "Echo", symbol: "repeat", subType: "dely",
                      help: "Repeats, fading away",
                      controls: [.init(address: 0, name: "Amount", style: .percent, range: 0...100),
                                 .init(address: 1, name: "Time", style: .seconds, range: 0.02...1.5),
                                 .init(address: 2, name: "Repeats", style: .percent, range: 0...90)],
                      start: [0: 25, 1: 0.3, 2: 30]),
        BuiltInEffect(id: "compressor", name: "Compressor", symbol: "arrow.down.right.and.arrow.up.left", subType: "dcmp",
                      help: "Evens out loud and quiet",
                      controls: [.init(address: 0, name: "Threshold", style: .decibels, range: -60...0),
                                 .init(address: 1, name: "Headroom", style: .decibels, range: 0.5...30),
                                 .init(address: 6, name: "Volume", style: .decibels, range: -20...20)],
                      start: [0: -24, 1: 6, 6: 4]),
        BuiltInEffect(id: "limiter", name: "Limiter", symbol: "chart.line.flattrend.xyaxis", subType: "lmtr",
                      help: "Louder, without going past full",
                      controls: [.init(address: 2, name: "Boost", style: .decibels, range: 0...20),
                                 .init(address: 1, name: "Release", style: .seconds)]),
        BuiltInEffect(id: "pitch", name: "Pitch", symbol: "tuningfork", subType: "nutp",
                      help: "Higher or lower, at the same speed",
                      controls: [.init(address: 1, name: "Pitch", style: .pitch, range: -1200...1200, step: 100)]),
        BuiltInEffect(id: "distortion", name: "Distortion", symbol: "bolt", subType: "dist",
                      help: "Radio, phone, broken speaker and more",
                      controls: [.init(address: 15, name: "Amount", style: .percent)],
                      keptByPresets: [15]),
        BuiltInEffect(id: "voice", name: "Voice Isolation", symbol: "person.wave.2", subType: "vois",
                      help: "Just the voice, without what's around it",
                      controls: [.init(address: 0, name: "Amount", style: .percent, range: 0...100)],
                      start: [0: 100]),
    ]
}

/// Something to add: one of Soundcheck's own, or a plug-in.
struct EffectChoice: Identifiable, Hashable {
    let kind: EffectKind
    let name: String
    /// Who makes it ("" for Soundcheck's own).
    let maker: String
    let builtIn: String?
    let symbol: String
    var id: String { kind.id }
}

/// One effect in a chain, as it's kept.
struct EffectSlot: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: EffectKind
    var name: String
    var maker: String
    var builtIn: String?
    var isOn = true
    /// The preset last picked, shown on its menu.
    var preset: String?
    /// Everything about how it's set (the effect's full state, as a property list).
    var settings: Data?
}

/// One of an effect's controls, as the panel and the companion show it.
struct EffectControlInfo: Identifiable {
    let address: AUParameterAddress
    let name: String
    let style: EffectValueStyle
    let range: ClosedRange<AUValue>
    let step: AUValue?
    let choices: [String]?
    let unit: String?
    let value: AUValue
    var id: AUParameterAddress { address }

    func format(_ value: AUValue) -> String { style.format(value, choices: choices, unit: unit) }
}

// MARK: A chain

/// One app's or microphone's effects: what's kept about each, the effects themselves (loaded
/// when Soundcheck starts or one's added), and the audio threads' side.
@MainActor
@Observable
final class EffectRack {
    let key: String
    private(set) var slots: [EffectSlot]
    /// The effects, by slot (one that's loading or failed has none).
    @ObservationIgnored private(set) var units: [UUID: AUAudioUnit] = [:]
    private(set) var loading: Set<UUID> = []
    /// What went wrong with an effect, shown in its row.
    private(set) var problems: [UUID: String] = [:]
    /// Goes up whenever an effect's controls move (here, in its window, or from a companion).
    private(set) var revision = 0
    @ObservationIgnored let control = EffectControl()
    @ObservationIgnored private var sampleRate: Double = 0
    @ObservationIgnored private var formats: [UUID: (rate: Double, channels: Int)] = [:]
    /// Where each slot is in the audio threads' chain.
    @ObservationIgnored private var positions: [UUID: Int] = [:]
    @ObservationIgnored private var observers: [UUID: AUParameterObserverToken] = [:]
    @ObservationIgnored private var fresh: Set<UUID> = []
    @ObservationIgnored private var movePending = false

    var isActive: Bool { slots.contains { $0.isOn } }
    var isFull: Bool { slots.count >= EffectControl.maxEffects }

    init(key: String, slots: [EffectSlot]) {
        self.key = key
        self.slots = slots
        control.onSampleRate = { [weak self] rate in
            MainActor.assumeIsolated { self?.use(sampleRate: rate) }
        }
        for slot in slots { load(slot) }
    }

    // MARK: Changing the chain

    func add(_ choice: EffectChoice) {
        guard !isFull else { return }
        let slot = EffectSlot(kind: choice.kind, name: choice.name, maker: choice.maker, builtIn: choice.builtIn)
        slots.append(slot)
        fresh.insert(slot.id)
        load(slot)
        changed(structure: true)
    }

    func remove(_ id: UUID) {
        slots.removeAll { $0.id == id }
        // The audio thread lets go of it before it goes.
        install()
        EffectWindows.shared.close(id)
        if let unit = units.removeValue(forKey: id) {
            if let token = observers.removeValue(forKey: id) { unit.parameterTree?.removeParameterObserver(token) }
            if unit.renderResourcesAllocated { unit.deallocateRenderResources() }
        }
        problems[id] = nil
        loading.remove(id)
        formats[id] = nil
        changed(structure: true)
    }

    func move(_ id: UUID, by offset: Int) {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + offset, 0), slots.count - 1)
        guard target != index else { return }
        slots.insert(slots.remove(at: index), at: target)
        install()
        changed(structure: false)
    }

    func setOn(_ id: UUID, _ on: Bool) {
        guard let index = slots.firstIndex(where: { $0.id == id }), slots[index].isOn != on else { return }
        slots[index].isOn = on
        if let position = positions[id] {
            if on, let unit = units[id] {
                // Nothing left over from before it was off (an old reverb tail).
                control.pause()
                unit.reset()
                control.resume()
            }
            control.on[position] = on ? 1 : 0
        }
        changed(structure: true)
    }

    /// Every effect off (Reset), giving back which were on.
    func turnOff() -> [UUID] {
        let wereOn = slots.filter(\.isOn).map(\.id)
        for id in wereOn { setOn(id, false) }
        return wereOn
    }

    func setValue(_ value: AUValue, address: AUParameterAddress, for id: UUID) {
        guard let parameter = units[id]?.parameterTree?.parameter(withAddress: address) else { return }
        parameter.value = min(max(value, parameter.minValue), parameter.maxValue)
    }

    /// The effect's own presets ("Large Hall"…), in order.
    func presets(_ id: UUID) -> [String] {
        guard let unit = units[id], let slot = slots.first(where: { $0.id == id }) else { return [] }
        return (unit.factoryPresets ?? []).map { Self.presetName($0.name, builtIn: slot.builtIn != nil) }
    }

    func choosePreset(_ index: Int, for id: UUID) {
        guard let unit = units[id], let presets = unit.factoryPresets, index >= 0, index < presets.count,
              let slotIndex = slots.firstIndex(where: { $0.id == id }) else { return }
        let kept = (BuiltInEffect.named(slots[slotIndex].builtIn)?.keptByPresets ?? []).compactMap { address in
            unit.parameterTree?.parameter(withAddress: address).map { (address, $0.value) }
        }
        control.pause()
        unit.currentPreset = presets[index]
        for (address, value) in kept { unit.parameterTree?.parameter(withAddress: address)?.value = value }
        control.resume()
        slots[slotIndex].preset = Self.presetName(presets[index].name, builtIn: slots[slotIndex].builtIn != nil)
        revision += 1
        changed(structure: false)
    }

    /// Apple's names have a category in front ("Speech- Radio Tower"): just the name.
    private static func presetName(_ name: String, builtIn: Bool) -> String {
        guard builtIn, let dash = name.range(of: "- ") ?? name.range(of: " - "), name.distance(from: name.startIndex, to: dash.lowerBound) <= 7 else { return name }
        return String(name[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// The controls to show for an effect: Soundcheck's choice for its own, or a plug-in's first
    /// several (the rest are in its window).
    func controls(_ id: UUID) -> [EffectControlInfo] {
        _ = revision
        guard let slot = slots.first(where: { $0.id == id }), let tree = units[id]?.parameterTree else { return [] }
        if let builtIn = BuiltInEffect.named(slot.builtIn) {
            return builtIn.controls.compactMap { control in
                tree.parameter(withAddress: control.address).map {
                    Self.info($0, name: control.name, style: control.style, range: control.range, step: control.step)
                }
            }
        }
        return tree.allParameters
            .filter { $0.flags.contains(.flag_IsWritable) && $0.maxValue > $0.minValue }
            .prefix(16)
            .map { Self.info($0) }
    }

    private static func info(_ parameter: AUParameter, name: String? = nil, style: EffectValueStyle? = nil,
                             range: ClosedRange<AUValue>? = nil, step: AUValue? = nil) -> EffectControlInfo {
        let choices = parameter.valueStrings
        let style = style ?? Self.style(parameter, hasChoices: choices?.isEmpty == false)
        var range = range ?? (parameter.minValue...max(parameter.maxValue, parameter.minValue + 0.0001))
        if style == .toggle { range = 0...1 }
        return EffectControlInfo(address: parameter.address, name: name ?? parameter.displayName, style: style, range: range,
                                 step: step ?? ((style == .choice || style == .toggle) ? 1 : nil),
                                 choices: style == .choice ? choices : nil, unit: parameter.unitName, value: parameter.value)
    }

    private static func style(_ parameter: AUParameter, hasChoices: Bool) -> EffectValueStyle {
        switch parameter.unit {
        case .indexed: return hasChoices ? .choice : .plain
        case .boolean: return .toggle
        case .percent, .equalPowerCrossfade: return .percent
        case .seconds: return .seconds
        case .milliseconds: return .milliseconds
        case .hertz: return .hertz
        case .cents, .absoluteCents: return .cents
        case .relativeSemiTones: return .semitones
        case .decibels: return .decibels
        case .octaves: return .octaves
        case .ratio: return .ratio
        default: return hasChoices ? .choice : .plain
        }
    }

    /// Whether it has more than the panel shows (it always has a window: its own, or a plain one).
    func hasWindow(_ id: UUID) -> Bool { units[id] != nil }

    // MARK: Loading and setting up

    private func load(_ slot: EffectSlot) {
        loading.insert(slot.id)
        let options: AudioComponentInstantiationOptions = slot.kind.isApple ? [] : .loadOutOfProcess
        AUAudioUnit.instantiate(with: slot.kind.description, options: options) { [weak self] unit, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.loaded(slot.id, unit, error) }
            }
        }
    }

    private func loaded(_ id: UUID, _ unit: AUAudioUnit?, _ error: Error?) {
        loading.remove(id)
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return } // removed while it loaded
        guard let unit else {
            problems[id] = "\(slots[index].name) couldn't open"
            effectsLog.error("Couldn't open \(self.slots[index].name, privacy: .public): \(error?.localizedDescription ?? "", privacy: .public)")
            return
        }
        unit.maximumFramesToRender = AUAudioFrameCount(EffectControl.chunk)
        if let data = slots[index].settings,
           let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            unit.fullState = state
        } else if fresh.remove(id) != nil, let builtIn = BuiltInEffect.named(slots[index].builtIn) {
            for (address, value) in builtIn.start { unit.parameterTree?.parameter(withAddress: address)?.value = value }
        }
        units[id] = unit
        if let tree = unit.parameterTree {
            observers[id] = tree.token(byAddingParameterObserver: { [weak self] _, _ in
                // From whatever moved it (often the effect's window), on its thread.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.controlsMoved() } }
            })
        }
        install()
        revision += 1
        changed(structure: false)
    }

    /// A stream with these effects started at `rate`.
    private func use(sampleRate rate: Double) {
        guard rate > 0, abs(rate - sampleRate) > 0.5 else { return }
        sampleRate = rate
        install()
    }

    /// Hands the audio threads the chain as it is now, each effect set up for the stream.
    private func install() {
        control.pause()
        defer { control.resume() }
        var count = 0
        positions = [:]
        if sampleRate > 0 {
            for slot in slots {
                guard count < EffectControl.maxEffects, let unit = units[slot.id] else { continue }
                if formats[slot.id]?.rate != sampleRate || !unit.renderResourcesAllocated {
                    guard let channels = allocate(unit, slot: slot) else { continue }
                    formats[slot.id] = (sampleRate, channels)
                }
                control.blocks[count] = unit.renderBlock
                control.channels[count] = formats[slot.id]?.channels ?? 2
                control.on[count] = slot.isOn ? 1 : 0
                positions[slot.id] = count
                count += 1
            }
        }
        for index in count..<EffectControl.maxEffects {
            control.blocks[index] = nil
            control.on[index] = 0
        }
        control.count = count
        control.sampleRate = sampleRate
    }

    /// Stereo at the stream's rate, or mono if that's all it takes.
    private func allocate(_ unit: AUAudioUnit, slot: EffectSlot) -> Int? {
        if unit.renderResourcesAllocated { unit.deallocateRenderResources() }
        guard unit.outputBusses.count > 0 else {
            problems[slot.id] = "\(slot.name) isn't an effect"
            return nil
        }
        for channels: AVAudioChannelCount in [2, 1] {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else { continue }
            do {
                // Busses start off (an effect takes nothing in until its host says so).
                if unit.inputBusses.count > 0 {
                    try unit.inputBusses[0].setFormat(format)
                    unit.inputBusses[0].isEnabled = true
                }
                try unit.outputBusses[0].setFormat(format)
                unit.outputBusses[0].isEnabled = true
                try unit.allocateRenderResources()
                problems[slot.id] = nil
                return Int(channels)
            } catch {
                continue
            }
        }
        problems[slot.id] = "\(slot.name) doesn't work at \(Int(sampleRate)) Hz"
        return nil
    }

    private func controlsMoved() {
        guard !movePending else { return }
        movePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.movePending = false
                self.revision += 1
                Effects.shared.needsSave()
            }
        }
    }

    private func changed(structure: Bool) {
        Effects.shared.rackChanged(self, structure: structure)
    }

    /// Each effect's state, into what's kept (before saving).
    func captureSettings() {
        for index in slots.indices {
            guard let state = units[slots[index].id]?.fullState,
                  let data = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0) else { continue }
            slots[index].settings = data
        }
    }

    /// Back on (undoing Reset).
    func turnOn(_ ids: [UUID]) {
        for id in ids { setOn(id, true) }
    }
}

// MARK: All of them

/// Every app's and microphone's effects, what can be added, and keeping them between launches
/// (in Application Support, as effects' settings can be large).
@MainActor
@Observable
final class Effects {
    static let shared = Effects()

    /// What can be added: Soundcheck's own, then plug-ins by maker.
    private(set) var choices: [EffectChoice] = []
    @ObservationIgnored private var racks: [String: EffectRack] = [:]
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var loaded = false
    /// Goes up as chains change (for whoever lists every chain).
    private(set) var revision = 0

    private init() {}

    static func key(_ target: AudioEngine.ShapeTarget) -> String? {
        switch target {
        case .app(let id): "app:" + id
        case .mic(let uid): "mic:" + uid
        case .speaker: nil
        }
    }

    /// The chain for an app or microphone (made the first time it's asked for).
    func rack(_ target: AudioEngine.ShapeTarget) -> EffectRack? {
        guard let key = Self.key(target) else { return nil }
        if let rack = racks[key] { return rack }
        let rack = EffectRack(key: key, slots: [])
        racks[key] = rack
        return rack
    }

    func existingRack(_ target: AudioEngine.ShapeTarget) -> EffectRack? {
        Self.key(target).flatMap { racks[$0] }
    }

    /// The audio threads' side, for a tap or mixer to run (every app and microphone has one).
    func control(for target: AudioEngine.ShapeTarget) -> EffectControl? { rack(target)?.control }

    /// It has an effect that's on.
    func isActive(_ target: AudioEngine.ShapeTarget) -> Bool { existingRack(target)?.isActive ?? false }

    // MARK: Starting

    /// Before the taps are made, so apps with effects get theirs.
    func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? PropertyListDecoder().decode([String: [EffectSlot]].self, from: data) {
            for (key, slots) in saved where !slots.isEmpty { racks[key] = EffectRack(key: key, slots: slots) }
        }
        refreshChoices()
        NotificationCenter.default.addObserver(forName: AVAudioUnitComponentManager.registrationsChangedNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { Effects.shared.refreshChoices() }
        }
    }

    /// Soundcheck's own, then every other Audio Unit effect on the Mac (Apple's others under
    /// Apple), by maker.
    private func refreshChoices() {
        var list = BuiltInEffect.all.map {
            EffectChoice(kind: $0.kind, name: $0.name, maker: "", builtIn: $0.id, symbol: $0.symbol)
        }
        let own = Set(list.map(\.kind))
        // Not effects you'd play through: sending sound over the network, an AAC round trip.
        let skipped: Set<UInt32> = [EffectKind.code("nsnd"), EffectKind.code("raac")]
        var plugIns: [EffectChoice] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let wanted = AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0,
                                                   componentFlags: 0, componentFlagsMask: 0)
            for component in AVAudioUnitComponentManager.shared().components(matching: wanted) {
                let kind = EffectKind(component.audioComponentDescription)
                guard !own.contains(kind), !(kind.isApple && skipped.contains(kind.subType)) else { continue }
                plugIns.append(EffectChoice(kind: kind, name: Self.plainName(component.name), maker: component.manufacturerName,
                                            builtIn: nil, symbol: "puzzlepiece.extension"))
            }
        }
        plugIns.sort {
            let maker = $0.maker.localizedStandardCompare($1.maker)
            return maker == .orderedSame ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : maker == .orderedAscending
        }
        list += plugIns
        choices = list
    }

    /// "AUGraphicEQ" → "Graphic EQ" (Apple's); others keep their names.
    private static func plainName(_ name: String) -> String {
        guard name.hasPrefix("AU"), name.count > 2 else { return name }
        var result = ""
        let rest = name.dropFirst(2)
        for (index, character) in rest.enumerated() {
            let previous = index > 0 ? rest[rest.index(rest.startIndex, offsetBy: index - 1)] : nil
            if index > 0, character.isUppercase, let previous, previous.isLowercase { result.append(" ") }
            result.append(character)
        }
        return result
    }

    // MARK: Changes

    func rackChanged(_ rack: EffectRack, structure: Bool) {
        revision += 1
        if structure { AudioEngine.shared.effectsChanged() }
        needsSave()
    }

    /// Every effect off (Options › Reset), giving back which were on.
    func turnAllOff() -> [String: [UUID]] {
        var wereOn: [String: [UUID]] = [:]
        for (key, rack) in racks {
            let ids = rack.turnOff()
            if !ids.isEmpty { wereOn[key] = ids }
        }
        return wereOn
    }

    func turnOn(_ wereOn: [String: [UUID]]) {
        for (key, ids) in wereOn { racks[key]?.turnOn(ids) }
    }

    // MARK: Keeping them

    private static var file: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soundcheck", isDirectory: true)
        return folder.appendingPathComponent("Effects.plist")
    }

    func needsSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { Effects.shared.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Now (quitting, or a window with an effect's settings closing).
    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard loaded else { return }
        var saved: [String: [EffectSlot]] = [:]
        for (key, rack) in racks where !rack.slots.isEmpty {
            rack.captureSettings()
            saved[key] = rack.slots
        }
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(saved)
            try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: Self.file, options: .atomic)
        } catch {
            effectsLog.error("Couldn't save effects: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: Effects' windows

/// An effect's full set of controls, in a window of its own: the effect's own design, or a plain
/// list of its controls for one without.
@MainActor
final class EffectWindows: NSObject, NSWindowDelegate {
    static let shared = EffectWindows()
    private var windows: [UUID: NSWindow] = [:]

    func open(_ id: UUID, in rack: EffectRack, title: String) {
        if let window = windows[id] {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let unit = rack.units[id] else { return }
        unit.requestViewController { [weak self] controller in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.show(controller, unit: unit, id: id, title: title) }
            }
        }
    }

    private func show(_ own: NSViewController?, unit: AUAudioUnit, id: UUID, title: String) {
        guard windows[id] == nil else { return }
        let controller: NSViewController
        if let own {
            controller = own
        } else {
            let generic = AUGenericViewController()
            generic.auAudioUnit = unit
            controller = generic
        }
        var size = controller.preferredContentSize
        if size.width < 10 || size.height < 10 { size = controller.view.fittingSize }
        if size.width < 10 || size.height < 10 { size = controller.view.frame.size }
        size = NSSize(width: max(size.width, 320), height: max(size.height, 160))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(size)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        window.center()
        windows[id] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ id: UUID) {
        windows.removeValue(forKey: id)?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let raw = window.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        windows[id] = nil
        // What was changed there is kept.
        Effects.shared.saveNow()
    }
}
