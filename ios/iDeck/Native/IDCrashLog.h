// iDeck — records why the app died (fatal signals, uncaught ObjC exceptions)
// to Documents/Logs/crash.log, so crashes can be diagnosed without digging
// through iPadOS Analytics. A missing entry after an unexpected close points
// at a SIGKILL (jetsam / watchdog), which no handler can see.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface IDCrashLog : NSObject
/// Installs handlers once. `path` is opened now (append), so the signal
/// handler only uses async-signal-safe calls.
+ (void)installWithPath:(NSString *)path;
@end

NS_ASSUME_NONNULL_END
