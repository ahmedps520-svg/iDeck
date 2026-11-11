import Combine
import CoreHaptics
import Foundation
import GameController

/// Forwards physical controllers (Xbox, PlayStation, MFi, Switch) to the
/// guest as virtual Xbox 360 pads, and plays guest rumble on them.
final class ControllerBridge: ObservableObject {
    struct Pad: Identifiable, Equatable {
        let id: ObjectIdentifier
        var slot: UInt8
        var name: String
        var kind: String
        var battery: Float?
        var hasHaptics: Bool
    }

    @Published private(set) var pads: [Pad] = []
    /// Live state per slot for the Controls test screen.
    @Published private(set) var liveState: [UInt8: ideck_pad_state] = [:]
    var hapticsEnabled = true

    private var channel: InputChannel?
    private var slots: [ObjectIdentifier: UInt8] = [:]
    private var controllers: [UInt8: GCController] = [:]
    private var engines: [UInt8: CHHapticEngine] = [:]
    private var seq: UInt16 = 0
    private var observers: [NSObjectProtocol] = []
    private var keepalive: Timer?

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.attach(c) }
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.detach(c) }
        })
        GCController.shouldMonitorBackgroundEvents = false
        GCController.startWirelessControllerDiscovery {}
        GCController.controllers().forEach(attach)
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        keepalive?.invalidate()
    }

    /// Connects to the guest input channel; re-announces connected pads.
    func bind(to channel: InputChannel?) {
        self.channel = channel
        channel?.onRumble = { [weak self] r in
            DispatchQueue.main.async { self?.rumble(r) }
        }
        for (slot, c) in controllers {
            send(type: 2, slot: slot, controller: c)
            send(type: 1, slot: slot, controller: c)
        }
        keepalive?.invalidate()
        keepalive = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let ch = self.channel else { return }
            var s = ideck_pad_state()
            s.type = 5
            ch.send(s)
        }
    }

    private func kind(of c: GCController) -> (UInt8, String) {
        let cat = c.productCategory
        if c.extendedGamepad is GCDualSenseGamepad || c.extendedGamepad is GCDualShockGamepad { return (2, "PlayStation") }
        if c.extendedGamepad is GCXboxGamepad { return (1, "Xbox") }
        if cat.localizedCaseInsensitiveContains("switch") || cat.localizedCaseInsensitiveContains("joy-con") {
            return (3, "Nintendo")
        }
        return (0, cat.isEmpty ? "Controller" : cat)
    }

    private func attach(_ c: GCController) {
        guard c.extendedGamepad != nil else { return }
        let key = ObjectIdentifier(c)
        guard slots[key] == nil else { return }
        guard let slot = (0..<4).map(UInt8.init).first(where: { s in !slots.values.contains(s) }) else { return }
        slots[key] = slot
        controllers[slot] = c
        c.playerIndex = GCControllerPlayerIndex(rawValue: Int(slot)) ?? .indexUnset
        c.extendedGamepad?.valueChangedHandler = { [weak self, weak c] _, _ in
            guard let self, let c else { return }
            self.send(type: 1, slot: slot, controller: c)
        }
        let (_, kindName) = kind(of: c)
        pads.append(Pad(id: key, slot: slot, name: c.vendorName ?? kindName, kind: kindName,
                        battery: c.battery?.batteryLevel, hasHaptics: c.haptics != nil))
        send(type: 2, slot: slot, controller: c)
    }

    private func detach(_ c: GCController) {
        let key = ObjectIdentifier(c)
        guard let slot = slots.removeValue(forKey: key) else { return }
        controllers.removeValue(forKey: slot)
        engines.removeValue(forKey: slot)?.stop(completionHandler: nil)
        pads.removeAll { $0.id == key }
        liveState.removeValue(forKey: slot)
        var s = ideck_pad_state()
        s.type = 3
        s.pad = slot
        channel?.send(s)
    }

    private func state(of c: GCController, slot: UInt8, type: UInt8) -> ideck_pad_state {
        var s = ideck_pad_state()
        s.type = type
        s.pad = slot
        s.kind = kind(of: c).0
        seq &+= 1
        s.seq = seq
        guard let g = c.extendedGamepad else { return s }
        var b: UInt32 = 0
        func set(_ pressed: Bool, _ bit: UInt32) { if pressed { b |= bit } }
        set(g.buttonA.isPressed, 1 << 0)
        set(g.buttonB.isPressed, 1 << 1)
        set(g.buttonX.isPressed, 1 << 2)
        set(g.buttonY.isPressed, 1 << 3)
        set(g.leftShoulder.isPressed, 1 << 4)
        set(g.rightShoulder.isPressed, 1 << 5)
        set(g.buttonOptions?.isPressed ?? false, 1 << 6)
        set(g.buttonMenu.isPressed, 1 << 7)
        set(g.buttonHome?.isPressed ?? false, 1 << 8)
        set(g.leftThumbstickButton?.isPressed ?? false, 1 << 9)
        set(g.rightThumbstickButton?.isPressed ?? false, 1 << 10)
        set(g.dpad.up.isPressed, 1 << 11)
        set(g.dpad.down.isPressed, 1 << 12)
        set(g.dpad.left.isPressed, 1 << 13)
        set(g.dpad.right.isPressed, 1 << 14)
        if let ds = g as? GCDualSenseGamepad { set(ds.touchpadButton.isPressed, 1 << 15) }
        s.buttons = b
        s.lx = g.leftThumbstick.xAxis.value
        s.ly = g.leftThumbstick.yAxis.value
        s.rx = g.rightThumbstick.xAxis.value
        s.ry = g.rightThumbstick.yAxis.value
        s.lt = g.leftTrigger.value
        s.rt = g.rightTrigger.value
        return s
    }

    private func send(type: UInt8, slot: UInt8, controller c: GCController) {
        let s = state(of: c, slot: slot, type: type)
        channel?.send(s)
        if type == 1 {
            DispatchQueue.main.async { self.liveState[slot] = s }
        }
    }

    // MARK: Rumble

    private func rumble(_ r: ideck_rumble) {
        guard hapticsEnabled, let c = controllers[r.pad], let haptics = c.haptics else { return }
        let engine: CHHapticEngine
        if let e = engines[r.pad] {
            engine = e
        } else {
            guard let e = haptics.createEngine(withLocality: .default) else { return }
            try? e.start()
            engines[r.pad] = e
            engine = e
        }
        let strong = Float(r.strong) / 65535
        let weak = Float(r.weak) / 65535
        let intensity = max(strong, weak)
        guard intensity > 0.01 else {
            engine.stop(completionHandler: nil)
            engines.removeValue(forKey: r.pad)
            return
        }
        let duration = Double(max(r.duration_ms, 30)) / 1000
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            // Strong motor = low frequency rumble, weak motor = sharp buzz.
            CHHapticEventParameter(parameterID: .hapticSharpness, value: strong >= weak ? 0.2 : 0.7),
        ], relativeTime: 0, duration: duration)
        if let pattern = try? CHHapticPattern(events: [event], parameters: []),
           let player = try? engine.makePlayer(with: pattern) {
            try? player.start(atTime: CHHapticTimeImmediate)
        }
    }
}
