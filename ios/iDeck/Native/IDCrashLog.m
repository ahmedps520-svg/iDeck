#import "IDCrashLog.h"

#import <execinfo.h>
#import <fcntl.h>
#import <pthread.h>
#import <signal.h>
#import <string.h>
#import <time.h>
#import <unistd.h>

static int gFd = -1;
static struct sigaction gPrevious[32];
static const int kSignals[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP, SIGSYS};

static void writeStr(const char *s) {
    if (gFd >= 0 && s) (void)write(gFd, s, strlen(s));
}

static void writeHex(uintptr_t v) {
    char buf[2 + 16 + 1];
    buf[0] = '0';
    buf[1] = 'x';
    for (int i = 0; i < 16; i++) {
        unsigned d = (unsigned)((v >> ((15 - i) * 4)) & 0xF);
        buf[2 + i] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
    }
    buf[18] = 0;
    writeStr(buf);
}

static void writeInt(long v) {
    char buf[24];
    int i = 23;
    buf[i] = 0;
    BOOL neg = v < 0;
    unsigned long u = neg ? (unsigned long)(-v) : (unsigned long)v;
    do {
        buf[--i] = (char)('0' + u % 10);
        u /= 10;
    } while (u && i > 1);
    if (neg) buf[--i] = '-';
    writeStr(&buf[i]);
}

static const char *signalName(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS: return "SIGBUS";
        case SIGILL: return "SIGILL";
        case SIGFPE: return "SIGFPE";
        case SIGABRT: return "SIGABRT";
        case SIGTRAP: return "SIGTRAP";
        case SIGSYS: return "SIGSYS";
        default: return "signal";
    }
}

static void handler(int sig, siginfo_t *info, void *context) {
    char thread[64] = {0};
    pthread_getname_np(pthread_self(), thread, sizeof(thread));
    writeStr("\n=== iDeck crash: ");
    writeStr(signalName(sig));
    writeStr(" (");
    writeInt(sig);
    writeStr(") at ");
    writeHex((uintptr_t)(info ? info->si_addr : 0));
    writeStr(" code ");
    writeInt(info ? info->si_code : 0);
    writeStr(" thread '");
    writeStr(thread[0] ? thread : (pthread_main_np() ? "main" : "?"));
    writeStr("' time ");
    writeInt((long)time(NULL));
    writeStr("\n");
    void *frames[64];
    int n = backtrace(frames, 64);
    backtrace_symbols_fd(frames, n, gFd);
    writeStr("=== end\n");
    if (gFd >= 0) fsync(gFd);
    // Hand over to the previous handler (or the default) and re-raise so
    // iPadOS still produces its own crash report.
    struct sigaction *prev = &gPrevious[sig];
    if (prev->sa_flags & SA_SIGINFO ? prev->sa_sigaction != NULL : (prev->sa_handler != SIG_DFL && prev->sa_handler != SIG_IGN)) {
        sigaction(sig, prev, NULL);
    } else {
        signal(sig, SIG_DFL);
    }
    raise(sig);
}

static void exceptionHandler(NSException *e) {
    NSString *text = [NSString stringWithFormat:@"\n=== iDeck uncaught exception: %@: %@\n%@\n=== end\n",
                      e.name, e.reason, [e.callStackSymbols componentsJoinedByString:@"\n"]];
    writeStr(text.UTF8String);
    if (gFd >= 0) fsync(gFd);
}

@implementation IDCrashLog

+ (void)installWithPath:(NSString *)path {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gFd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
        // A separate stack so stack overflows can still be reported.
        static uint8_t altstack[64 * 1024];
        stack_t ss = {.ss_sp = altstack, .ss_size = sizeof(altstack), .ss_flags = 0};
        sigaltstack(&ss, NULL);
        for (size_t i = 0; i < sizeof(kSignals) / sizeof(kSignals[0]); i++) {
            struct sigaction sa;
            memset(&sa, 0, sizeof(sa));
            sa.sa_sigaction = handler;
            sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
            sigemptyset(&sa.sa_mask);
            sigaction(kSignals[i], &sa, &gPrevious[kSignals[i]]);
        }
        NSSetUncaughtExceptionHandler(exceptionHandler);
    });
}

@end
