import Foundation

// The provisioning profile that Sideloadly, AltStore, SideStore or Xcode put
// into the app when signing it (embedded.mobileprovision). With a free Apple
// ID it is valid for 7 days; after that iOS refuses to open iDeck until it is
// signed and installed again. Foundation only, so CI tests the parsing on
// macOS without the app (ios/tests/log_parsers).

struct SigningProfile: Equatable {
    var name: String?
    var created: Date?
    var expires: Date

    /// Profiles from free Apple IDs last 7 days; paid developer ones a year.
    var isShortLived: Bool {
        guard let created else { return false }
        return expires.timeIntervalSince(created) < 8 * 86_400
    }

    func secondsLeft(now: Date = Date()) -> TimeInterval { expires.timeIntervalSince(now) }

    /// Shown on Home from two days before expiry.
    func needsWarning(now: Date = Date()) -> Bool { secondsLeft(now: now) < 2 * 86_400 }

    /// The profile is a CMS (PKCS#7) signed message whose content, the XML
    /// property list, is stored unencrypted, so it can be cut out directly.
    static func parse(_ data: Data) -> SigningProfile? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let expires = plist["ExpirationDate"] as? Date
        else { return nil }
        return SigningProfile(name: plist["Name"] as? String, created: plist["CreationDate"] as? Date, expires: expires)
    }

    /// nil for App Store, TestFlight and simulator builds, which embed none.
    static let current: SigningProfile? = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { SigningProfile.parse($0) }

    /// "1 day, 4 hours" / "3 hours" / "less than an hour"; nil once expired.
    static func remaining(_ seconds: TimeInterval) -> String? {
        guard seconds > 0 else { return nil }
        let hours = Int(seconds / 3600)
        if hours < 1 { return "less than an hour" }
        let d = hours / 24, h = hours % 24
        func unit(_ n: Int, _ s: String) -> String { "\(n) \(s)\(n == 1 ? "" : "s")" }
        if d == 0 { return unit(h, "hour") }
        return unit(d, "day") + (h > 0 ? ", " + unit(h, "hour") : "")
    }

    /// One line for ideck.log.
    func logLine(now: Date = Date()) -> String {
        let left = SigningProfile.remaining(secondsLeft(now: now)).map { "\($0) left" } ?? "expired"
        return "signing profile: expires \(ISO8601DateFormatter().string(from: expires)) (\(left)), "
            + (isShortLived ? "7-day (free Apple ID)" : "long-lived")
    }

    /// Home notice text, or nil when no warning is due.
    func warning(now: Date = Date(), device: String = "device") -> (title: String, message: String)? {
        guard needsWarning(now: now) else { return nil }
        let day = DateFormatter.localizedString(from: expires, dateStyle: .medium, timeStyle: .short)
        let how = "Install iDeck again with Sideloadly (or refresh it in AltStore or SideStore) using the same Apple ID. "
            + "Installing over the existing app keeps your Linux disk, Steam login and games."
        guard let left = SigningProfile.remaining(secondsLeft(now: now)) else {
            return ("iDeck's signature has expired", "It expired on \(day). \(how)")
        }
        return ("iDeck stops opening in \(left)",
                "The signature from your " + (isShortLived ? "free Apple ID" : "developer account")
                    + " runs out on \(day). After that this \(device) will not open iDeck until it is signed again. " + how)
    }
}
