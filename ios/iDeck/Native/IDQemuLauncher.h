// iDeck — runs QEMU (utmapp/qemu fork, built as a framework) in-process.
//
// iOS apps cannot spawn processes, so QEMU's softmmu library is loaded with
// dlopen and its entry points (qemu_init / qemu_main_loop / qemu_cleanup)
// run on a dedicated thread, the same model UTM uses on iOS. QEMU keeps
// global state, so it can be started once per app process.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^IDQemuExitHandler)(int status, NSString *_Nullable message);

@interface IDQemuLauncher : NSObject

/// YES once QEMU has been started in this process (it cannot be restarted).
@property (class, nonatomic, readonly) BOOL hasStarted;
/// YES while the QEMU thread is running.
@property (nonatomic, readonly) BOOL running;

- (instancetype)init NS_UNAVAILABLE;
/// `frameworkPath` is the bundle's qemu-aarch64-softmmu.framework.
- (instancetype)initWithFrameworkPath:(NSString *)frameworkPath NS_DESIGNATED_INITIALIZER;

/// Loads QEMU and starts it with `arguments` (argv[0] included). Environment
/// variables are exported process-wide first (QEMU's libraries read them
/// with getenv). QEMU's stdout/stderr go to `logPath`.
- (BOOL)startWithArguments:(NSArray<NSString *> *)arguments
               environment:(NSDictionary<NSString *, NSString *> *)environment
                   logPath:(NSString *)logPath
               exitHandler:(IDQemuExitHandler)exitHandler
                     error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
