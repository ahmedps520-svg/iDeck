// iDeck — platform queries: JIT availability, memory limits, signing.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface IDPlatform : NSObject

/// The kernel marked this process CS_DEBUGGED: a debugger (StikDebug, Xcode)
/// attached, which is what makes JIT possible for sideloaded apps.
@property (class, nonatomic, readonly) BOOL isDebuggerAttached;
/// A debugger is attached right now (P_TRACED).
@property (class, nonatomic, readonly) BOOL isTraced;
/// iOS/iPadOS 26 or later: TXM devices need the debugger-assisted JIT
/// protocol implemented by the utmapp/qemu fork (split-wx + brk #0x69).
@property (class, nonatomic, readonly) BOOL needsTXMJITProtocol;

/// os_proc_available_memory(): bytes the app may still allocate before
/// iPadOS terminates it.
@property (class, nonatomic, readonly) uint64_t availableMemory;
/// task_vm_info.phys_footprint: what jetsam charges this app.
@property (class, nonatomic, readonly) uint64_t physFootprint;
@property (class, nonatomic, readonly) uint64_t physicalMemory;
/// e.g. "iPad17,1"
@property (class, nonatomic, readonly) NSString *modelIdentifier;

/// Entitlements from embedded.mobileprovision (nil if absent, e.g. unsigned).
@property (class, nonatomic, readonly, nullable) NSDictionary<NSString *, id> *provisionedEntitlements;
/// Entitlements in this binary's code signature (what the kernel and the
/// sandbox enforce), read with csops(CS_OPS_ENTITLEMENTS_BLOB). A sideloading
/// tool may sign with fewer or renamed app groups than the build asked for.
@property (class, nonatomic, readonly, nullable) NSDictionary<NSString *, id> *signedEntitlements;
/// First com.apple.security.application-groups entry; needed by
/// virglrenderer's shm_open() for Venus blob memory. Taken from the code
/// signature, else the provisioning profile, else Info.plist.
@property (class, nonatomic, readonly, nullable) NSString *applicationGroupIdentifier;
/// Where applicationGroupIdentifier came from: "signature", "profile",
/// "Info.plist" or "none".
@property (class, nonatomic, readonly) NSString *applicationGroupSource;
/// Every app group worth trying, in order: code signature, provisioning
/// profile, Info.plist (duplicates removed).
@property (class, nonatomic, readonly) NSArray<NSString *> *applicationGroupCandidates;
/// Creates, sizes, maps and removes a POSIX shared memory object named the
/// way UTM's virglrenderer names Venus blob memory ("<group>/<hex>").
/// Returns nil when that works, else why it failed.
+ (nullable NSString *)sharedMemoryProblemForGroup:(nullable NSString *)group;
@property (class, nonatomic, readonly) BOOL hasIncreasedMemoryLimit;
/// "development", "testflight/app-store", "unsigned" — from the profile.
@property (class, nonatomic, readonly) NSString *signingKind;

@end

NS_ASSUME_NONNULL_END
