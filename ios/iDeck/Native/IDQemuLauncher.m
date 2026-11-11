#import "IDQemuLauncher.h"

#import <dlfcn.h>
#import <fcntl.h>
#import <pthread.h>
#import <stdlib.h>
#import <unistd.h>

typedef int (*qemu_init_fn)(int, const char *[], const char *[]);
typedef void (*qemu_void_fn)(void);

static BOOL gHasStarted = NO;

@interface IDQemuLauncher ()
@property (nonatomic, copy) NSString *frameworkPath;
@property (nonatomic, copy) NSArray<NSString *> *arguments;
@property (nonatomic, copy) IDQemuExitHandler exitHandler;
@property (nonatomic, readwrite) BOOL running;
@end

@implementation IDQemuLauncher {
    qemu_init_fn _init;
    qemu_void_fn _mainLoop;
    qemu_void_fn _cleanup;
    pthread_t _thread;
    int _status;
    BOOL _fatal;
    dispatch_semaphore_t _done;
}

+ (BOOL)hasStarted {
    return gHasStarted;
}

- (instancetype)initWithFrameworkPath:(NSString *)frameworkPath {
    if (self = [super init]) {
        _frameworkPath = [frameworkPath copy];
        _done = dispatch_semaphore_create(0);
    }
    return self;
}

static NSError *IDError(NSString *message) {
    return [NSError errorWithDomain:@"iDeck.QEMU" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static void *qemu_thread_main(void *arg) {
    IDQemuLauncher *self = (__bridge_transfer IDQemuLauncher *)arg;
    NSArray<NSString *> *args = self.arguments;
    int argc = (int)args.count;
    const char **argv = calloc((size_t)argc + 1, sizeof(char *));
    for (int i = 0; i < argc; i++) {
        argv[i] = strdup(args[(NSUInteger)i].UTF8String);
    }
    extern char **environ;
    int ret = self->_init(argc, argv, (const char **)environ);
    if (ret == 0) {
        self->_mainLoop();
        self->_cleanup();
    }
    self->_status = ret;
    dispatch_semaphore_signal(self->_done);
    return NULL;
}

- (BOOL)startWithArguments:(NSArray<NSString *> *)arguments
               environment:(NSDictionary<NSString *, NSString *> *)environment
                   logPath:(NSString *)logPath
               exitHandler:(IDQemuExitHandler)exitHandler
                     error:(NSError **)error {
    if (gHasStarted) {
        if (error) *error = IDError(@"Linux was already started in this session. Close iDeck from the app switcher and open it again.");
        return NO;
    }
    NSString *name = self.frameworkPath.lastPathComponent.stringByDeletingPathExtension;
    NSString *dylib = [self.frameworkPath stringByAppendingPathComponent:name];
    void *handle = dlopen(dylib.fileSystemRepresentation, RTLD_LOCAL | RTLD_NOW);
    if (!handle) {
        if (error) *error = IDError([NSString stringWithFormat:@"Could not load QEMU: %s", dlerror()]);
        return NO;
    }
    _init = (qemu_init_fn)dlsym(handle, "qemu_init");
    _mainLoop = (qemu_void_fn)dlsym(handle, "qemu_main_loop");
    _cleanup = (qemu_void_fn)dlsym(handle, "qemu_cleanup");
    if (!_init || !_mainLoop || !_cleanup) {
        if (error) *error = IDError(@"QEMU framework does not export qemu_init/qemu_main_loop/qemu_cleanup.");
        return NO;
    }

    [environment enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        setenv(key.UTF8String, value.UTF8String, 1);
    }];

    // QEMU reports configuration errors on stderr; keep them for diagnostics.
    int logfd = open(logPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (logfd >= 0) {
        dup2(logfd, STDOUT_FILENO);
        dup2(logfd, STDERR_FILENO);
        close(logfd);
    }

    self.arguments = arguments;
    self.exitHandler = exitHandler;
    __weak typeof(self) weakSelf = self;
    // exit() called by QEMU on its own thread must not terminate the app:
    // end just that thread and report a fatal exit instead.
    if (atexit_b(^{
            __strong typeof(weakSelf) s = weakSelf;
            if (s && pthread_equal(pthread_self(), s->_thread)) {
                s->_fatal = YES;
                dispatch_semaphore_signal(s->_done);
                pthread_exit(NULL);
            }
        }) != 0) {
        if (error) *error = IDError(@"Internal error (atexit).");
        return NO;
    }

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    pthread_attr_setstacksize(&attr, 8 * 1024 * 1024);
    gHasStarted = YES;
    self.running = YES;
    int rc = pthread_create(&_thread, &attr, qemu_thread_main, (__bridge_retained void *)self);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        self.running = NO;
        if (error) *error = IDError(@"Could not create the QEMU thread.");
        return NO;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        dispatch_semaphore_wait(self->_done, DISPATCH_TIME_FOREVER);
        self.running = NO;
        int status = self->_fatal ? -1 : self->_status;
        NSString *msg = nil;
        if (self->_fatal) msg = @"QEMU exited unexpectedly. See the QEMU log in Diagnostics.";
        else if (status != 0) msg = @"QEMU rejected the VM configuration. See the QEMU log in Diagnostics.";
        IDQemuExitHandler handler = self.exitHandler;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (handler) handler(status, msg);
        });
    });
    return YES;
}

@end
