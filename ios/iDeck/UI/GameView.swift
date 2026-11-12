import GameController
import MetalKit
import SwiftUI
import UIKit

/// Full-screen Linux/Steam display with input. Shows boot progress until the
/// guest is up, and the JIT / relaunch guidance when Linux cannot start.
struct GameView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var runtime: RuntimeController
    @State private var showMenu = false
    @State private var captureMouse = false
    @State private var showKeyboard = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let spice = runtime.spice, runtime.isRunning {
                DisplayRepresentable(spice: spice, captureMouse: captureMouse, showKeyboard: showKeyboard)
                    .ignoresSafeArea()
            }
            overlay
        }
        .statusBarHidden(true)
        // StikDebug returned with JIT ready: start Linux without another tap.
        .onChange(of: runtime.jitReadyEvent) { _ in
            Task { await runtime.startGaming() }
        }
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    @ViewBuilder
    private var overlay: some View {
        switch runtime.phase {
        case .running:
            VStack {
                HStack(alignment: .top) {
                    if let update = runtime.steamUpdate {
                        SteamUpdateBanner(update: update)
                            .padding(.leading, 14).padding(.top, 14)
                    }
                    Spacer()
                    Menu {
                        Button { captureMouse.toggle() } label: {
                            Label(captureMouse ? "Release Mouse" : "Capture Mouse (games)", systemImage: "cursorarrow.motionlines")
                        }
                        Button { showKeyboard.toggle() } label: {
                            Label(showKeyboard ? "Hide Keyboard" : "Show Keyboard", systemImage: "keyboard")
                        }
                        Button { Task { try? await runtime.openSteam("steam://open/downloads") } } label: {
                            Label("Steam Downloads", systemImage: "arrow.down.circle")
                        }
                        Button { runtime.spice?.resetZoom() } label: {
                            Label("Reset Zoom", systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                        Divider()
                        Button { model.showGame = false } label: { Label("Back to iDeck", systemImage: "square.grid.2x2") }
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.system(size: 26))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white.opacity(0.85), .black.opacity(0.45))
                            .padding(14)
                    }
                }
                Spacer()
            }
        case .starting(let s), .booting(let s):
            BootProgressView(status: s)
        case .needsJIT:
            JITHelpView(onClose: { model.showGame = false })
        case .needsRelaunch:
            MessageOverlay(icon: "arrow.clockwise.circle", title: "Restart iDeck",
                           message: runtime.relaunchReason ?? "Linux has stopped. \(Device.os) allows the emulator to start once per launch: close iDeck from the app switcher and open it again (enable JIT again first).",
                           action: ("Back to iDeck", { model.showGame = false }))
        case .failed(let m):
            MessageOverlay(icon: "exclamationmark.triangle", title: "Linux could not start", message: m,
                           action: ("Back to iDeck", { model.showGame = false }))
        case .stopping:
            BootProgressView(status: "Shutting down Linux…")
        default:
            MessageOverlay(icon: "power", title: "Linux is not running", message: "Tap Start Gaming on the home screen.",
                           action: ("Back to iDeck", { model.showGame = false }))
        }
    }
}

/// Steam installs client updates before its window appears; under
/// emulation that takes minutes with only the small updater window on screen,
/// which looked like a hang on device.
struct SteamUpdateBanner: View {
    var update: SteamUpdateState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(update.summary, systemImage: "arrow.down.circle")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            if update.stage == .downloading, update.totalKB > 0 {
                ProgressView(value: Double(update.doneKB), total: Double(update.totalKB)).tint(Theme.accent)
            }
            Text("Keep iDeck open: this can take several minutes, and Steam's window appears when it is done.")
                .font(.caption).foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.72)))
        .allowsHitTesting(false)
    }
}

struct BootProgressView: View {
    var status: String
    @State private var pulse = false
    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().stroke(Theme.accent.opacity(0.15), lineWidth: 6).frame(width: 84, height: 84)
                Circle().trim(from: 0, to: 0.28)
                    .stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 84, height: 84)
                    .rotationEffect(.degrees(pulse ? 360 : 0))
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: pulse)
            }
            Text(status).font(.system(.title3, design: .rounded).weight(.semibold)).foregroundStyle(.white)
            Text("Linux boots under emulation; the first start can take a few minutes.")
                .font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
        .onAppear { pulse = true }
    }
}

struct MessageOverlay: View {
    var icon: String
    var title: String
    var message: String
    var action: (String, () -> Void)
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text(title).font(.system(.title2, design: .rounded).weight(.bold)).foregroundStyle(.white)
            ScrollView {
                Text(message).font(.callout.monospaced()).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.leading).frame(maxWidth: 560)
            }.frame(maxHeight: 260)
            Button(action.0, action: action.1).buttonStyle(PrimaryButtonStyle())
        }
        .padding(32)
    }
}

/// Explains how to enable JIT on a sideloaded build (no URL scheme exists
/// to request it automatically).
struct JITHelpView: View {
    var onClose: () -> Void
    @EnvironmentObject var runtime: RuntimeController
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Enable JIT to start Linux", systemImage: "bolt.badge.clock")
                .font(.system(.title2, design: .rounded).weight(.bold)).foregroundStyle(.white)
            Text(runtime.jitProblem)
                .font(.callout.weight(.semibold)).foregroundStyle(Theme.warning)
            Text("iDeck emulates an ARM64 PC. \(Device.os) only allows the emulator's JIT while a debugger (StikDebug) is attached. Without it the emulator is far too slow to run.")
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 12) {
                Button("Enable JIT with StikDebug") { runtime.requestJIT() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Check Again") { Task { await runtime.startGaming() } }.buttonStyle(SecondaryButtonStyle())
                Button("Close", action: onClose).buttonStyle(SecondaryButtonStyle())
            }
            Text("StikDebug asks you to confirm, attaches with its legacy.js script and returns to iDeck, which then continues by itself.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 10) {
                Text("If that does not work, do it by hand:").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                step(1, "Open StikDebug (LocalDevVPN connected, pairing file imported).")
                step(2, "Long-press iDeck in its app list › Assign Script › legacy.js (once).")
                step(3, "Tap Enable JIT for iDeck, and leave StikDebug running in the background.")
            }
            Text("State: CS_DEBUGGED \(IDPlatform.isDebuggerAttached ? "yes" : "no") · debugger attached \(IDPlatform.isTraced ? "yes" : "no")"
                 + (IDPlatform.needsTXMJITProtocol ? " · \(Device.os) 26+ (TXM)" : ""))
                .font(.caption.monospaced()).foregroundStyle(Theme.textTertiary)
        }
        .padding(32).frame(maxWidth: 640)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline.monospacedDigit()).foregroundStyle(.black)
                .frame(width: 26, height: 26).background(Theme.accent, in: Circle())
            Text(text).foregroundStyle(.white)
        }
    }
}

// MARK: - Display + input

struct DisplayRepresentable: UIViewControllerRepresentable {
    let spice: IDSpiceClient
    var captureMouse: Bool
    var showKeyboard: Bool

    func makeUIViewController(context: Context) -> DisplayViewController {
        DisplayViewController(spice: spice)
    }

    func updateUIViewController(_ vc: DisplayViewController, context: Context) {
        vc.setMouseCaptured(captureMouse)
        vc.setKeyboardVisible(showKeyboard)
    }
}

/// Hosts the MTKView that CocoaSpice renders into and translates touch,
/// pointer, keyboard and GCMouse input into SPICE input events.
final class DisplayViewController: UIViewController, UIKeyInput {
    let spice: IDSpiceClient
    private let mtkView = MTKView()
    private var buttons: IDMouseButton = []
    private var mouseCaptured = false
    private var keyboardVisible = false
    private var lastPan: CGPoint = .zero
    private var mouseObserver: NSObjectProtocol?

    init(spice: IDSpiceClient) {
        self.spice = spice
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        mtkView.isMultipleTouchEnabled = true
        view = mtkView
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Re-attach in case another controller held the display meanwhile.
        spice.attach(to: mtkView)
        spice.updateViewport()
        becomeFirstResponder()  // hardware keyboard events
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        spice.attach(to: mtkView)
        if !spice.connected { _ = spice.connect() }

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let twoTap = UITapGestureRecognizer(target: self, action: #selector(rightClick(_:)))
        twoTap.numberOfTouchesRequired = 2
        // One finger on the screen scrolls what is under it (or moves the
        // captured mouse in games); a trackpad click-drag drags.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let pointerDrag = UIPanGestureRecognizer(target: self, action: #selector(pointerDragged(_:)))
        pointerDrag.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = .continuous
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        long.minimumPressDuration = 0.45
        // Pinch zooms the display (small screens); two fingers then pan it.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        scroll.delegate = self
        [tap, twoTap, pan, pointerDrag, scroll, hover, long, pinch].forEach(view.addGestureRecognizer)
        tap.require(toFail: twoTap)

        mouseObserver = NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) {
            [weak self] _ in self?.bindMice()
        }
        bindMice()
    }

    deinit {
        if let mouseObserver { NotificationCenter.default.removeObserver(mouseObserver) }
        // Only our own view: SwiftUI may build the replacement controller
        // (which attaches its view) before this one goes away.
        spice.detach(from: mtkView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The drawable size is only known after layout; without this a newly
        // attached view kept the renderer's default 1:1 scale.
        spice.updateViewport()
    }

    // Pointer lock for games when the user captures the mouse.
    override var prefersPointerLocked: Bool { mouseCaptured }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    func setMouseCaptured(_ on: Bool) {
        guard on != mouseCaptured else { return }
        mouseCaptured = on
        spice.requestRelativeMouse(on)
        setNeedsUpdateOfPrefersPointerLocked()
    }

    func setKeyboardVisible(_ on: Bool) {
        guard on != keyboardVisible else { return }
        keyboardVisible = on
        if on { becomeFirstResponder() } else { resignFirstResponder() }
    }

    override var canBecomeFirstResponder: Bool { true }

    /// Maps a point in the view to guest framebuffer pixels (aspect fit,
    /// zoom and pan).
    private func guestPoint(_ p: CGPoint) -> CGPoint {
        spice.guestPoint(forViewPoint: p)
    }

    private var pinching = false
    private var lastPinchCentre: CGPoint = .zero

    @objc private func pinched(_ r: UIPinchGestureRecognizer) {
        let c = r.location(in: view)
        switch r.state {
        case .began:
            pinching = true
            lastPinchCentre = c
        case .changed:
            spice.zoom(by: r.scale, around: c)
            r.scale = 1
            spice.pan(by: CGPoint(x: c.x - lastPinchCentre.x, y: c.y - lastPinchCentre.y))
            lastPinchCentre = c
        default:
            pinching = false
        }
    }

    private var lastTwoFingerPan: CGPoint = .zero

    @objc private func tapped(_ r: UITapGestureRecognizer) {
        let p = guestPoint(r.location(in: view))
        spice.sendMouseAbsolute(p, buttons: [])
        spice.sendMouseButton(.left, pressed: true, buttons: .left)
        spice.sendMouseButton(.left, pressed: false, buttons: [])
    }

    @objc private func rightClick(_ r: UITapGestureRecognizer) {
        let p = guestPoint(r.location(in: view))
        spice.sendMouseAbsolute(p, buttons: [])
        spice.sendMouseButton(.right, pressed: true, buttons: .right)
        spice.sendMouseButton(.right, pressed: false, buttons: [])
    }

    @objc private func longPressed(_ r: UILongPressGestureRecognizer) {
        // Long-press then drag = left-button drag (select, drag windows).
        let p = guestPoint(r.location(in: view))
        switch r.state {
        case .began:
            spice.sendMouseAbsolute(p, buttons: [])
            buttons.insert(.left)
            spice.sendMouseButton(.left, pressed: true, buttons: buttons)
        case .changed:
            spice.sendMouseAbsolute(p, buttons: buttons)
        default:
            buttons.remove(.left)
            spice.sendMouseButton(.left, pressed: false, buttons: buttons)
        }
    }

    @objc private func panned(_ r: UIPanGestureRecognizer) {
        if mouseCaptured {
            // Games: one-finger drag is trackpad-style relative motion.
            let t = r.translation(in: view)
            spice.sendMouseRelative(CGPoint(x: t.x - lastPan.x, y: t.y - lastPan.y), buttons: buttons)
            lastPan = r.state == .ended ? .zero : t
        } else {
            // Desktop (Steam): one-finger drag scrolls, like any iPad app.
            // Before, it only moved the pointer, so nothing scrolled.
            scrolled(r)
        }
    }

    /// Finger travel per scroll-wheel notch (Chromium scrolls about three
    /// lines per notch).
    private static let pointsPerNotch: CGFloat = 22
    private var lastScrollY: CGFloat = 0

    @objc private func scrolled(_ r: UIPanGestureRecognizer) {
        // Two fingers on a zoomed display move the view instead of scrolling
        // (a trackpad's two-finger scroll has no touches and still scrolls).
        if r.state == .began { lastTwoFingerPan = .zero }
        let twoFingers = r.minimumNumberOfTouches >= 2 && r.numberOfTouches >= 2
        if twoFingers && (pinching || spice.zoom > 1) {
            let t = r.translation(in: view)
            // While pinching, the pinch moves the view with its centre.
            if !pinching { spice.pan(by: CGPoint(x: t.x - lastTwoFingerPan.x, y: t.y - lastTwoFingerPan.y)) }
            lastTwoFingerPan = t
            return
        }
        switch r.state {
        case .began:
            lastScrollY = 0
            // Aim the wheel at the content under the fingers.
            spice.sendMouseAbsolute(guestPoint(r.location(in: view)), buttons: buttons)
        case .changed:
            // Distance, not velocity: a slow drag scrolls as far as a fast
            // one. Finger up -> content follows the finger -> wheel down.
            let y = r.translation(in: view).y
            spice.sendScroll(-(y - lastScrollY) / DisplayViewController.pointsPerNotch, buttons: buttons)
            lastScrollY = y
        default:
            lastScrollY = 0
        }
    }

    @objc private func pointerDragged(_ r: UIPanGestureRecognizer) {
        // Trackpad or mouse click-and-drag: select text, drag windows.
        if mouseCaptured {
            panned(r)
            return
        }
        let p = guestPoint(r.location(in: view))
        switch r.state {
        case .began:
            spice.sendMouseAbsolute(p, buttons: [])
            buttons.insert(.left)
            spice.sendMouseButton(.left, pressed: true, buttons: buttons)
        case .changed:
            spice.sendMouseAbsolute(p, buttons: buttons)
        default:
            buttons.remove(.left)
            spice.sendMouseButton(.left, pressed: false, buttons: buttons)
        }
    }

    @objc private func hovered(_ r: UIHoverGestureRecognizer) {
        guard !mouseCaptured else { return }
        spice.sendMouseAbsolute(guestPoint(r.location(in: view)), buttons: buttons)
    }

    // Physical mouse buttons arrive as UIEvent button masks through
    // GCMouse; relative motion is used while captured.
    private func bindMice() {
        for mouse in GCMouse.mice() {
            guard let input = mouse.mouseInput else { continue }
            input.mouseMovedHandler = { [weak self] _, dx, dy in
                guard let self, self.mouseCaptured else { return }
                self.spice.sendMouseRelative(CGPoint(x: CGFloat(dx), y: CGFloat(-dy)), buttons: self.buttons)
            }
            input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in self?.mouseButton(.left, pressed) }
            input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.mouseButton(.right, pressed) }
            input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.mouseButton(.middle, pressed) }
            input.scroll.valueChangedHandler = { [weak self] _, _, y in
                guard let self, abs(y) > 0.01 else { return }
                self.spice.sendScroll(CGFloat(-y) / 10, buttons: self.buttons)
            }
        }
    }

    private func mouseButton(_ b: IDMouseButton, _ pressed: Bool) {
        if pressed { buttons.insert(b) } else { buttons.remove(b) }
        spice.sendMouseButton(b, pressed: pressed, buttons: buttons)
    }

    // MARK: Keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            if let key = p.key {
                spice.sendKeyUsage(key.keyCode.rawValue, pressed: true)
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            if let key = p.key {
                spice.sendKeyUsage(key.keyCode.rawValue, pressed: false)
                handled = true
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        spice.releaseAllKeys()
        super.pressesCancelled(presses, with: event)
    }

    // UIKeyInput: the on-screen keyboard (text only; hardware keys use presses).
    var hasText: Bool { true }

    func insertText(_ text: String) {
        for ch in text {
            guard let (usage, shift) = Self.usage(for: ch) else { continue }
            if shift { spice.sendKeyUsage(0xE1, pressed: true) }
            spice.sendKeyUsage(usage, pressed: true)
            spice.sendKeyUsage(usage, pressed: false)
            if shift { spice.sendKeyUsage(0xE1, pressed: false) }
        }
    }

    func deleteBackward() {
        spice.sendKeyUsage(0x2A, pressed: true)
        spice.sendKeyUsage(0x2A, pressed: false)
    }

    /// US-layout mapping for on-screen keyboard characters.
    static func usage(for ch: Character) -> (Int, Bool)? {
        let s = String(ch)
        if let a = s.unicodeScalars.first?.value {
            switch a {
            case 97...122: return (Int(a - 97) + 0x04, false)
            case 65...90: return (Int(a - 65) + 0x04, true)
            case 49...57: return (Int(a - 49) + 0x1E, false)
            case 48: return (0x27, false)
            default: break
            }
        }
        let table: [Character: (Int, Bool)] = [
            "\n": (0x28, false), " ": (0x2C, false), "\t": (0x2B, false), "-": (0x2D, false), "_": (0x2D, true),
            "=": (0x2E, false), "+": (0x2E, true), "[": (0x2F, false), "{": (0x2F, true), "]": (0x30, false),
            "}": (0x30, true), "\\": (0x31, false), "|": (0x31, true), ";": (0x33, false), ":": (0x33, true),
            "'": (0x34, false), "\"": (0x34, true), "`": (0x35, false), "~": (0x35, true), ",": (0x36, false),
            "<": (0x36, true), ".": (0x37, false), ">": (0x37, true), "/": (0x38, false), "?": (0x38, true),
            "!": (0x1E, true), "@": (0x1F, true), "#": (0x20, true), "$": (0x21, true), "%": (0x22, true),
            "^": (0x23, true), "&": (0x24, true), "*": (0x25, true), "(": (0x26, true), ")": (0x27, true),
        ]
        return table[ch]
    }
}

extension DisplayViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch and the two-finger pan run together so a pinch can also move
        // the zoomed view.
        (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
            || (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }
}
