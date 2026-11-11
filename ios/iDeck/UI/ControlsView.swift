import SwiftUI

struct ControlsView: View {
    @EnvironmentObject var controllers: ControllerBridge
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(title: "Controllers", subtitle: "Each controller appears in Linux as an Xbox 360 pad, which Steam Input and SDL support without setup.")
                if controllers.pads.isEmpty {
                    Card {
                        Text("No controller connected. Pair an Xbox, PlayStation, Switch Pro or MFi controller in \(Device.os) Settings › Bluetooth.")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                ForEach(controllers.pads) { pad in
                    Card {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Image(systemName: "gamecontroller.fill").foregroundStyle(Theme.accent)
                                Text(pad.name).font(.headline).foregroundStyle(.white)
                                Text("Player \(pad.slot + 1)").font(.caption).foregroundStyle(Theme.textSecondary)
                                Spacer()
                                if let b = pad.battery, b >= 0 { StatusPill(text: Format.percent(Double(b) * 100), color: Theme.success) }
                                if pad.hasHaptics { StatusPill(text: "Rumble", color: Theme.accent) }
                            }
                            if let s = controllers.liveState[pad.slot] { PadTester(state: s, kind: pad.kind) }
                            else { Text("Press any button to test.").font(.caption).foregroundStyle(Theme.textTertiary) }
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Button layout").font(.headline).foregroundStyle(.white)
                        mappingRow("Xbox", "A B X Y · LB RB · View/Menu · Xbox")
                        mappingRow("PlayStation", "Cross=A, Circle=B, Square=X, Triangle=Y · L1/R1 · Create/Options · PS · touchpad click")
                        mappingRow("Nintendo", "Positional: the bottom face button is A in Linux")
                        Text("Per-game remapping is done in Steam Input (Steam › Controller settings), which works with these pads.")
                            .font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                Toggle("Controller vibration", isOn: $model.settings.hapticsEnabled)
                    .onChange(of: model.settings.hapticsEnabled) { v in controllers.hapticsEnabled = v }
                    .padding(.horizontal, 4)
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Keyboard, mouse and touch").font(.headline).foregroundStyle(.white)
                        Text("• Hardware keyboards and mice work directly (Magic Keyboard, USB-C, Bluetooth).\n• Touch: tap = click, two-finger tap = right click, long-press and drag = drag, two-finger swipe = scroll.\n• For games that use mouse-look, open the in-game menu (top right) and choose Capture Mouse.")
                            .font(.callout).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(28)
        }
        .navigationTitle("Controls")
    }

    private func mappingRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.subheadline.weight(.semibold)).frame(width: 110, alignment: .leading).foregroundStyle(.white)
            Text(v).font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Live view of a controller's state as sent to Linux.
struct PadTester: View {
    var state: ideck_pad_state
    var kind: String

    var body: some View {
        HStack(spacing: 24) {
            stick(state.lx, state.ly, pressed: bit(9))
            VStack(spacing: 6) {
                trigger("LT", state.lt)
                trigger("RT", state.rt)
            }
            stick(state.rx, state.ry, pressed: bit(10))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 4), spacing: 6) {
                ForEach(Array(labels.enumerated()), id: \.offset) { i, l in
                    Text(l).font(.caption2.weight(.bold))
                        .frame(width: 44, height: 26)
                        .background(bit(i) ? Theme.accent : Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(bit(i) ? .black : Theme.textSecondary)
                }
            }
        }
    }

    private var labels: [String] {
        let face = kind == "PlayStation" ? ["✕", "○", "□", "△"] : ["A", "B", "X", "Y"]
        return face + ["LB", "RB", "Back", "Start", "Home", "LS", "RS", "▲", "▼", "◀", "▶", "Pad"]
    }

    private func bit(_ i: Int) -> Bool { state.buttons & (1 << UInt32(i)) != 0 }

    private func stick(_ x: Float, _ y: Float, pressed: Bool) -> some View {
        ZStack {
            Circle().stroke(Theme.stroke, lineWidth: 2).frame(width: 70, height: 70)
            Circle().fill(pressed ? Theme.accent : Theme.textSecondary).frame(width: 18, height: 18)
                .offset(x: CGFloat(x) * 26, y: CGFloat(-y) * 26)
        }
    }

    private func trigger(_ name: String, _ v: Float) -> some View {
        HStack(spacing: 6) {
            Text(name).font(.caption2.weight(.bold)).foregroundStyle(Theme.textSecondary).frame(width: 22)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceRaised).frame(width: 80, height: 8)
                Capsule().fill(Theme.accent).frame(width: CGFloat(v) * 80, height: 8)
            }
        }
    }
}
