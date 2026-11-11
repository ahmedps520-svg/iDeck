import UIKit

/// Receives IDSpiceClient events (on the main queue) and writes them to the
/// app log; the connection state is handed back to the runtime controller.
final class SpiceEventLog: NSObject, IDSpiceClientDelegate {
    var onChange: ((Bool) -> Void)?

    func spiceClientDidConnect() {
        DiagLog.write("display: SPICE connected")
        onChange?(true)
    }

    func spiceClientDidDisconnect() {
        DiagLog.write("display: SPICE disconnected")
        onChange?(false)
    }

    func spiceClientDidFail(_ message: String) {
        DiagLog.write("display: SPICE error: \(message)")
    }

    func spiceClientDisplaySizeChanged(_ size: CGSize) {
        DiagLog.write("display: primary display \(Int(size.width))x\(Int(size.height))")
    }

    func spiceClientAgentConnected(_ connected: Bool) {
        DiagLog.write("display: guest SPICE agent \(connected ? "connected" : "disconnected")")
    }
}
