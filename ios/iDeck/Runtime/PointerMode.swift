import Foundation

// How touches on the Linux screen become mouse input. Foundation only, so CI
// compiles and tests it on macOS without the app (ios/tests/log_parsers).

/// Touch sends positions (tap where you want to click), which suits Steam
/// and anything with a normal pointer. A game that takes the mouse for
/// itself (SDL relative mode: Teeworlds, shooters) reads movement instead,
/// and a position makes its own cursor jump: on device (build 41) every tap
/// in Teeworlds threw the cursor somewhere else. Trackpad sends movement.
enum PointerMode: String, CaseIterable {
    case automatic, touch, trackpad

    /// Trackpad when chosen, or in automatic while a game runs in Linux.
    func usesTrackpad(gameRunning: Bool) -> Bool {
        switch self {
        case .automatic: return gameRunning
        case .touch: return false
        case .trackpad: return true
        }
    }

    var title: String {
        switch self {
        case .automatic: return "Pointer: automatic"
        case .touch: return "Pointer: touch"
        case .trackpad: return "Pointer: trackpad"
        }
    }

    static let trackpadHint = "Trackpad pointer: drag to move, tap to click, two-finger tap to right-click. "
        + "A second finger holds the button while you drag. Change it in the ⋯ menu."
    static let touchHint = "Touch pointer: tap where you want to click."
}

/// Whole-pixel mouse movement from fractional finger movement. SPICE sends
/// integers; the fraction left over is carried to the next event, so slow
/// movement adds up instead of being dropped.
struct RelativeMotion {
    private var restX = 0.0
    private var restY = 0.0

    mutating func add(dx: Double, dy: Double) -> (x: Int, y: Int) {
        restX += dx
        restY += dy
        let x = restX.rounded(.towardZero)
        let y = restY.rounded(.towardZero)
        restX -= x
        restY -= y
        return (Int(x), Int(y))
    }

    mutating func reset() {
        restX = 0
        restY = 0
    }
}
