import Foundation

// How large a TCG cache the JIT edition asks for on iPadOS 26 and later.
// Foundation only, so CI compiles and tests it on macOS without the app
// (ios/tests/log_parsers).

/// On iPadOS 26 and later StikDebug makes QEMU's cache executable by
/// writing one byte to each 16 KiB page of it over the debug connection
/// (legacy.js, `brk #0x69`). On the M5 iPad a 384 MiB cache runs (builds
/// 31, 41, 42) and a 1 GiB cache does not (builds 38, 40: one block
/// translated, vCPU 0 spinning on the first guest instruction).
///
/// A larger cache means fewer flushes: when the cache is full QEMU throws
/// all translated code away, and Steam's interface fills 384 MiB about four
/// times as often as 1 GiB (CI, docs/PERFORMANCE.md).
///
/// One cause is known that would stop a large cache: StikDebug 3.2.2 writes
/// each page address with nine hex digits (JSDebugSupport.swift,
/// fillAddress), so a cache mapped at 64 GiB or above is never prepared.
/// Where a cache would be mapped can be measured before QEMU starts
/// (IDPlatform.jitPlacement), which gives a rule that needs no failed start:
/// - if 1 GiB would be mapped at 64 GiB or above, the address limit explains
///   why it did not run, and a size that stays below is used;
/// - if 1 GiB would be mapped below 64 GiB, something else stopped it, and
///   the cache stays at the size that is known to run.
enum JITCachePlan {
    /// First address StikDebug's page writes cannot reach.
    static let debuggerAddressLimit: UInt64 = 1 << 36
    /// Runs on the device.
    static let provenMb: UInt64 = 384
    /// Did not run on the device.
    static let failedOnDeviceMb: UInt64 = 1024
    /// Sizes between the two, largest first (the planner's steps).
    static let largerMb: [UInt64] = [768, 512]

    /// Where QEMU would map a cache of `mb`: its buffer, and the second
    /// view of it, which is the executable one the debugger prepares.
    struct Placement: Equatable {
        var mb: UInt64
        var buffer: UInt64
        var view: UInt64

        var viewEnd: UInt64 { view + (mb << 20) }
        var addressable: Bool { view != 0 && viewEnd <= JITCachePlan.debuggerAddressLimit }
        var text: String {
            "\(mb) MiB at 0x\(String(view, radix: 16))" + (addressable ? "" : " (reaches 64 GiB or above)")
        }
    }

    struct Choice: Equatable {
        var mb: UInt64
        var reason: String
    }

    /// `failedMb`: a size above `provenMb` that did not run on this build.
    static func choose(placements: [Placement], failedMb: UInt64?) -> Choice {
        if let failedMb {
            return Choice(mb: provenMb, reason: "\(failedMb) MiB did not run on this build")
        }
        guard let large = placements.first(where: { $0.mb == failedOnDeviceMb }) else {
            return Choice(mb: provenMb, reason: "the placement of \(failedOnDeviceMb) MiB could not be measured")
        }
        if large.addressable {
            return Choice(mb: provenMb,
                          reason: "\(failedOnDeviceMb) MiB would be mapped below 64 GiB, so the debugger's address limit "
                              + "does not explain why it did not run")
        }
        for mb in largerMb {
            if let p = placements.first(where: { $0.mb == mb }), p.addressable {
                return Choice(mb: mb, reason: "it stays below 64 GiB, where \(failedOnDeviceMb) MiB would not")
            }
        }
        return Choice(mb: provenMb, reason: "no larger size stays below 64 GiB")
    }

    /// One unknown per start: while the engine options are on their first
    /// try, the cache stays at the size that is known to run, so a start
    /// that fails has one possible cause.
    static func oneUnknown(_ choice: Choice, engineFirstTry: Bool) -> Choice {
        guard engineFirstTry, choice.mb > provenMb else { return choice }
        return Choice(mb: provenMb, reason: "\(choice.mb) MiB is possible (\(choice.reason)), "
                          + "but this start is the first try of the engine options")
    }

    // MARK: A size that did not run

    /// Contents of the state file: the size and the app build it failed on.
    static func failureRecord(mb: UInt64, build: String) -> String { "\(mb)|\(build)" }

    /// The recorded size, if the record is from this app build (a later
    /// build may map the cache differently and is allowed one new attempt).
    static func failedMb(record: String?, build: String) -> UInt64? {
        guard let parts = record?.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|"),
              parts.count == 2, parts[1] == build, let mb = UInt64(parts[0]), mb > provenMb else { return nil }
        return mb
    }

    // MARK: What the debugger prepared

    /// The first byte of each page of the cache, read after QEMU answered
    /// (IDPlatform.jitPageMarks): `marked` hold the debugger's 0x69, `zero`
    /// were never written. QEMU has translated little by then, so a
    /// prepared cache is nearly all marks.
    struct PageMarks: Equatable {
        var pages: Int
        var marked: Int
        var zero: Int
        /// Offset in MiB of the first page that reads zero, -1 if none.
        var firstZeroMb: Int

        /// More than one page in 64 unwritten: the debugger did not prepare
        /// the cache. (A page QEMU already filled can begin with a zero
        /// byte, so a few are not evidence.)
        var unprepared: Bool { pages > 0 && zero * 64 > pages }

        var text: String {
            var s = "\(marked) of \(pages) pages carry the debugger's mark"
            if zero > 0 { s += ", \(zero) read zero (first at \(firstZeroMb) MiB)" }
            return s
        }
    }
}
